import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/cloud_storage.dart';
import 'package:ai_flashcards/services/doc_files.dart';
import 'package:ai_flashcards/services/s3_signer.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 模拟的 S3 兼容存储桶：每个请求都重新计算签名并校验，签名不对就返回 403。
class FakeBucket {
  final objects = <String, Uint8List>{};
  final requests = <String>[];
  String secret;
  int? forceHeadSize; // 模拟上传后大小不一致
  FakeBucket({this.secret = 'test-secret'});

  MockClient client() => MockClient((req) async {
        requests.add('${req.method} ${req.url.path}');
        final auth = req.headers['authorization'] ?? '';
        final m = RegExp(r'Credential=([^/]+)/(\d{8})/([^/]+)/s3/aws4_request, SignedHeaders=([^,]+), Signature=([0-9a-f]{64})').firstMatch(auth);
        if (m == null) return http.Response('<Error><Code>AccessDenied</Code></Error>', 403);
        final signedNames = m.group(4)!.split(';');
        final amzDate = req.headers['x-amz-date']!;
        final t = DateTime.utc(int.parse(amzDate.substring(0, 4)), int.parse(amzDate.substring(4, 6)), int.parse(amzDate.substring(6, 8)),
            int.parse(amzDate.substring(9, 11)), int.parse(amzDate.substring(11, 13)), int.parse(amzDate.substring(13, 15)));
        final extra = {
          for (final n in signedNames)
            if (!['host', 'x-amz-date', 'x-amz-content-sha256'].contains(n)) n: req.headers[n] ?? '',
        };
        final host = req.url.hasPort && req.url.port != 443 ? '${req.url.host}:${req.url.port}' : req.url.host;
        final expect = S3SigV4(accessKey: m.group(1)!, secretKey: secret, region: m.group(3)!).sign(
            method: req.method,
            host: host,
            path: req.url.path,
            query: req.url.queryParameters,
            headers: extra,
            payloadHash: req.headers['x-amz-content-sha256']!,
            now: t);
        if (expect['authorization'] != auth) {
          return http.Response('<Error><Code>SignatureDoesNotMatch</Code><Message>bad</Message></Error>', 403);
        }
        final key = req.url.path;
        switch (req.method) {
          case 'PUT':
            if (S3SigV4.hashHex(req.bodyBytes) != req.headers['x-amz-content-sha256']) {
              return http.Response('<Error><Code>XAmzContentSHA256Mismatch</Code></Error>', 400);
            }
            objects[key] = req.bodyBytes;
            return http.Response('', 200);
          case 'GET':
            final o = objects[key];
            return o == null ? http.Response('<Error><Code>NoSuchKey</Code></Error>', 404) : http.Response.bytes(o, 200);
          case 'HEAD':
            final o = objects[key];
            if (o == null) return http.Response('', 404);
            return http.Response('', 200, headers: {'content-length': '${forceHeadSize ?? o.length}'});
          case 'DELETE':
            objects.remove(key);
            return http.Response('', 204);
        }
        return http.Response('', 405);
      });
}

