import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/repository.dart';
import '../models.dart';
import 'doc_files.dart';
import 's3_signer.dart';
import 'settings.dart';

/// 云端存储：把大文件（原始资料、笔记照片、导出的 PDF、备份）放到用户自己买的
/// 阿里云 OSS / 腾讯云 COS / 其他 S3 兼容存储桶里，释放手机空间；用到时再下载回来。
///
/// 只是「省空间」，不是多设备同步：数据库（文字、卡片、笔记、导图）永远留在本机。
/// 释放空间是手动操作（用户点「释放空间」才删本地文件），从不自动上传或删除。

class CloudException implements Exception {
  final String message;
  CloudException(this.message);
  @override
  String toString() => message;
}

/// 存储服务商预设。
class CloudProvider {
  final String id;
  final String name;
  final String regionHint;
  final String bucketHint;
  final String keyIdLabel;
  final String secretLabel;
  const CloudProvider(this.id, this.name, {required this.regionHint, required this.bucketHint, required this.keyIdLabel, required this.secretLabel});

  static const aliyun = CloudProvider('aliyun', '阿里云 OSS',
      regionHint: 'cn-hangzhou', bucketHint: '存储桶名称，例如 my-notes', keyIdLabel: 'AccessKey ID', secretLabel: 'AccessKey Secret');
  static const tencent = CloudProvider('tencent', '腾讯云 COS',
      regionHint: 'ap-guangzhou', bucketHint: '存储桶名称，带 APPID，例如 my-notes-1250000000', keyIdLabel: 'SecretId', secretLabel: 'SecretKey');
  static const s3 = CloudProvider('s3', '其他 S3 兼容存储',
      regionHint: 'us-east-1（R2 填 auto）', bucketHint: '存储桶名称', keyIdLabel: 'Access Key ID', secretLabel: 'Secret Access Key');
  static const all = [aliyun, tencent, s3];
  static CloudProvider of(String id) => all.firstWhere((e) => e.id == id, orElse: () => aliyun);
}

/// 一套完整的连接信息。
class CloudConfig {
  final String provider;
  final String region;
  final String bucket;
  final String endpoint; // 阿里云 / 腾讯云：可选的自定义域名；其他 S3：服务地址
  final String prefix;
  final String keyId;
  final String secret;
  const CloudConfig({
    required this.provider,
    required this.region,
    required this.bucket,
    this.endpoint = '',
    this.prefix = 'ai-flashcards/',
    required this.keyId,
    required this.secret,
  });

  static Future<CloudConfig> fromSettings(Settings s) async => CloudConfig(
        provider: s.cloudProvider,
        region: s.cloudRegion,
        bucket: s.cloudBucket,
        endpoint: s.cloudEndpoint,
        prefix: s.cloudPrefix,
        keyId: await s.cloudKeyId(),
        secret: await s.cloudSecret(),
      );

  bool get complete => bucket.isNotEmpty && keyId.isNotEmpty && secret.isNotEmpty && (region.isNotEmpty || endpoint.isNotEmpty);

  String get signRegion => region.isNotEmpty ? region : 'us-east-1';

  /// 规范化的对象前缀：不以 / 开头，以 / 结尾（空 = 存储桶根目录）。
  String get cleanPrefix {
    var x = prefix.trim().replaceAll(RegExp(r'^/+'), '');
    if (x.isNotEmpty && !x.endsWith('/')) x = '$x/';
    return x;
  }

  Uri _endpointUri() {
    var e = endpoint.trim();
    if (!e.contains('://')) e = 'https://$e';
    return Uri.parse(e.replaceAll(RegExp(r'/+$'), ''));
  }

