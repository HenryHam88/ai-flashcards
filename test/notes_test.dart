import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/pdf_export.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'pdf_export_test.dart' show FakeRaster, font, pdfText;
import 'sample_data.dart';
import 'study_test.dart' show FakeLlm;

void main() {
  late AppState s;
  late Directory dir;
  late FakeLlm llm;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    llm = FakeLlm(answer: r'条件概率就是缩小样本空间：$P(A\mid B)=\dfrac{P(AB)}{P(B)}$。');
    s = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()), llmFactory: (_, _) => llm);
    dir = Directory.systemTemp.createTempSync('afc_notes');
    s.appDirOverride = dir;
    await seedSampleData(s.repo);
    await seedChapterPages(s.repo);
    await s.repo.saveKps([KnowledgePoint(id: 'kp1', projectId: 'p1', docId: 'd1', chapter: '第一章 随机事件与概率', title: '条件概率', content: '设 P(B)>0', page: 12)]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('同一知识点只有一条笔记；新笔记带上知识点标题和章节，空笔记不保存', () async {
    final n = await s.noteFor(projectId: 'p1', kpId: 'kp1');
    expect((n.title, n.chapter), ('条件概率', '第一章 随机事件与概率'));
    expect(await s.repo.notes(projectId: 'p1'), isEmpty);
    n.own = '我的理解';
    await s.saveNote(n);
    final again = await s.noteFor(projectId: 'p1', kpId: 'kp1');
    expect(again.id, n.id);
    expect(again.own, '我的理解');
  });

  test('照片：存进 media 目录并登记为 photo；移除和删除笔记会删掉文件', () async {
    final n = await s.noteFor(projectId: 'p1', kpId: 'kp1');
    final id = await s.addNotePhoto(n, FakeRaster.png, ext: 'png');
    final m = (await s.repo.mediaAsset(id))!;
    expect(m.kind, 'photo');
    expect(m.ownerId, n.id);
    expect(m.localPath, startsWith('${dir.path}/media/'));
    expect(File(m.localPath).existsSync(), isTrue);
    expect((await s.repo.note(n.id))!.photoIds, [id]);
    expect((await s.notePhoto(id))!.path, m.localPath);
    final id2 = await s.addNotePhoto(n, FakeRaster.png, ext: 'png');
    await s.removeNotePhoto(n, id);
    expect(File(m.localPath).existsSync(), isFalse);
    expect((await s.repo.note(n.id))!.photoIds, [id2]);
    final p2 = (await s.repo.mediaAsset(id2))!.localPath;
    await s.deleteNoteEverywhere(n);
    expect(File(p2).existsSync(), isFalse);
    expect(await s.repo.note(n.id), isNull);
    expect(await s.repo.media(), isNot(contains(predicate((MediaAsset x) => x.kind == 'photo'))));
  });

  test('AI 讲解：带上知识点内容、自己的理解和教材原文', () async {
    final n = await s.noteFor(projectId: 'p1', kpId: 'kp1');
    n.own = '分母不能为零';
    final a = await s.noteExplain(n);
    expect(a.content, contains(r'\dfrac'));
    // 默认联网（深度搜索）：系统提示说明以教材为准，并带回参考网页
    expect(llm.webs.single, WebMode.deep);
    expect(llm.chats.single.first['content'], contains('以学生自己的教材'));
    expect(a.sources.single.url, 'https://example.com/p');
    final prompt = llm.chats.single.last['content']!;
    expect(prompt, contains('条件概率'));
    expect(prompt, contains('设 P(B)>0'));
    expect(prompt, contains('我的理解：分母不能为零'));
    expect(prompt, contains('乘法定理'), reason: '第 12 页原文');
  });

  test('笔记 PDF：标题、知识点、我的理解、AI 讲解、照片、相关题目、引用原文和页码', () async {
    final n = StudyNote(id: 'n1', projectId: 'p1', kpId: 'kp1', chapter: '第一章 随机事件与概率', title: '条件概率',
        own: r'把样本空间缩小到 $B$', ai: r'**关键**：分母 $P(B)$ 不能为零', questionIds: ['q1'], quotes: [NoteQuote(docId: 'd1', page: 12, text: '称为条件概率')]);
    final q = (await s.repo.question('q1'))!;
    final kp = (await s.repo.kp('kp1'))!;
    final bytes = await PdfExportService(font(), math: FakeRaster())
        .notes('概率论', [NoteExport(n, kp: kp, questions: [q], photos: [FakeRaster.png], docNames: {'d1': '概率论与数理统计'})], now: DateTime(2026, 11, 25));
    final t = pdfText(bytes);
    for (final x in ['概率论 · 笔记', '共 1 条', '第一章 随机事件与概率', '条件概率', '设 P(B)>0', '我的理解', '把样本空间缩小到', 'AI 讲解', '关键', '照片', '相关题目', '一阶线性', '答案：', '引用原文', '称为条件概率', '《概率论与数理统计》第 12 页']) {
      expect(t, contains(x), reason: x);
    }
    final d = PdfDocument(inputBytes: bytes);
    expect(d.pages.count, 1);
    d.dispose();
    expect(Uint8List.fromList(bytes.take(4).toList()), '%PDF'.codeUnits);
  });
}