void main() {
  group('S3 SigV4 签名', () {
    final t = DateTime.utc(2026, 11, 24, 8, 30, 0);
    final signer = S3SigV4(accessKey: 'AKIDEXAMPLE', secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', region: 'ap-guangzhou');

    // 期望值由 botocore（AWS 官方 Python SDK）对同样的请求计算得出
    test('腾讯云 COS GET（中文对象名、空格）与 botocore 一致', () {
      final h = signer.sign(
          method: 'GET', host: 'my-bucket-1250000000.cos.ap-guangzhou.myqcloud.com', path: '/ai-flashcards/docs/p1/高数 第1章.pdf', now: t);
      expect(h['authorization'],
          'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261124/ap-guangzhou/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=01191ebc2eb7247354b4c2f4bc5d803175c9cd296c795b794731288fad864628');
      expect(h['x-amz-date'], '20261124T083000Z');
      expect(h.containsKey('host'), isFalse);
    });

    test('阿里云 OSS PUT（带 Content-Type 和请求体哈希）与 botocore 一致', () {
      final s = S3SigV4(accessKey: 'AKIDEXAMPLE', secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', region: 'cn-hangzhou');
      final h = s.sign(
          method: 'PUT',
          host: 'notes.s3.oss-cn-hangzhou.aliyuncs.com',
          path: '/ai-flashcards/photo/a.jpg',
          headers: {'Content-Type': 'image/jpeg'},
          payloadHash: S3SigV4.hashHex('hello oss'.codeUnits),
          now: t);
      expect(h['authorization'],
          'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261124/cn-hangzhou/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=45cd72ec0c4b7122e6e34023bb2bc5852b687efc00bdf6782a08b0c94bd5c21b');
    });

    test('S3 兼容（端口 + 查询参数）与 botocore 一致', () {
      final s = S3SigV4(accessKey: 'AKIDEXAMPLE', secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', region: 'us-east-1');
      final h = s.sign(
          method: 'GET', host: 'minio.example.com:9000', path: '/bucket/', query: {'list-type': '2', 'prefix': 'ai-flashcards/'}, now: t);
      expect(h['authorization'],
          'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261124/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=0d916441d55d9dd0b842b08f3f041bd71de42591a55fe99991e517b6c874350d');
    });
  });

  test('各服务商的对象地址', () {
    CloudConfig c(String provider, {String endpoint = '', String region = 'cn-hangzhou'}) =>
        CloudConfig(provider: provider, region: region, bucket: 'bk', endpoint: endpoint, keyId: 'a', secret: 'b');
    expect(c('aliyun').objectUri('ai-flashcards/x.pdf').toString(), 'https://bk.s3.oss-cn-hangzhou.aliyuncs.com/ai-flashcards/x.pdf');
    expect(c('tencent', region: 'ap-guangzhou').objectUri('a/b.jpg').toString(), 'https://bk.cos.ap-guangzhou.myqcloud.com/a/b.jpg');
    expect(c('aliyun', endpoint: 'files.example.com').objectUri('a/b.jpg').toString(), 'https://files.example.com/a/b.jpg');
    expect(c('s3', endpoint: 'http://minio.local:9000/', region: '').objectUri('a/b.jpg').toString(), 'http://minio.local:9000/bk/a/b.jpg');
    expect(c('s3', endpoint: 'x', region: '').signRegion, 'us-east-1');
    expect(CloudConfig(provider: 'aliyun', region: 'r', bucket: 'b', prefix: '/notes', keyId: 'a', secret: 'b').cleanPrefix, 'notes/');
  });

  test('错误翻译成中文提示', () {
    expect(S3Client.explainError(403, '<Error><Code>SignatureDoesNotMatch</Code></Error>'), contains('AccessKey Secret'));
    expect(S3Client.explainError(404, '<Error><Code>NoSuchBucket</Code></Error>'), contains('存储桶不存在'));
    expect(S3Client.explainError(403, '<Error><Code>SecondLevelDomainForbidden</Code></Error>'), contains('自定义域名'));
    expect(S3Client.explainError(500, ''), 'HTTP 500');
  });

  group('释放空间 / 按需下载', () {
    late AppState s;
    late FakeBucket bucket;
    late Directory dir;
    late PdfDoc doc;
    final content = Uint8List.fromList(List.generate(50000, (i) => (i * 31) % 256));

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'cloud_provider': 'tencent',
        'cloud_region': 'ap-guangzhou',
        'cloud_bucket': 'notes-1250000000',
      });
      final secrets = MemorySecretStore();
      s = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), secrets));
      dir = await Directory.systemTemp.createTemp('afc_cloud');
      s.appDirOverride = dir;
      bucket = FakeBucket();
      s.cloudClientFactory = (c) => S3Client(c, client: bucket.client());
      await s.settings.setCloudKeyId('AKID-test');
      await s.settings.setCloudSecret('test-secret');
      final f = File('${dir.path}/pdfs/d1.pdf');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(content);
      doc = PdfDoc(id: 'd1', projectId: 'p1', name: '高数 第1章', path: f.path, status: '已解析', pageCount: 3, parsedPages: 3);
      await s.repo.saveProject(Project(id: 'p1', name: '高数'));
      await s.repo.saveDoc(doc);
    });

    tearDown(() => DocFiles.resolver = null);

    test('没配置时不显示可用，操作给出明确提示', () async {
      await s.settings.setCloudSecret('');
      final c = await s.cloud();
      expect(await c.configured(), isFalse);
      await expectLater(c.releaseAll(await c.releasable()), throwsA(isA<CloudException>().having((e) => e.message, 'm', contains('还没有配置'))));
      // 没放到云端的资料照常读取
      expect((await DocFiles.read(doc)).length, content.length);
    });

    test('释放 → 本机删除、云端有一份 → 解析时自动下载回来且内容一致', () async {
      final c = await s.cloud();
      final items = await c.releasable(projectId: 'p1');
      expect(items.single.id, 'doc_d1');
      final u0 = await c.usage();
      expect(u0.releasable, content.length);

      final r = await c.releaseAll(items);
      expect(r.errors, isEmpty);
      expect(r.files, 1);
      expect(r.bytes, content.length);
      expect(File(doc.path).existsSync(), isFalse);
      final m = (await s.repo.mediaAsset('doc_d1'))!;
      expect(m.offloaded, isTrue);
      expect(m.cloudKey, startsWith('ai-flashcards/doc/p1/doc_d1_'));
      expect(bucket.objects.values.single, content);
      expect(m.stateLabel, '仅云端');
      final u1 = await c.usage();
      expect(u1.offloadedCount, 1);
      expect(u1.cloudTotal, content.length);
      expect(u1.releasable, 0);

      // 读取原文件（解析 / 按章重新解析都走这里）：自动下载
      final bytes = await DocFiles.read(doc);
      expect(bytes, content);
      final m2 = (await s.repo.mediaAsset('doc_d1'))!;
      expect(m2.cached, isTrue);
      expect(m2.offloaded, isFalse);

      // 再次释放不重复上传
      final puts = bucket.requests.where((x) => x.startsWith('PUT')).length;
      await c.release(m2);
      expect(bucket.requests.where((x) => x.startsWith('PUT')).length, puts);
      expect(File(doc.path).existsSync(), isFalse);
    });

    test('上传后校验不通过：本机文件保留', () async {
      bucket.forceHeadSize = 10;
      final c = await s.cloud();
      final r = await c.releaseAll(await c.releasable());
      expect(r.files, 0);
      expect(r.errors.single, contains('校验失败'));
      expect(File(doc.path).existsSync(), isTrue);
      expect((await s.repo.mediaAsset('doc_d1'))!.offloaded, isFalse);
    });

    test('签名错误（密钥不对）给出中文原因，本机文件不动', () async {
      bucket.secret = 'another-secret';
      final c = await s.cloud();
      final r = await c.releaseAll(await c.releasable());
      expect(r.errors.single, contains('AccessKey Secret'));
      expect(File(doc.path).existsSync(), isTrue);
    });

    test('缓存上限：下载回来的临时副本超过上限时清理最久没用的', () async {
      s.settings.cloudCacheMb = 50; // 最小 50 MB
      final c = await s.cloud();
      await c.releaseAll(await c.releasable());
      await DocFiles.read(doc);
      expect(await c.trimCache(), 0); // 没超过上限
      expect(await c.clearCache(), content.length);
      expect(File(doc.path).existsSync(), isFalse);
      expect((await s.repo.mediaAsset('doc_d1'))!.offloaded, isTrue);
    });

    test('测试连接：上传、确认、删除测试文件', () async {
      final c = await s.cloud();
      await c.test();
      expect(bucket.requests, ['PUT /ai-flashcards/.connection-test', 'HEAD /ai-flashcards/.connection-test', 'DELETE /ai-flashcards/.connection-test']);
      expect(bucket.objects, isEmpty);
    });

    test('删除资料时可以一起删除云端文件', () async {
      final c = await s.cloud();
      await c.releaseAll(await c.releasable());
      expect(await s.cloudFileCount(projectId: 'p1'), 1);
      await s.deleteDocEverywhere(doc, remote: true);
      expect(bucket.objects, isEmpty);
      expect(await s.repo.mediaAsset('doc_d1'), isNull);
      expect(await s.repo.docs('p1'), isEmpty);
    });

    test('本机备份文件也可以放到云端，之后可下载回来恢复', () async {
      final b = File('${dir.path}/backups/auto_20261124.afcbak');
      await b.parent.create(recursive: true);
      await b.writeAsBytes([1, 2, 3, 4]);
      final c = await s.cloud();
      final items = await c.releasable();
      expect(items.map((m) => m.kind), containsAll(['doc', 'backup']));
      expect((await c.releasable(projectId: 'p1')).map((m) => m.kind), isNot(contains('backup')));
      await c.releaseAll(items);
      expect(b.existsSync(), isFalse);
      final cloud = await c.cloudBackups();
      expect(cloud.single.fileName, 'auto_20261124.afcbak');
      expect((await c.ensureLocal(cloud.single)).readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('已放到云端但没配置：提示先配置', () async {
      final c = await s.cloud();
      await c.releaseAll(await c.releasable());
      await s.settings.setCloudKeyId('');
      await expectLater(DocFiles.read(doc), throwsA(isA<CloudException>().having((e) => e.message, 'm', contains('云端存储'))));
    });
  });

  test('DocStore 新集合在内存实现里可用', () async {
    final st = MemoryDocStore();
    await st.put('media', 'x', 'p', {'id': 'x'});
    expect((await st.rows('media')).length, 1);
  });
}