  /// 对象的完整地址。阿里云 / 腾讯云用虚拟主机风格（存储桶在域名里）；
  /// 填了自定义域名时直接用该域名；其他 S3 兼容服务用路径风格（MinIO / R2 都支持）。
  Uri objectUri(String key, {Map<String, String> query = const {}}) {
    final path = '/$key';
    if (provider == 's3') {
      final u = _endpointUri();
      return u.replace(path: '/$bucket$path', queryParameters: query.isEmpty ? null : query);
    }
    if (endpoint.isNotEmpty) {
      final u = _endpointUri();
      return u.replace(path: path, queryParameters: query.isEmpty ? null : query);
    }
    final host = provider == 'tencent' ? '$bucket.cos.$region.myqcloud.com' : '$bucket.s3.oss-$region.aliyuncs.com';
    return Uri(scheme: 'https', host: host, path: path, queryParameters: query.isEmpty ? null : query);
  }
}

/// 最小的 S3 对象客户端：上传、下载、查询、删除。HTTP 客户端可注入，便于测试。
class S3Client {
  final CloudConfig config;
  final http.Client client;
  final DateTime Function() clock;
  S3Client(this.config, {http.Client? client, DateTime Function()? clock})
      : client = client ?? http.Client(),
        clock = clock ?? DateTime.now;

  S3SigV4 get _signer => S3SigV4(accessKey: config.keyId, secretKey: config.secret, region: config.signRegion);

  static String _hostHeader(Uri u) => u.hasPort && u.port != 443 && u.port != 80 ? '${u.host}:${u.port}' : u.host;

  Map<String, String> _signed(String method, Uri u, {Map<String, String> headers = const {}, String payloadHash = S3SigV4.emptyHash}) =>
      _signer.sign(
        method: method,
        host: _hostHeader(u),
        path: u.path,
        query: u.queryParameters,
        headers: headers,
        payloadHash: payloadHash,
        now: clock(),
      );

