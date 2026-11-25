import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/attachments.dart';
import 'package:ai_flashcards/services/backup.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/services/study.dart';
import 'package:ai_flashcards/ui/study_page.dart' show attachNotice, limitLabel;
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';
import 'study_test.dart' show FakeLlm;

Uint8List docx(List<String> paras) {
  final xml = '<?xml version="1.0"?><w:document><w:body>'
      '${paras.map((p) => '<w:p><w:r><w:t>${p.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</w:t></w:r></w:p>').join()}'
      '</w:body></w:document>';
  final a = Archive()..addFile(ArchiveFile.bytes('word/document.xml', utf8.encode(xml)));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  late AppState s;
  late Directory dir;
  late FakeLlm llm;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    llm = FakeLlm(answer: '好的回答');
    s = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()), llmFactory: (_, _) => llm);
    dir = Directory.systemTemp.createTempSync('afc_att');
    s.appDirOverride = dir;
    await seedSampleData(s.repo);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('格式、大小、数量限制', () {
    expect(AttachmentService.kindOf('需求.PDF'), 'pdf');
    expect(AttachmentService.kindOf('a.docx'), 'word');
    expect(AttachmentService.kindOf('a.doc'), 'word');
    expect(AttachmentService.kindOf('a.txt'), 'txt');
    expect(AttachmentService.kindOf('a.webp'), 'image');
    expect(AttachmentService.check('a.pptx', 10, 0), contains('格式不支持'));
    expect(AttachmentService.check('a.pdf', 21 * 1024 * 1024, 0), contains('20 MB'));
    expect(AttachmentService.check('a.jpg', 9 * 1024 * 1024, 0), contains('压缩'));
    expect(AttachmentService.check('a.txt', 10, 5), contains('最多 5 个'));
    expect(AttachmentService.check('a.txt', 10, 4), isNull);
  });

  test('.docx 在手机上直接读正文（不联网）', () {
    expect(AttachmentService.docxText(docx(['第一段 A&B', '第二段 x<y'])), '第一段 A&B\n第二段 x<y');
    expect(AttachmentService.docxText(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('附件全文另存；按模型上下文（deepseek-flash 1M）整份发给 AI；删除对话时文件一起删掉', () async {
    final chat = StudyChat(id: 'c1', projectId: 'p1');
    final big = '需求' * 15000; // 30000 字
    final a = await s.addChatAttachment(chat, '需求文档.txt', Uint8List.fromList(utf8.encode(big)));
    expect(a.kind, 'txt');
    expect(a.chars, 30000);
    expect(a.text.length, AttachmentService.storeChars, reason: '数据库里只放预览');
    final full = (await s.repo.mediaAsset('${a.id}_text'))!;
    expect(full.kind, 'chat_file');
    expect(File(full.localPath).readAsStringSync(), big);
    await s.addChatAttachment(chat, '接口说明.docx', docx(['登录接口 POST /login']));
    final m = (await s.repo.mediaAsset(a.id))!;
    expect(m.kind, 'chat_file');
    expect(m.ownerId, 'c1');
    expect(File(m.localPath).existsSync(), isTrue);
    expect((await s.repo.studyChats('p1')).single.attachments.length, 2, reason: '附件随对话保存');
    expect(chat.plan!.context, 1000000);
    expect(chat.plan!.attachCut, isFalse);

    await s.studyAsk(chat, '帮我总结需求');
    final sys = llm.chats.single.first['content']!;
    expect(sys, contains('【附件：需求文档.txt】\n$big'));
    expect(sys, isNot(contains('只附上了前一部分')));
    expect(sys, contains('登录接口 POST /login'));
    expect(sys, contains('学生上传了附件（需求文档.txt、接口说明.docx）'));
    expect(chat.plan!.attachSent, 30000 + '登录接口 POST /login'.length);

    await s.deleteStudyChat(chat);
    expect(File(m.localPath).existsSync(), isFalse);
    expect(File(full.localPath).existsSync(), isFalse);
    expect(await s.repo.mediaAsset(a.id), isNull);
    expect(await s.repo.mediaAsset('${a.id}_text'), isNull);
    expect(await s.repo.studyChats('p1'), isEmpty);
  });

  test('上下文分配：先扣安全余量、回答 / 联网预留和固定部分，放不下先丢最早的对话，再截断附件', () {
    // 128K：可用 = 115200 − 32000 − 1000 = 82200
    var p = AttachmentService.plan(context: 128000, fixedChars: 1000, history: [10000, 10000, 5000, 5000], attachChars: 50000);
    expect((p.historyDropped, p.attachSent, p.attachCut), (0, 50000, false));
    p = AttachmentService.plan(context: 128000, fixedChars: 1000, history: [10000, 10000, 5000, 5000], attachChars: 60000);
    expect((p.historyDropped, p.attachSent), (2, 60000), reason: '成对丢掉最早的一问一答');
    p = AttachmentService.plan(context: 128000, fixedChars: 1000, history: [10000, 10000, 5000, 5000], attachChars: 100000);
    expect((p.historyDropped, p.attachSent, p.attachCut), (4, 82200, true));
    // 联网再预留 64000，两张图各 2000
    p = AttachmentService.plan(context: 128000, fixedChars: 1000, history: const [], attachChars: 100000, web: true, images: 2);
    expect(p.attachSent, 82200 - 64000 - 4000);
    p = AttachmentService.plan(context: 128000, fixedChars: 200000, history: [100], attachChars: 10);
    expect((p.historyDropped, p.attachSent), (1, 0));
    expect(LlmClient.contextTokens('deepseek-flash'), 1000000);
    expect(LlmClient.contextTokens('deepseek-v4-pro'), 1000000);
    expect(LlmClient.contextTokens('qwen-plus'), 128000);
  });

  test('超出上下文时截断附件，提示写明实际发送的字数', () async {
    s.settings.llmModel = 'other-model'; // 128K
    final chat = StudyChat(id: 'c4', projectId: 'p1');
    await s.addChatAttachment(chat, '大文件.txt', Uint8List.fromList(utf8.encode('字' * 200000)));
    final p = chat.plan!;
    expect(p.attachCut, isTrue);
    expect(p.attachSent, greaterThan(0));
    expect(attachNotice(p), contains('附件共约 20.0 万字，这次只发送前 ${p.attachSent} 字'));
    expect(attachNotice(p), contains('128K token'));
    await s.studyAsk(chat, '总结');
    final sys = llm.chats.single.first['content']!;
    expect(sys, contains('（附件较长，只附上了前一部分）'));
    expect('字'.allMatches(sys).length, greaterThanOrEqualTo(chat.plan!.attachSent));
  });

  test('图片：deepseek-flash 才能发，随提问以 image_url 发给模型；其他模型给出原因', () async {
    final chat = StudyChat(id: 'c2', projectId: 'p1');
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    s.settings.llmModel = 'deepseek-v4-pro';
    expect(() => s.addChatAttachment(chat, '板书.png', png), throwsA(isA<AttachmentException>().having((e) => e.message, 'm', contains('deepseek-flash'))));
    s.settings.llmModel = 'deepseek-flash';
    final a = await s.addChatAttachment(chat, '板书.png', png);
    expect(a.isImage, isTrue);
    await s.studyAsk(chat, '这张图讲了什么');
    final last = llm.chats.single.last;
    final imgs = jsonDecode(last['images']!) as List;
    expect(imgs.single, 'data:image/png;base64,${base64Encode(png)}');
    final wire = LlmClient.wireMessages([last]).single;
    expect((wire['content'] as List).first, {'type': 'text', 'text': '这张图讲了什么'});
    expect(((wire['content'] as List)[1] as Map)['type'], 'image_url');
    // 对话里只保存可见文字，不保存图片数据
    expect(chat.messages.first.containsKey('images'), isFalse);
  });

  test('上限文案跟着常量走', () {
    expect(limitLabel(StudyService.budget), '6 万字');
    expect(limitLabel(20000), '2 万字');
    expect(limitLabel(25000), '2.5 万字');
    expect(limitLabel(8000), '8000 字');
  });

  test('移除单个附件', () async {
    final chat = StudyChat(id: 'c3', projectId: 'p1');
    final a = await s.addChatAttachment(chat, 'a.txt', Uint8List.fromList(utf8.encode('内容')));
    await s.removeChatAttachment(chat, a.id);
    expect(chat.attachments, isEmpty);
    expect(await s.repo.mediaAsset(a.id), isNull);
  });

  test('备份带上伴学附件，导入后能找到文件', () async {
    final store = MemoryDocStore();
    final repo = Repository(store);
    SharedPreferences.setMockInitialValues({});
    final st = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    final f = File('${dir.path}/media/chatfile_1.txt')..createSync(recursive: true);
    f.writeAsStringSync('需求');
    await repo.saveProject(Project(id: 'p1', name: 'x', createdAt: DateTime(2026)));
    await repo.saveMedia(MediaAsset(id: 'chatfile_1', projectId: 'p1', kind: 'chat_file', ownerId: 'c1', localPath: f.path, fileName: 'a.txt', size: 6));
    final bytes = await BackupService(store: store, settings: st, appDir: dir, appVersion: '1').export(options: const BackupOptions(includeFiles: true));
    expect(ZipDecoder().decodeBytes(bytes).findFile('files/chatfile_1/chatfile_1.txt'), isNotNull);
    final dir2 = Directory.systemTemp.createTempSync('afc_att2');
    addTearDown(() => dir2.deleteSync(recursive: true));
    final store2 = MemoryDocStore();
    final b = BackupService(store: store2, settings: st, appDir: dir2, appVersion: '1');
    await b.import(b.read(bytes), ImportMode.overwrite);
    final m = (await Repository(store2).mediaAsset('chatfile_1'))!;
    expect(m.localPath, startsWith('${dir2.path}/media'));
    expect(File(m.localPath).readAsStringSync(), '需求');
  });
}
