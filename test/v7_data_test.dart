import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/backup.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_test.dart' show Phone;
import 'sample_data.dart';

void main() {
  test('v7：新增集合与模型 JSON 往返', () async {
    expect(SqliteDocStore.schemaVersion, 7);
    for (final c in ['favorites', 'mindmaps', 'study_chats', 'notes', 'media']) {
      expect(DocStore.allCollections, contains(c));
    }
    final repo = Repository(MemoryDocStore());

    final on = await repo.toggleFavorite(FavoriteItem(projectId: 'p1', kind: 'kp', targetId: 'k1', title: '条件概率'));
    expect(on, isTrue);
    expect(await repo.isFavorite('kp', 'k1'), isTrue);
    expect((await repo.favorites(projectId: 'p1')).single.title, '条件概率');
    expect(await repo.toggleFavorite(FavoriteItem(projectId: 'p1', kind: 'kp', targetId: 'k1')), isFalse);
    expect(await repo.favorites(), isEmpty);

    final root = MindNode(text: '第一章', children: [
      MindNode(text: r'条件概率 $P(A|B)$', children: [MindNode(text: '乘法公式')]),
      MindNode(text: '全概率公式'),
    ]);
    await repo.saveMindMap(ChapterMindMap(projectId: 'p1', docId: 'd1', chapter: '第一章', root: root));
    final m = (await repo.mindMap('d1', '第一章'))!;
    expect(m.root.count, 4);
    expect(m.root.children.first.children.single.text, '乘法公式');
    final leafId = m.root.children.first.children.single.id;
    expect(m.root.parentOf(leafId)!.text, startsWith('条件概率'));

    await repo.saveStudyChat(StudyChat(id: 's1', projectId: 'p1', title: '贝叶斯', scope: [
      MaterialRef(docId: 'd1', chapter: '第一章'),
      MaterialRef(docId: 'd1', pageFrom: 3, pageTo: 5),
    ], messages: [
      {'role': 'user', 'content': '讲讲贝叶斯公式'},
    ]));
    final chat = (await repo.studyChats('p1')).single;
    expect(chat.scope.length, 2);
    expect(chat.scope.last.pageTo, 5);

    await repo.saveNote(StudyNote(
        id: 'n1',
        projectId: 'p1',
        kpId: 'k1',
        title: '条件概率',
        own: '自己的理解',
        quotes: [NoteQuote(docId: 'd1', page: 12, text: '原文')],
        questionIds: ['q1'],
        photoIds: ['photo_1']));
    final n = (await repo.note('n1'))!;
    expect(n.quotes.single.page, 12);
    expect(n.photoIds, ['photo_1']);
    expect(n.isEmpty, isFalse);

    await repo.saveMedia(MediaAsset(id: MediaAsset.docId('d1'), projectId: 'p1', kind: 'doc', ownerId: 'd1', localPath: '/x/d1.pdf'));
    final a = (await repo.mediaAsset('doc_d1'))!;
    expect(a.stateLabel, '仅本机');
    a
      ..cloudKey = 'ai-flashcards/docs/d1/d1.pdf'
      ..offloaded = true;
    expect(a.stateLabel, '仅云端');

    // 删除资料时，导图和文件记录一起清掉
    await repo.saveDoc(PdfDoc(id: 'd1', projectId: 'p1', name: 'x', path: '/x/d1.pdf'));
    await repo.deleteDoc((await repo.docs('p1')).single);
    expect(await repo.mindMaps('p1'), isEmpty);
    expect(await repo.mediaAsset('doc_d1'), isNull);
  });

  test('旧数据（v6 JSON）读成新模型不报错', () {
    final n = StudyNote.fromJson({'id': 'n', 'projectId': 'p'});
    expect(n.isEmpty, isTrue);
    final m = ChapterMindMap.fromJson({'projectId': 'p', 'docId': 'd', 'chapter': '第一章'});
    expect(m.root.text, '第一章');
    expect(MediaAsset.fromJson({'id': 'x'}).offloaded, isFalse);
  });

  test('v7 备份：笔记照片随备份迁移，云端 AccessKey 绝不进备份', () async {
    final a = await Phone.create({'cloud_bucket': 'my-bucket', 'cloud_region': 'cn-hangzhou'});
    await seedSampleData(a.repo);
    await a.settings.setLlmKey('sk-llm');
    await a.settings.setCloudKeyId('LTAI-cloud-id');
    await a.settings.setCloudSecret('cloud-secret-value');
    expect(await a.settings.cloudConfigured(), isTrue);

    final photo = File('${a.dir.path}/media/photo_1.jpg');
    await photo.parent.create(recursive: true);
    await photo.writeAsBytes(List.generate(1000, (i) => i % 7));
    await a.repo.saveMedia(MediaAsset(id: 'photo_1', projectId: 'p1', kind: 'photo', ownerId: 'n1', localPath: photo.path, size: 1000));
    await a.repo.saveNote(StudyNote(id: 'n1', projectId: 'p1', kpId: 'k1', photoIds: ['photo_1'], own: '笔记'));
    await a.repo.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'card', targetId: 'c1'));

    final bytes = await a.backup.export(options: const BackupOptions(includeFiles: true, includeSecrets: true));
    final zip = ZipDecoder().decodeBytes(bytes);
    final all = [for (final f in zip.files) if (f.isFile) utf8.decode(f.content, allowMalformed: true)].join('\n');
    expect(all, contains('sk-llm')); // 勾选了包含 API 密钥
    expect(all, isNot(contains('cloud-secret-value')));
    expect(all, isNot(contains('LTAI-cloud-id')));
    expect(zip.findFile('files/photo_1/photo_1.jpg'), isNotNull);

    final b = await Phone.create({});
    final info = b.backup.read(bytes);
    await b.backup.import(info, ImportMode.overwrite, restoreSecrets: true);
    expect(await b.settings.cloudKeyId(), isEmpty);
    final m = (await b.repo.mediaAsset('photo_1'))!;
    expect(m.localPath, startsWith(b.dir.path));
    expect(File(m.localPath).readAsBytesSync().length, 1000);
    expect((await b.repo.note('n1'))!.photoIds, ['photo_1']);
    expect(await b.repo.isFavorite('card', 'c1'), isTrue);
  });

  test('v6 备份仍可导入到 v7', () async {
    final a = await Phone.create({});
    await seedSampleData(a.repo);
    final bytes = await a.backup.export();
    // 改写成 v6 清单（去掉新集合）后重新校验导入
    final zip = ZipDecoder().decodeBytes(bytes);
    final manifest = jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content)) as Map<String, dynamic>;
    expect(manifest['schemaVersion'], 7);
    SharedPreferences.setMockInitialValues({});
    final b = await Phone.create({});
    manifest['schemaVersion'] = 6;
    final out = Archive();
    for (final f in zip.files) {
      out.addFile(f.name == 'manifest.json' ? ArchiveFile.string('manifest.json', jsonEncode(manifest)) : f);
    }
    final info = b.backup.read(Uint8List.fromList(ZipEncoder().encode(out)));
    await b.backup.import(info, ImportMode.overwrite);
    expect((await b.repo.cards()).length, (await a.repo.cards()).length);
    expect(Settings.secretKeys, isNot(contains('cloud_sk')));
  });
}