  /// 上传一个文件。[sha256Hex] 为文件的 SHA-256（签名需要，也用来校验）。
  Future<void> putFile(String key, File file, {required String sha256Hex, String? contentType, void Function(int sent, int total)? onProgress}) async {
    final u = config.objectUri(key);
    final len = await file.length();
    final headers = {'content-type': contentType ?? _mime(key)};
    final signed = _signed('PUT', u, headers: headers, payloadHash: sha256Hex);
    final req = http.StreamedRequest('PUT', u)
      ..contentLength = len
      ..headers.addAll(signed);
    var sent = 0;
    unawaited(file.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(sent, len);
      return chunk;
    }).pipe(req.sink).catchError((_) {}));
    final res = await _send(req);
    await _check(res, '上传');
  }

  /// 下载对象到 [dest]（先写临时文件，完整后再改名，不会留下半个文件）。
  Future<void> getFile(String key, File dest, {void Function(int received, int total)? onProgress}) async {
    final u = config.objectUri(key);
    final req = http.Request('GET', u)..headers.addAll(_signed('GET', u));
    final res = await _send(req);
    if (res.statusCode != 200) await _check(res, '下载');
    await dest.parent.create(recursive: true);
    final tmp = File('${dest.path}.part');
    final sink = tmp.openWrite();
    var got = 0;
    final total = res.contentLength ?? 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      await sink.flush();
    } catch (e) {
      await sink.close();
      if (await tmp.exists()) await tmp.delete();
      throw CloudException('下载中断：$e');
    }
    await sink.close();
    if (await dest.exists()) await dest.delete();
    await tmp.rename(dest.path);
  }

  /// 对象是否存在；存在时返回大小（字节）。
  Future<int?> head(String key) async {
    final u = config.objectUri(key);
    final req = http.Request('HEAD', u)..headers.addAll(_signed('HEAD', u));
    final res = await _send(req);
    if (res.statusCode == 404) return null;
    await _check(res, '查询');
    return int.tryParse(res.headers['content-length'] ?? '') ?? 0;
  }

  Future<void> delete(String key) async {
    final u = config.objectUri(key);
    final req = http.Request('DELETE', u)..headers.addAll(_signed('DELETE', u));
    final res = await _send(req);
    if (res.statusCode == 404) return;
    await _check(res, '删除');
  }

  /// 测试连接：上传一个很小的测试文件、确认存在、再删除。三步都成功才算配置正确。
  Future<void> test(Directory tmpDir) async {
    final key = '${config.cleanPrefix}.connection-test';
    final f = File(p.join(tmpDir.path, 'cloud_test.txt'));
    await f.parent.create(recursive: true);
    await f.writeAsString('ai-flashcards ${DateTime.now().toIso8601String()}');
    final bytes = await f.readAsBytes();
    try {
      await putFile(key, f, sha256Hex: sha256.convert(bytes).toString(), contentType: 'text/plain');
      final size = await head(key);
      if (size == null) throw CloudException('上传后找不到测试文件，请检查存储桶和地域');
      await delete(key);
    } finally {
      if (await f.exists()) await f.delete();
    }
  }

  Future<http.StreamedResponse> _send(http.BaseRequest req) async {
    try {
      return await client.send(req).timeout(const Duration(minutes: 10));
    } on TimeoutException {
      throw CloudException('连接云端超时，请检查网络');
    } on SocketException {
      throw CloudException('连不上云端：请检查网络、地域和存储桶名称');
    } on HandshakeException {
      throw CloudException('HTTPS 连接失败：如果用的是自定义域名，请确认已配置 SSL 证书');
    } on http.ClientException catch (e) {
      throw CloudException('连不上云端：${e.message}');
    }
  }

  static Future<void> _check(http.StreamedResponse res, String action) async {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      await res.stream.drain<void>();
      return;
    }
    final body = await res.stream.bytesToString().catchError((_) => '');
    throw CloudException('$action失败：${explainError(res.statusCode, body)}');
  }

  /// 把服务端的 XML 错误翻译成用户看得懂的话。
  static String explainError(int status, String body) {
    final code = RegExp(r'<Code>([^<]+)</Code>').firstMatch(body)?.group(1) ?? '';
    final msg = RegExp(r'<Message>([^<]+)</Message>').firstMatch(body)?.group(1) ?? '';
    final hint = switch (code) {
      'SignatureDoesNotMatch' => '签名不匹配：AccessKey Secret 不对，或手机时间不准',
      'InvalidAccessKeyId' => 'AccessKey ID 不存在或已被禁用',
      'NoSuchBucket' => '存储桶不存在：检查名称和地域是否对应',
      'AccessDenied' => '没有权限：请给这个 AccessKey 授予该存储桶的读写权限',
      'RequestTimeTooSkewed' => '手机时间与服务器相差太大，请打开自动设置时间',
      'InvalidBucketName' => '存储桶名称格式不对',
      'PermanentRedirect' || 'AuthorizationHeaderMalformed' => '地域填写不对，请改成存储桶实际所在的地域',
      'SecondLevelDomainForbidden' => '阿里云要求用自定义域名访问这个存储桶，请在「自定义域名」里填写已绑定的域名',
      _ => '',
    };
    if (hint.isNotEmpty) return hint;
    if (status == 403) return '没有权限（403）${code.isEmpty ? '' : '：$code'}';
    if (status == 404) return '找不到（404）${code.isEmpty ? '' : '：$code'}';
    return 'HTTP $status${code.isEmpty ? '' : ' $code'}${msg.isEmpty ? '' : '：$msg'}';
  }

  static String _mime(String key) {
    final e = p.extension(key).toLowerCase();
    return switch (e) {
      '.pdf' => 'application/pdf',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.txt' => 'text/plain; charset=utf-8',
      '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.doc' => 'application/msword',
      _ => 'application/octet-stream',
    };
  }
}

/// 本机 / 云端空间占用。
class CloudUsage {
  final Map<String, int> localBytes; // kind -> 本机占用
  final Map<String, int> cloudBytes; // kind -> 云端占用
  final int releasable; // 可以释放的本机空间（已解析的资料、照片、导出、备份）
  final int releasableCount;
  final int offloadedCount;
  final int cacheBytes; // 下载回来的临时副本
  CloudUsage(this.localBytes, this.cloudBytes, this.releasable, this.releasableCount, this.offloadedCount, this.cacheBytes);
  int get localTotal => localBytes.values.fold(0, (a, b) => a + b);
  int get cloudTotal => cloudBytes.values.fold(0, (a, b) => a + b);
}

