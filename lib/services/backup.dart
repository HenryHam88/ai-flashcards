import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/doc_store.dart';
import 'settings.dart';

/// 闪卡刷题自己的备份格式（.afcbak，本质是 zip）。
///
/// ```
/// manifest.json          版本、数量、各文件 SHA-256、总校验和
/// data/<集合>.json        数据库原样导出：[{id, projectId, data}]
/// settings.json          不含密钥的设置（仅整机备份）
/// secrets.json           API 密钥（仅在用户勾选「包含 API 密钥」时）
/// files/<docId>/<文件名>  原始 PDF / Word（可选）
/// files/<photo_id>/<文件名> 笔记照片（可选，v7）
/// 云端存储的 AccessKey 永远不会写进备份。
/// ```
class BackupFormat {
  static const ext = 'afcbak';
  static const format = 'afcbak';
  static const formatVersion = 1;
}

class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => message;
}

class BackupOptions {
  final bool includeFiles;
  final bool includeSecrets;
  final bool includeProgress; // 单项目分享时可以不带学习进度
  const BackupOptions({this.includeFiles = false, this.includeSecrets = false, this.includeProgress = true});
}

/// 读出来的备份摘要（导入前给用户确认用）。
class BackupInfo {
  final Map<String, dynamic> manifest;
  final Map<String, List<StoreRow>> data;
  final Map<String, dynamic> settings;
  final Map<String, dynamic> secrets;
  final Map<String, Uint8List> files; // 'docId/文件名' -> bytes
  BackupInfo(this.manifest, this.data, this.settings, this.secrets, this.files);

  String get appVersion => manifest['appVersion'] ?? '';
  int get schemaVersion => manifest['schemaVersion'] ?? 0;
  DateTime? get createdAt => DateTime.tryParse(manifest['createdAt'] ?? '');
  String get scope => manifest['scope'] ?? 'full';
  bool get includesFiles => manifest['includesFiles'] == true;
  bool get includesSecrets => manifest['includesSecrets'] == true;
  bool get includesProgress => manifest['includesProgress'] != false;
  Map<String, int> get counts => {
        for (final e in ((manifest['counts'] as Map?) ?? {}).entries) e.key.toString(): (e.value as num).toInt()
      };
  int count(String c) => counts[c] ?? 0;
  List<String> get projectNames => [for (final r in data['projects'] ?? const <StoreRow>[]) '${r.$3['name'] ?? ''}'];
}

class ImportResult {
  final Map<String, int> added;
  final Map<String, int> updated;
  final Map<String, int> skipped;
  final String? safetyBackup;
  ImportResult(this.added, this.updated, this.skipped, this.safetyBackup);
  int get addedTotal => added.values.fold(0, (a, b) => a + b);
}

enum ImportMode { overwrite, merge }

class BackupService {
  final DocStore store;
  final Settings settings;
  final Directory appDir; // 应用文档目录：原始文件在 pdfs/，备份在 backups/
  final String appVersion;
  BackupService({required this.store, required this.settings, required this.appDir, required this.appVersion});

  Directory get backupDir => Directory(p.join(appDir.path, 'backups'));
  Directory get filesDir => Directory(p.join(appDir.path, 'pdfs'));
  Directory get mediaDir => Directory(p.join(appDir.path, 'media'));

  /// 备份里要带上的原始文件：资料文件 + 笔记照片（只算本机还在的）。key = 'id/文件名'。
  Future<Map<String, File>> _originalFiles(String? projectId) async {
    final out = <String, File>{};
    for (final r in await store.rows('docs', projectId: projectId)) {
      final f = File('${r.$3['path'] ?? ''}');
      if (await f.exists()) out['${r.$1}/${p.basename(f.path)}'] = f;
    }
    for (final r in await store.rows('media', projectId: projectId)) {
      if (r.$3['kind'] != 'photo') continue;
      final f = File('${r.$3['localPath'] ?? ''}');
      if (await f.exists()) out['${r.$1}/${p.basename(f.path)}'] = f;
    }
    return out;
  }

  static String fileName({String? projectName, DateTime? at}) {
    final t = at ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
    if (projectName != null) {
      final safe = projectName.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
      return '闪卡刷题项目_${safe}_$stamp.${BackupFormat.ext}';
    }
    return '闪卡刷题备份_$stamp.${BackupFormat.ext}';
  }

  // ---------------------------------------------------------------- 导出

