import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/backup.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';

/// 一台「手机」：独立的数据库、设置、密钥和应用目录。
class Phone {
  final MemoryDocStore store = MemoryDocStore();
  late final Repository repo = Repository(store);
  final MemorySecretStore secrets = MemorySecretStore();
  late Settings settings;
  late Directory dir;
  late BackupService backup;

  static Future<Phone> create(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = Phone();
    p.settings = Settings(await SharedPreferences.getInstance(), p.secrets);
    p.dir = await Directory.systemTemp.createTemp('afc_test');
    p.backup = BackupService(store: p.store, settings: p.settings, appDir: p.dir, appVersion: '1.2.0');
    return p;
  }

  Future<Map<String, List<StoreRow>>> dump() async =>
      {for (final c in DocStore.allCollections) c: (await store.rows(c))..sort((a, b) => a.$1.compareTo(b.$1))};
}

String canon(Map<String, List<StoreRow>> d) =>
    jsonEncode({for (final e in d.entries) e.key: [for (final r in e.value) [r.$1, r.$2, r.$3]]});

Future<void> seedExtras(Phone p) async {
  // 原始文件、错题、复习记录、解释历史、分章方案都要在备份里
  final f = File('${p.dir.path}/pdfs/book.pdf');
  await f.parent.create(recursive: true);
  await f.writeAsBytes(List.generate(2048, (i) => i % 256));
  final d = (await p.repo.docs('p1')).first..path = f.path;
  await p.repo.saveDoc(d);
  final c = (await p.repo.card('c1'))!
    ..reps = 3
    ..lastReview = DateTime(2026, 11, 1);
  await p.repo.saveCards([c]);
  await p.repo.log(LogEntry(id: 'backup_log_1', projectId: 'p1', kind: 'card', correct: true, at: DateTime(2026, 11, 1)));
  await p.repo.saveExplain(ExplainCache(id: 'c1', projectId: 'p1', kind: 'card', title: '什么是条件概率？', messages: [
    {'role': 'user', 'content': 'prompt'},
    {'role': 'assistant', 'content': r'条件概率 $P(A\mid B)$'},
  ]));
  await p.store.put('chapters', 'd1', 'p1', {'id': 'd1', 'docId': 'd1', 'projectId': 'p1', 'source': 'manual', 'chapters': []});
}