/// 释放空间的结果。
class ReleaseResult {
  int files = 0;
  int bytes = 0;
  final errors = <String>[];
}

/// 业务层：哪些文件能放到云端、释放空间、按需下载、缓存上限。
class CloudStorageService {
  final Repository repo;
  final Settings settings;
  final Directory appDir;
  final S3Client Function(CloudConfig)? clientFactory;
  CloudStorageService({required this.repo, required this.settings, required this.appDir, this.clientFactory});

  Future<S3Client> _client() async {
    final c = await CloudConfig.fromSettings(settings);
    if (!c.complete) throw CloudException('还没有配置云端存储：请到「我的 → 云端存储」填写存储桶和 AccessKey');
    return clientFactory?.call(c) ?? S3Client(c);
  }

  Future<bool> configured() => settings.cloudConfigured();

  /// 资料文件对应的记录（没有就按当前文件新建一条）。
  Future<MediaAsset> assetForDoc(PdfDoc d) async {
    final id = MediaAsset.docId(d.id);
    final old = await repo.mediaAsset(id);
    if (old != null) {
      if (old.localPath != d.path && d.path.isNotEmpty) {
        old.localPath = d.path;
        await repo.saveMedia(old);
      }
      return old;
    }
    final f = File(d.path);
    final m = MediaAsset(
      id: id,
      projectId: d.projectId,
      kind: 'doc',
      ownerId: d.id,
      localPath: d.path,
      fileName: '${d.name}.${d.type}',
      size: await f.exists() ? await f.length() : 0,
    );
    await repo.saveMedia(m);
    return m;
  }

  /// 对象在云端的路径：前缀/类型/项目/文件id_文件名。
  String keyFor(MediaAsset m, String prefix) {
    final name = p.basename(m.localPath).replaceAll(RegExp(r'[\\:*?"<>|\s]+'), '_');
    return '$prefix${m.kind}/${m.projectId.isEmpty ? '_' : m.projectId}/${m.id}_$name';
  }

  static Future<String> fileHash(File f) async => (await sha256.bind(f.openRead()).first).toString();

  /// 上传到云端（已经上传过且内容没变时跳过），不删本地文件。
  Future<MediaAsset> upload(MediaAsset m, {void Function(double)? onProgress}) async {
    final f = File(m.localPath);
    if (!await f.exists()) {
      if (m.inCloud) return m;
      throw CloudException('本机找不到这个文件');
    }
    final client = await _client();
    final hash = await fileHash(f);
    final size = await f.length();
    if (m.inCloud && m.sha256 == hash && await client.head(m.cloudKey) == size) return m;
    final key = keyFor(m, client.config.cleanPrefix);
    await client.putFile(key, f, sha256Hex: hash, onProgress: (s, t) => onProgress?.call(t == 0 ? 1 : s / t));
    // 上传后再确认一次大小，确认无误才算成功
    final remote = await client.head(key);
    if (remote != size) throw CloudException('上传后校验失败（云端 ${remote ?? 0} 字节，本机 $size 字节），本机文件没有删除');
    m
      ..cloudKey = key
      ..sha256 = hash
      ..size = size;
    await repo.saveMedia(m);
    return m;
  }

  /// 释放一个文件的本机空间：先上传并校验，再删除本机文件。
  Future<int> release(MediaAsset m, {void Function(double)? onProgress}) async {
    final f = File(m.localPath);
    if (m.offloaded && !await f.exists()) return 0;
    await upload(m, onProgress: onProgress);
    final size = await f.exists() ? await f.length() : 0;
    if (await f.exists()) await f.delete();
    m
      ..offloaded = true
      ..cached = false;
    await repo.saveMedia(m);
    return size;
  }