  /// 原始文件总大小（字节），用于在导出页显示「约 xx MB」。
  Future<int> originalFilesSize({String? projectId}) async {
    var total = 0;
    for (final f in (await _originalFiles(projectId)).values) {
      total += await f.length();
    }
    return total;
  }

  /// 数据库部分大致大小（JSON 字节数），用于估算。
  Future<int> dataSize({String? projectId}) async {
    var total = 0;
    for (final c in DocStore.allCollections) {
      for (final r in await store.rows(c, projectId: projectId)) {
        total += jsonEncode(r.$3).length;
      }
    }
    return total ~/ 4; // zip 压缩后通常只有 1/4 左右
  }

  Future<Uint8List> export({String? projectId, BackupOptions options = const BackupOptions()}) async {
    final entries = <String, List<int>>{};
    final counts = <String, int>{};
    for (final c in DocStore.allCollections) {
      var rows = projectId == null
          ? await store.rows(c)
          : c == 'projects'
              ? (await store.rows(c)).where((r) => r.$1 == projectId).toList()
              : await store.rows(c, projectId: projectId);
      if (!options.includeProgress) rows = _stripProgress(c, rows);
      if (rows.isEmpty && c != 'projects') continue;
      counts[c] = rows.length;
      entries['data/$c.json'] =
          utf8.encode(jsonEncode([for (final r in rows) {'id': r.$1, 'projectId': r.$2, 'data': r.$3}]));
    }
    if (projectId != null && (counts['projects'] ?? 0) == 0) throw BackupException('找不到这个项目');
    if (projectId == null) entries['settings.json'] = utf8.encode(jsonEncode(settings.exportPrefs()));
    if (options.includeSecrets) entries['secrets.json'] = utf8.encode(jsonEncode(await settings.exportSecrets()));
    var files = 0;
    if (options.includeFiles) {
      for (final e in (await _originalFiles(projectId)).entries) {
        entries['files/${e.key}'] = await e.value.readAsBytes();
        files++;
      }
    }
    final checksums = {for (final e in entries.entries) e.key: sha256.convert(e.value).toString()};
    final manifest = {
      'format': BackupFormat.format,
      'formatVersion': BackupFormat.formatVersion,
      'app': '闪卡刷题',
      'appVersion': appVersion,
      'schemaVersion': SqliteDocStore.schemaVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'scope': projectId == null ? 'full' : 'project',
      'projectId': ?projectId,
      'includesFiles': options.includeFiles,
      'includesSecrets': options.includeSecrets,
      'includesProgress': options.includeProgress,
      'counts': {...counts, 'files': files},
      'files': checksums,
      'checksum': _total(checksums),
    };
    final archive = Archive();
    archive.addFile(ArchiveFile.string('manifest.json', const JsonEncoder.withIndent('  ').convert(manifest)));
    for (final e in entries.entries) {
      archive.addFile(ArchiveFile.bytes(e.key, e.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static String _total(Map<String, String> checksums) {
    final keys = checksums.keys.toList()..sort();
    return sha256.convert(utf8.encode(keys.map((k) => '$k:${checksums[k]}').join('\n'))).toString();
  }

  /// 不带学习进度：去掉复习记录、错题、解释历史以外的个人状态，卡片重置为新卡。
  static List<StoreRow> _stripProgress(String c, List<StoreRow> rows) {
    if (c == 'logs' || c == 'wrong') return const [];
    if (c != 'cards') return rows;
    final now = DateTime.now().toIso8601String();
    return [
      for (final r in rows)
        (r.$1, r.$2, {
          ...r.$3,
          'stability': 0.0,
          'difficulty': 0.0,
          'reps': 0,
          'lapses': 0,
          'due': now,
          'lastReview': null,
        })
    ];
  }

  // ---------------------------------------------------------------- 读取与校验

  /// 解析并校验备份文件；损坏、被改动、版本太新都会抛 [BackupException]。
  BackupInfo read(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      throw BackupException('文件已损坏或不是闪卡刷题的备份文件');
    }
    final files = {for (final f in archive.files) if (f.isFile) f.name: f};
    final mf = files['manifest.json'];
    if (mf == null) throw BackupException('不是闪卡刷题的备份文件（缺少 manifest.json）');
    final Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(utf8.decode(mf.content)) as Map<String, dynamic>;
    } catch (_) {
      throw BackupException('备份清单已损坏');
    }
    if (manifest['format'] != BackupFormat.format) throw BackupException('不是闪卡刷题的备份文件');
    final fv = (manifest['formatVersion'] as num?)?.toInt() ?? 0;
    final sv = (manifest['schemaVersion'] as num?)?.toInt() ?? 0;
    if (fv > BackupFormat.formatVersion || sv > SqliteDocStore.schemaVersion) {
      throw BackupException('这个备份来自更新版本的闪卡刷题（${manifest['appVersion'] ?? '未知版本'}），请先把应用升级到最新版再导入');
    }
    if (sv < 1) throw BackupException('备份版本信息缺失');
    final checksums = {
      for (final e in ((manifest['files'] as Map?) ?? {}).entries) e.key.toString(): e.value.toString()
    };
    if (_total(checksums) != manifest['checksum']) throw BackupException('校验失败：备份清单被修改过或已损坏');
    final content = <String, Uint8List>{};
    for (final e in checksums.entries) {
      final f = files[e.key];
      if (f == null) throw BackupException('备份不完整：缺少 ${e.key}');
      final b = Uint8List.fromList(f.content);
      if (sha256.convert(b).toString() != e.value) throw BackupException('校验失败：${e.key} 已损坏');
      content[e.key] = b;
    }
    final data = <String, List<StoreRow>>{};
    for (final e in content.entries.where((e) => e.key.startsWith('data/'))) {
      final c = p.basenameWithoutExtension(e.key);
      final l = jsonDecode(utf8.decode(e.value)) as List;
      data[c] = [
        for (final r in l.cast<Map>())
          ('${r['id']}', '${r['projectId'] ?? ''}', Map<String, dynamic>.from(r['data'] as Map))
      ];
    }
    migrateRows(data, sv);
    Map<String, dynamic> js(String k) =>
        content[k] == null ? {} : jsonDecode(utf8.decode(content[k]!)) as Map<String, dynamic>;
    return BackupInfo(manifest, data, js('settings.json'), js('secrets.json'), {
      for (final e in content.entries)
        if (e.key.startsWith('files/')) e.key.substring(6): e.value
    });
  }

  /// 旧版本备份的数据结构升级到当前版本（与数据库 onUpgrade 保持一致）。
  static void migrateRows(Map<String, List<StoreRow>> data, int from) {
    if (from < 2) {
      for (final r in data['docs'] ?? const <StoreRow>[]) {
        r.$3['type'] ??= 'pdf';
      }
    }
    if (from < 4) {
      final now = DateTime.now().toIso8601String();
      for (final r in data['explain'] ?? const <StoreRow>[]) {
        r.$3['createdAt'] ??= now;
        r.$3['updatedAt'] ??= r.$3['createdAt'];
      }
    }
  }

  // ---------------------------------------------------------------- 导入

  Future<ImportResult> import(BackupInfo info, ImportMode mode, {bool restoreSecrets = false}) async {
    String? safety;
    if (mode == ImportMode.overwrite) {
      // 覆盖前先给当前数据做一份安全备份（不含原文件，原文件不会被删除）
      safety = await saveLocal(await export(), prefix: 'safety');
    }
    final added = <String, int>{}, updated = <String, int>{}, skipped = <String, int>{};
    final puts = <(String, StoreRow)>[];
    // 原始文件先落盘（写到新文件，不覆盖现有文件），并改写资料路径
    final pathFor = <String, String>{};
    for (final e in info.files.entries) {
      final docId = e.key.split('/').first;
      final dir = docId.startsWith('photo_') ? mediaDir : filesDir;
      final dest = File(p.join(dir.path, '${docId}_${p.basename(e.key)}'));
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(e.value, flush: true);
      pathFor[docId] = dest.path;
    }
    for (final c in DocStore.allCollections) {
      final incoming = info.data[c] ?? const <StoreRow>[];
      final existing = mode == ImportMode.merge
          ? {for (final r in await store.rows(c)) r.$1: r}
          : <String, StoreRow>{};
      for (var r in incoming) {
        if (c == 'docs') {
          final path = pathFor[r.$1] ?? _relocate('${r.$3['path'] ?? ''}');
          r = (r.$1, r.$2, {...r.$3, 'path': path});
        } else if (c == 'media') {
          // 资料文件跟着资料走；照片落到本机的照片目录。云端那份（cloudKey）不变，配置同一个存储桶后可以重新下载。
          final ownerId = '${r.$3['ownerId'] ?? ''}';
          final path = r.$3['kind'] == 'doc'
              ? (pathFor[ownerId] ?? _relocate('${r.$3['localPath'] ?? ''}'))
              : (pathFor[r.$1] ?? (r.$3['localPath'] == null || '${r.$3['localPath']}'.isEmpty
                  ? ''
                  : p.join(mediaDir.path, p.basename('${r.$3['localPath']}'))));
          final exists = path.isNotEmpty && File(path).existsSync();
          r = (r.$1, r.$2, {...r.$3, 'localPath': path, 'offloaded': !exists && '${r.$3['cloudKey'] ?? ''}'.isNotEmpty});
        }
        final old = existing[r.$1];
        if (old == null) {
          puts.add((c, r));
          added[c] = (added[c] ?? 0) + 1;
        } else if (_incomingWins(c, old.$3, r.$3)) {
          puts.add((c, r));
          updated[c] = (updated[c] ?? 0) + 1;
        } else {
          skipped[c] = (skipped[c] ?? 0) + 1;
        }
      }
    }
    final full = info.scope == 'full';
    // 单项目备份的「覆盖」只替换同一个项目，不动其他项目
    final deletes = <(String, String)>[];
    if (!full && mode == ImportMode.overwrite) {
      final pids = {for (final r in info.data['projects'] ?? const <StoreRow>[]) r.$1};
      for (final c in DocStore.allCollections) {
        for (final pid in pids) {
          for (final r in await store.rows(c, projectId: pid)) {
            deletes.add((c, r.$1));
          }
        }
      }
    }
    await store.applyAtomic(
        clear: full && mode == ImportMode.overwrite ? DocStore.allCollections : const [], deletes: deletes, puts: puts);
    if (full && mode == ImportMode.overwrite) await settings.importPrefs(info.settings);
    if (restoreSecrets && info.secrets.isNotEmpty) await settings.importSecrets(info.secrets);
    return ImportResult(added, updated, skipped, safety);
  }

  /// 换手机后应用目录可能不同：按文件名映射到本机的资料目录。
  String _relocate(String oldPath) => oldPath.isEmpty ? '' : p.join(filesDir.path, p.basename(oldPath));

  /// 合并时同一 id 的记录谁留下：卡片保留复习更新的 FSRS 状态；解释保留对话更长 / 更新的；其他一律跳过重复。
  static bool _incomingWins(String c, Map<String, dynamic> old, Map<String, dynamic> neu) {
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v) : null;
    if (c == 'cards') {
      final a = t(old['lastReview']), b = t(neu['lastReview']);
      if (b == null) return false;
      if (a == null) return true;
      if (b.isAfter(a)) return true;
      return b.isAtSameMomentAs(a) && (neu['reps'] ?? 0) > (old['reps'] ?? 0);
    }
    if (c == 'explain') {
      final a = t(old['updatedAt']), b = t(neu['updatedAt']);
      if (a != null && b != null && b != a) return b.isAfter(a);
      return ((neu['messages'] as List?)?.length ?? 0) > ((old['messages'] as List?)?.length ?? 0);
    }
    return false;
  }

  // ---------------------------------------------------------------- 本机备份（安全备份 / 自动备份）

  Future<String> saveLocal(Uint8List bytes, {required String prefix, int keep = 3}) async {
    await backupDir.create(recursive: true);
    final name = '${prefix}_${fileName().replaceFirst('闪卡刷题备份_', '')}';
    var f = File(p.join(backupDir.path, name));
    var i = 1;
    while (await f.exists()) {
      f = File(p.join(backupDir.path, name.replaceFirst('.${BackupFormat.ext}', '_${i++}.${BackupFormat.ext}')));
    }
    await f.writeAsBytes(bytes, flush: true);
    final all = (await localBackups(prefix: prefix));
    for (final old in all.skip(keep)) {
      await old.delete();
    }
    return f.path;
  }

  Future<List<File>> localBackups({String? prefix}) async {
    if (!await backupDir.exists()) return [];
    final l = backupDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.${BackupFormat.ext}'))
        .where((f) => prefix == null || p.basename(f.path).startsWith('${prefix}_'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return l;
  }

  /// 每周自动备份一次（打开应用时检查），只保留最近 3 份。
  Future<String?> autoBackupIfDue({DateTime? now}) async {
    if (!settings.autoBackup) return null;
    final n = now ?? DateTime.now();
    final last = settings.lastAutoBackup;
    if (last != null && n.difference(last).inDays < 7) return null;
    final path = await saveLocal(await export(), prefix: 'auto');
    settings.lastAutoBackup = n;
    return path;
  }
}