void main() {
  test('整机备份 → 新手机覆盖导入：数据完全一致，密钥默认不带', () async {
    final a = await Phone.create({'llm_model': 'deepseek-v4-pro', 'desired_retention': 0.88});
    await seedSampleData(a.repo);
    await seedExtras(a);
    await a.settings.setLlmKey('sk-secret');
    final bytes = await a.backup.export(options: const BackupOptions(includeFiles: true));

    // manifest 内容
    final zip = ZipDecoder().decodeBytes(bytes);
    final m = jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content)) as Map;
    expect(m['format'], 'afcbak');
    expect(m['schemaVersion'], SqliteDocStore.schemaVersion);
    expect(m['appVersion'], '1.2.0');
    expect((m['counts'] as Map)['cards'], (await a.repo.cards()).length);
    expect((m['counts'] as Map)['files'], 1);
    expect(zip.findFile('secrets.json'), isNull);

    final b = await Phone.create({});
    final info = b.backup.read(bytes);
    expect(info.count('projects'), 3);
    expect(info.count('cards'), (await a.repo.cards()).length);
    await b.backup.import(info, ImportMode.overwrite);

    // 原始文件被放到新手机的资料目录，路径改写；其余数据逐字段相同
    final da = await a.dump(), db = await b.dump();
    final docB = db['docs']!.firstWhere((r) => r.$1 == 'd1');
    expect(docB.$3['path'], startsWith(b.dir.path));
    expect(File(docB.$3['path']).readAsBytesSync(), File('${a.dir.path}/pdfs/book.pdf').readAsBytesSync());
    for (final r in [...da['docs']!, ...db['docs']!]) {
      r.$3.remove('path');
    }
    expect(canon(db), canon(da));
    expect(b.settings.llmModel, 'deepseek-v4-pro');
    expect(b.settings.desiredRetention, 0.88);
    expect(await b.settings.llmKey(), isEmpty);
  });

  test('勾选包含 API 密钥时可以一起恢复', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    await a.settings.setLlmKey('sk-secret');
    final bytes = await a.backup.export(options: const BackupOptions(includeSecrets: true));
    final b = await Phone.create({});
    final info = b.backup.read(bytes);
    expect(info.includesSecrets, isTrue);
    await b.backup.import(info, ImportMode.merge, restoreSecrets: true);
    expect(await b.settings.llmKey(), 'sk-secret');
  });

  test('合并：新增项目，重复 id 跳过，卡片保留更新的 FSRS 状态', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    await seedExtras(a); // a 上 c1 在 11/1 复习过
    final bytes = await a.backup.export();

    final b = await Phone.create({});
    await seedSampleData(b.repo);
    await b.repo.saveProject(Project(id: 'mine', name: '我自己的项目', createdAt: DateTime.now()));
    final c1 = (await b.repo.card('c1'))!
      ..reps = 7
      ..lastReview = DateTime.now().add(const Duration(days: 2)); // b 上更新
    final c2 = (await b.repo.card('c2'))!..front = '我改过的正面';
    await b.repo.saveCards([c1, c2]);
    final cardC3 = (await a.repo.card('c3'))!
      ..reps = 2
      ..lastReview = DateTime.now().add(const Duration(days: 1));
    await a.repo.saveCards([cardC3]);
    final bytes2 = await a.backup.export();
    expect(bytes2, isNot(bytes));

    final res = await b.backup.import(b.backup.read(bytes2), ImportMode.merge);
    expect((await b.repo.projects()).length, 4); // 自己的项目还在
    expect((await b.repo.card('c1'))!.reps, 7); // 本机更新，保留本机
    expect((await b.repo.card('c3'))!.reps, 2); // 备份更新，采用备份
    expect((await b.repo.card('c2'))!.front, '我改过的正面'); // 没复习过的重复卡跳过
    expect(res.updated['cards'], 1);
    expect(res.added['logs'], 1);
    expect(res.added['explain'], 1); // c1 的解释是新的，c11 重复跳过
    expect(res.safetyBackup, isNull);
  });

  test('覆盖前自动生成安全备份，可以用它恢复原数据', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    final bytes = await a.backup.export();

    final b = await Phone.create({});
    await b.repo.saveProject(Project(id: 'mine', name: '原来的数据', createdAt: DateTime.now()));
    final before = canon(await b.dump());
    final res = await b.backup.import(b.backup.read(bytes), ImportMode.overwrite);
    expect(res.safetyBackup, isNotNull);
    expect((await b.repo.projects()).map((e) => e.id), isNot(contains('mine')));
    final local = await b.backup.localBackups(prefix: 'safety');
    expect(local, hasLength(1));
    await b.backup.import(b.backup.read(await local.first.readAsBytes()), ImportMode.overwrite);
    expect(canon(await b.dump()), before);
  });

  test('损坏、被改动、不是备份的文件都会被拒绝，且不改动现有数据', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    final bytes = await a.backup.export();
    final b = await Phone.create({});

    expect(() => b.backup.read(Uint8List.fromList(utf8.encode('hello'))), throwsA(isA<BackupException>()));
    // 截断
    expect(() => b.backup.read(Uint8List.sublistView(bytes, 0, bytes.length ~/ 2)), throwsA(isA<BackupException>()));
    // 篡改其中一个数据文件（重新打包，manifest 不变）
    final zip = ZipDecoder().decodeBytes(bytes);
    final tampered = Archive();
    for (final f in zip.files) {
      if (f.name == 'data/cards.json') {
        final l = jsonDecode(utf8.decode(f.content)) as List;
        (l.first as Map)['data']['front'] = '被改了';
        tampered.addFile(ArchiveFile.string(f.name, jsonEncode(l)));
      } else {
        tampered.addFile(ArchiveFile.bytes(f.name, f.content));
      }
    }
    expect(() => b.backup.read(Uint8List.fromList(ZipEncoder().encode(tampered))),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('校验失败'))));
    // 普通 zip
    final other = Archive()..addFile(ArchiveFile.string('a.txt', 'x'));
    expect(() => b.backup.read(Uint8List.fromList(ZipEncoder().encode(other))),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('不是'))));
    expect((await b.repo.projects()), isEmpty);
  });

  test('导入中途失败整体回滚', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    final bytes = await a.backup.export();
    final b = await Phone.create({});
    await b.repo.saveProject(Project(id: 'mine', name: '原来的数据', createdAt: DateTime.now()));
    final before = canon(await b.dump());
    b.store.failAfterPuts = 5;
    await expectLater(b.backup.import(b.backup.read(bytes), ImportMode.overwrite), throwsA(isA<StateError>()));
    expect(canon(await b.dump()), before);
  });

  Uint8List repack(Uint8List bytes, Map<String, dynamic> Function(Map<String, dynamic>) editManifest,
      {Map<String, List<int>> replace = const {}}) {
    final zip = ZipDecoder().decodeBytes(bytes);
    final m = editManifest(jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content)) as Map<String, dynamic>);
    final files = <String, List<int>>{
      for (final f in zip.files)
        if (f.name != 'manifest.json') f.name: replace[f.name] ?? f.content
    };
    final checks = {for (final e in files.entries) e.key: sha256Hex(e.value)};
    final keys = checks.keys.toList()..sort();
    m['files'] = checks;
    m['checksum'] = sha256Hex(utf8.encode(keys.map((k) => '$k:${checks[k]}').join('\n')));
    final out = Archive()..addFile(ArchiveFile.string('manifest.json', jsonEncode(m)));
    for (final e in files.entries) {
      out.addFile(ArchiveFile.bytes(e.key, e.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(out));
  }

  test('旧版本备份自动迁移；更新版本的备份拒绝并提示升级', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    await seedExtras(a);
    final bytes = await a.backup.export();
    // 模拟 v1.1.5（schema 1）：资料没有 type，解释没有时间字段
    final docs = (jsonDecode(utf8.decode(ZipDecoder().decodeBytes(bytes).findFile('data/docs.json')!.content)) as List)
      ..forEach((r) => (r['data'] as Map).remove('type'));
    final ex = (jsonDecode(utf8.decode(ZipDecoder().decodeBytes(bytes).findFile('data/explain.json')!.content)) as List)
      ..forEach((r) => (r['data'] as Map)..remove('createdAt')..remove('updatedAt'));
    final old = repack(bytes, (m) => m..['schemaVersion'] = 1..['appVersion'] = '1.1.5', replace: {
      'data/docs.json': utf8.encode(jsonEncode(docs)),
      'data/explain.json': utf8.encode(jsonEncode(ex)),
    });
    final b = await Phone.create({});
    final info = b.backup.read(old);
    expect(info.schemaVersion, 1);
    await b.backup.import(info, ImportMode.overwrite);
    expect((await b.repo.docs('p1')).first.type, 'pdf');
    final h = await b.repo.explainHistory();
    expect(h.firstWhere((e) => e.id == 'c1').title, '什么是条件概率？');
    expect(h.every((e) => e.title.isNotEmpty), isTrue);

    final newer = repack(bytes, (m) => m..['schemaVersion'] = SqliteDocStore.schemaVersion + 1..['appVersion'] = '9.9.9');
    expect(() => b.backup.read(newer),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', allOf(contains('9.9.9'), contains('升级')))));
  });

  test('单项目导出：只含该项目，可不带学习进度；导入后不影响其他项目', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    await seedExtras(a);
    final bytes = await a.backup.export(projectId: 'p1', options: const BackupOptions(includeProgress: false));
    final b = await Phone.create({'llm_model': 'keep-me'});
    await b.repo.saveProject(Project(id: 'mine', name: '我的', createdAt: DateTime.now()));
    final info = b.backup.read(bytes);
    expect(info.scope, 'project');
    expect(info.count('projects'), 1);
    expect(info.projectNames, ['概率论 第3章']);
    expect(info.count('logs'), 0);
    await b.backup.import(info, ImportMode.overwrite); // 单项目「替换」不会清空其他项目
    expect((await b.repo.projects()).map((e) => e.id).toSet(), {'mine', 'p1'});
    expect((await b.repo.card('c1'))!.reps, 0);
    expect(await b.repo.wrong(), isEmpty);
    expect(b.settings.llmModel, 'keep-me'); // 单项目不带设置
  });

  test('每周自动备份只保留最近 3 份', () async {
    final a = await Phone.create({'auto_backup': true});
    await seedSampleData(a.repo);
    var t = DateTime(2026, 1, 1);
    expect(await a.backup.autoBackupIfDue(now: t), isNotNull);
    expect(await a.backup.autoBackupIfDue(now: t.add(const Duration(days: 3))), isNull);
    for (var i = 1; i <= 4; i++) {
      t = t.add(const Duration(days: 8));
      expect(await a.backup.autoBackupIfDue(now: t), isNotNull);
    }
    expect(await a.backup.localBackups(prefix: 'auto'), hasLength(3));
  });

  test('AppState.dueCards：上限默认不限，设置后按新卡 / 复习分别限制', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    final s = AppState(a.repo, a.settings);
    final all = await s.dueCards(projectId: 'p1');
    a.settings.dailyNewLimit = 5;
    expect((await s.dueCards(projectId: 'p1')).where((c) => c.reps == 0).length, 5);
    await a.repo.log(LogEntry(id: 'x', projectId: 'p1', kind: 'card', correct: true, isNew: true));
    expect((await s.dueCards(projectId: 'p1')).where((c) => c.reps == 0).length, 4);
    a.settings.dailyNewLimit = 0;
    expect((await s.dueCards(projectId: 'p1')).length, all.length);
  });
}

String sha256Hex(List<int> b) => sha256.convert(b).toString();