  /// 可以释放的文件：解析完的资料（之后只有按章重新解析、识别目录时才需要原文件）、
  /// 笔记照片原图（本机保留缩略图）、导出的 PDF、备份。
  Future<List<MediaAsset>> releasable({String? projectId}) async {
    final out = <MediaAsset>[];
    final projects = projectId == null ? [for (final p in await repo.projects()) p.id] : [projectId];
    for (final pid in projects) {
      for (final d in await repo.docs(pid)) {
        if (d.status != '已解析') continue;
        if (!await File(d.path).exists()) continue;
        out.add(await assetForDoc(d));
      }
    }
    for (final m in await repo.media(projectId: projectId)) {
      if (m.kind == 'doc' || m.kind == 'backup') continue;
      if (await File(m.localPath).exists()) out.add(m);
    }
    if (projectId == null) out.addAll(await _backupAssets());
    return out;
  }

  /// 本机的备份文件（自动备份、导入前的安全备份），按需建记录。
  Future<List<MediaAsset>> _backupAssets() async {
    final dir = Directory(p.join(appDir.path, 'backups'));
    if (!await dir.exists()) return const [];
    final out = <MediaAsset>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.afcbak')) continue;
      final id = 'backup_${p.basenameWithoutExtension(f.path)}';
      var m = await repo.mediaAsset(id);
      if (m == null) {
        m = MediaAsset(id: id, projectId: '', kind: 'backup', localPath: f.path, fileName: p.basename(f.path), size: await f.length());
        await repo.saveMedia(m);
      }
      out.add(m);
    }
    return out;
  }

  /// 放到云端的备份（可以下载回来恢复）。
  Future<List<MediaAsset>> cloudBackups() async {
    final l = (await repo.media(projectId: '')).where((m) => m.kind == 'backup' && m.inCloud).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }

  /// 手动「释放空间」：逐个上传并删除本机文件；单个失败不影响其他文件。
  Future<ReleaseResult> releaseAll(List<MediaAsset> items, {void Function(int done, int total, String name)? onProgress}) async {
    await _client(); // 没配置时直接报错，不开始
    final r = ReleaseResult();
    for (var i = 0; i < items.length; i++) {
      final m = items[i];
      onProgress?.call(i, items.length, m.fileName.isEmpty ? p.basename(m.localPath) : m.fileName);
      try {
        r.bytes += await release(m);
        r.files++;
      } catch (e) {
        r.errors.add('${m.fileName.isEmpty ? p.basename(m.localPath) : m.fileName}：$e');
      }
    }
    onProgress?.call(items.length, items.length, '');
    return r;
  }

  /// 确保文件在本机：在就直接用；已放到云端就下载回原位置（标记为临时副本），然后按缓存上限清理。
  Future<File> ensureLocal(MediaAsset m, {void Function(double)? onProgress}) async {
    final f = File(m.localPath);
    if (await f.exists()) {
      m.lastAccess = DateTime.now();
      await repo.saveMedia(m);
      return f;
    }
    if (!m.inCloud) throw CloudException('找不到原文件，可能已被删除，请重新上传这份资料');
    if (!await configured()) {
      throw CloudException('这个文件已放到云端以节省空间。请先在「我的 → 云端存储」填好存储桶和 AccessKey，再联网下载');
    }
    final client = await _client();
    await client.getFile(m.cloudKey, f, onProgress: (g, t) => onProgress?.call(t == 0 ? 0 : g / t));
    if (m.sha256.isNotEmpty && await fileHash(f) != m.sha256) {
      await f.delete();
      throw CloudException('下载的文件校验失败，请重试');
    }
    m
      ..offloaded = false
      ..cached = true
      ..lastAccess = DateTime.now();
    await repo.saveMedia(m);
    await trimCache(keep: m.id);
    return f;
  }

  /// 资料原文件：解析、按章重新解析、识别目录前调用。
  Future<File> ensureDocLocal(PdfDoc d, {void Function(double)? onProgress}) async {
    final f = File(d.path);
    final m = await repo.mediaAsset(MediaAsset.docId(d.id));
    if (m == null) return f; // 从没放到云端：保持原来的行为
    if (m.localPath != d.path && d.path.isNotEmpty) m.localPath = d.path;
    return ensureLocal(m, onProgress: onProgress);
  }

  /// 缓存上限：下载回来的临时副本总大小超过设置值时，按最久没用的顺序删除（云端仍保留）。
  Future<int> trimCache({String? keep}) async {
    final limit = settings.cloudCacheMb * 1024 * 1024;
    final cached = <(MediaAsset, int)>[];
    for (final m in await repo.media()) {
      if (!m.cached || !m.inCloud) continue;
      final f = File(m.localPath);
      if (await f.exists()) cached.add((m, await f.length()));
    }
    var total = cached.fold(0, (a, e) => a + e.$2);
    cached.sort((a, b) => a.$1.lastAccess.compareTo(b.$1.lastAccess));
    var freed = 0;
    for (final (m, size) in cached) {
      if (total <= limit) break;
      if (m.id == keep) continue;
      await File(m.localPath).delete();
      m
        ..offloaded = true
        ..cached = false;
      await repo.saveMedia(m);
      total -= size;
      freed += size;
    }
    return freed;
  }

  /// 清空全部临时副本。
  Future<int> clearCache() async {
    var freed = 0;
    for (final m in await repo.media()) {
      if (!m.cached || !m.inCloud) continue;
      final f = File(m.localPath);
      if (await f.exists()) {
        freed += await f.length();
        await f.delete();
      }
      m
        ..offloaded = true
        ..cached = false;
      await repo.saveMedia(m);
    }
    return freed;
  }

  /// 删除云端那份（删除资料 / 项目 / 照片时询问用户后调用）。
  Future<void> deleteRemote(MediaAsset m) async {
    if (!m.inCloud) return;
    final client = await _client();
    await client.delete(m.cloudKey);
    m
      ..cloudKey = ''
      ..offloaded = false
      ..cached = false;
  }

  /// 删除一个文件记录：本机文件、可选的云端文件、记录本身。云端删除失败时抛出，记录保留以便重试。
  Future<void> deleteAsset(MediaAsset m, {bool remote = true}) async {
    if (remote && m.inCloud) await deleteRemote(m);
    for (final path in [m.localPath, m.thumbPath]) {
      if (path.isEmpty) continue;
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
    await repo.deleteMedia(m.id);
  }

  Future<CloudUsage> usage({String? projectId}) async {
    final local = <String, int>{}, cloud = <String, int>{};
    var releasableBytes = 0, releasableCount = 0, offloaded = 0, cache = 0;
    final seenDocs = <String>{};
    for (final m in await repo.media(projectId: projectId)) {
      final f = File(m.localPath);
      final exists = m.localPath.isNotEmpty && await f.exists();
      final size = exists ? await f.length() : m.size;
      if (m.kind == 'doc') seenDocs.add(m.ownerId);
      if (exists) local[m.kind] = (local[m.kind] ?? 0) + size;
      if (m.inCloud) cloud[m.kind] = (cloud[m.kind] ?? 0) + (m.size > 0 ? m.size : size);
      if (!exists && m.offloaded) offloaded++;
      if (exists && m.cached) cache += size;
    }
    // 还没有记录的资料文件（从没上过云）也算进本机占用
    final projects = projectId == null ? [for (final p in await repo.projects()) p.id] : [projectId];
    for (final pid in projects) {
      for (final d in await repo.docs(pid)) {
        if (seenDocs.contains(d.id)) continue;
        final f = File(d.path);
        if (d.path.isNotEmpty && await f.exists()) local['doc'] = (local['doc'] ?? 0) + await f.length();
      }
    }
    for (final m in await releasable(projectId: projectId)) {
      final f = File(m.localPath);
      if (await f.exists()) {
        releasableBytes += await f.length();
        releasableCount++;
      }
    }
    return CloudUsage(local, cloud, releasableBytes, releasableCount, offloaded, cache);
  }

  /// 测试当前设置能否连通。
  Future<void> test() async => (await _client()).test(Directory(p.join(appDir.path, 'tmp')));

  /// 接管资料文件读取：解析等流程读原文件前，自动从云端下载回来。
  void installDocResolver() => DocFiles.resolver = (d) => ensureDocLocal(d);
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
