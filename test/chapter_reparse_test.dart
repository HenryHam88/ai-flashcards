import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/chapter_reparse.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/services/text_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeLlm extends LlmClient {
  final List<String> titles;
  int calls = 0;
  FakeLlm(this.titles) : super(baseUrl: 'http://x', apiKey: 'k', model: 'm');
  @override
  Future<Map<String, dynamic>> chatJson(String prompt, {String? system, int retries = 3}) async {
    calls++;
    if (titles.isEmpty) throw LlmException('网络错误');
    return {
      'knowledge_points': [for (final t in titles) {'title': t, 'type': '定义', 'content': '$t 的内容'}]
    };
  }
}

/// 重新切块时失败：验证保存时的回滚。
class FailingRechunk extends ChapterReparseService {
  FailingRechunk(super.repo, super.settings, {super.fetchOverride});
  @override
  Future<void> rechunk(PdfDoc doc, {List<Chunk>? oldChunks}) async => throw StateError('磁盘已满');
}

String pageText(int p, [String v = '旧']) => '[$v] 第 $p 页正文：${'条件概率与全概率公式。' * 3}';

void main() {
  late Repository repo;
  late Settings settings;
  final doc = PdfDoc(id: 'd', projectId: 'p', name: '概率论', path: '', type: 'pdf', status: '已解析', pageCount: 6, parsedPages: 6);
  final ch1 = ChapterRange('第一章 随机事件', 1, 3);
  final ch2 = ChapterRange('第二章 随机变量', 4, 6);

  ChapterReparseService svc({BatchFetcher? fetch}) => ChapterReparseService(repo, settings,
      fetchOverride: fetch ?? (e, f, t) async => [for (var p = f; p <= t; p++) pageText(p, '新')], retryDelay: Duration.zero);

  Future<Map<int, PageText>> pages() async => {for (final p in await repo.pages('p', docId: 'd')) p.page: p};
  Future<List<Chunk>> chunksOf(ChapterRange r) => svc().chapterChunks(doc, r);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = Repository(MemoryDocStore());
    settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    await repo.saveDoc(doc..parsedPages = 6);
    await repo.savePages([
      for (var p = 1; p <= 6; p++) PageText(docId: 'd', projectId: 'p', page: p, text: pageText(p), source: 'deepseek_text')
    ]);
    await repo.saveChapterPlan(ChapterPlan(docId: 'd', projectId: 'p', source: 'manual', chapters: [ch1, ch2]));
    await svc().rechunk(doc);
    // 每块一个知识点（模拟已缓存的自动数量结果）
    final cs = await repo.chunks('p');
    await repo.saveKps([
      for (final c in cs)
        KnowledgePoint(id: '${c.id}_k0', projectId: 'p', docId: 'd', chapter: c.chapter, title: '${c.chapter} 知识点', page: c.pageStart)
    ]);
    await repo.saveCards([
      Flashcard(id: 'c1', projectId: 'p', docId: 'd', kpId: '${cs.last.id}_k0', chapter: ch2.title, front: 'Q', back: 'A', page: 5)
    ]);
  });

  test('只解析这一章的页，结果先放在内存里，不改动任何数据', () async {
    final asked = <(int, int)>[];
    final before = jsonEncode((await pages()).map((k, v) => MapEntry('$k', v.toJson())));
    final r = await svc(fetch: (e, f, t) async {
      asked.add((f, t));
      return [for (var p = f; p <= t; p++) pageText(p, '新')];
    }).run(doc, ch2, ReparseEngine.deepseekRich);
    expect(asked, [(4, 6)]);
    expect(r.pages.map((p) => p.page), [4, 5, 6]);
    expect(r.changedCount, 3);
    expect(jsonEncode((await pages()).map((k, v) => MapEntry('$k', v.toJson()))), before);
    expect(await svc().snapshot(doc, ch2), isNull);
  });

  test('按批次上传；保存只替换所选的页，更新来源，分章、闪卡不变，这一章的知识点缓存失效', () async {
    settings.ocrBatchPages = 2;
    final asked = <(int, int)>[];
    final s = svc(fetch: (e, f, t) async {
      asked.add((f, t));
      return [for (var p = f; p <= t; p++) pageText(p, '新')];
    });
    final cardBefore = (await repo.card('c1'))!.toJson();
    final ch1Chunks = (await chunksOf(ch1)).map((c) => c.id).toList();
    final r = await s.run(doc, ch2, ReparseEngine.deepseekRich);
    expect(asked, [(4, 5), (6, 6)]);
    r.pages[1].useNew = false; // 第 5 页保留旧的
    expect(await s.commit(r), 2);
    final ps = await pages();
    expect(ps[4]!.text, pageText(4, '新'));
    expect(ps[4]!.source, 'deepseek_rich');
    expect(ps[5]!.text, pageText(5));
    expect(ps[5]!.source, 'deepseek_text');
    expect(ps[6]!.text, pageText(6, '新'));
    for (var p = 1; p <= 3; p++) {
      expect(ps[p]!.text, pageText(p));
    }
    expect((await repo.chapterPlan('d'))!.chapters.map((c) => c.toString()), [ch1.toString(), ch2.toString()]);
    expect((await repo.card('c1'))!.toJson(), cardBefore);
    expect((await chunksOf(ch1)).map((c) => c.id).toList(), ch1Chunks);
    expect(await s.kpCoverage(doc, ch1), (1, 1));
    final (done2, total2) = await s.kpCoverage(doc, ch2);
    expect(done2, 0);
    expect(total2, greaterThan(0));
    expect(await s.chapterKps(doc, ch1), hasLength(1));
    // 旧知识点记录仍在（闪卡引用的 kpId 不受影响）
    expect((await repo.kps('p')).any((k) => k.id == cardBefore['kpId']), isTrue);
  });

  test('取消：在批次之间停止，什么都不写入', () async {
    settings.ocrBatchPages = 1;
    final token = CancelToken();
    var calls = 0;
    final s = svc(fetch: (e, f, t) async {
      calls++;
      if (f == 5) token.cancel();
      return [pageText(f, '新')];
    });
    await expectLater(s.run(doc, ch2, ReparseEngine.kimi, cancel: token), throwsA(isA<ReparseCancelled>()));
    expect(calls, 2);
    expect((await pages())[4]!.text, pageText(4));
    expect(await s.snapshot(doc, ch2), isNull);
  });

  test('保存中途失败：还原旧文字和切块，不留快照', () async {
    final chunkIds = (await repo.chunks('p')).map((c) => c.id).toList();
    final s = FailingRechunk(repo, settings, fetchOverride: (e, f, t) async => [for (var p = f; p <= t; p++) pageText(p, '新')]);
    final r = await s.run(doc, ch2, ReparseEngine.local);
    await expectLater(s.commit(r), throwsA(isA<StateError>()));
    final ps = await pages();
    for (var p = 1; p <= 6; p++) {
      expect(ps[p]!.text, pageText(p));
    }
    expect((await repo.chunks('p')).map((c) => c.id).toList(), chunkIds);
    expect(await s.snapshot(doc, ch2), isNull);
  });

  test('恢复上次解析：换回旧文字，再点一次换回新文字', () async {
    final s = svc();
    await s.commit(await s.run(doc, ch2, ReparseEngine.deepseekText));
    expect((await pages())[5]!.text, pageText(5, '新'));
    final snap = await s.snapshot(doc, ch2);
    expect(snap!.pages.map((p) => p.page), [4, 5, 6]);
    expect(await s.undo(doc, ch2), 3);
    var ps = await pages();
    expect(ps[5]!.text, pageText(5));
    expect(ps[5]!.source, 'deepseek_text');
    expect(await s.kpCoverage(doc, ch2), (1, 1)); // 文字恢复后，原来的知识点又能用上
    await s.undo(doc, ch2);
    ps = await pages();
    expect(ps[5]!.text, pageText(5, '新'));
  });

  test('原来没有解析的页：替换后补上，恢复时删掉', () async {
    await repo.deletePage('d', 6);
    final s = svc();
    final r = await s.run(doc, ch2, ReparseEngine.local);
    expect(r.pages.last.oldParsed, isFalse);
    await s.commit(r);
    expect((await pages())[6]!.text, pageText(6, '新'));
    expect((await repo.docs('p')).single.parsedPages, 6);
    await s.undo(doc, ch2);
    expect((await pages()).containsKey(6), isFalse);
  });

  test('部分批次失败：失败的页只能保留旧的；全部失败报错', () async {
    settings.ocrBatchPages = 2;
    final s = svc(fetch: (e, f, t) async {
      if (f == 6) throw Exception('超时');
      return [for (var p = f; p <= t; p++) pageText(p, '新')];
    });
    final r = await s.run(doc, ch2, ReparseEngine.deepseekText);
    expect(r.failedCount, 1);
    expect(r.pages.last.useNew, isFalse);
    expect(r.chosen.map((p) => p.page), [4, 5]);
    final bad = svc(fetch: (e, f, t) async => throw Exception('超时'));
    await expectLater(bad.run(doc, ch2, ReparseEngine.deepseekText), throwsA(isA<ReparseException>()));
  });

  test('Word 不支持按章重新解析，并说明原因；TXT 只能本地重新读取', () async {
    final w = PdfDoc(id: 'w', projectId: 'p', name: '讲义', path: '', type: 'docx');
    expect(reparseUnsupported(w), contains('整份'));
    expect(enginesFor(w), isEmpty);
    await expectLater(svc().run(w, ch1, ReparseEngine.kimi), throwsA(isA<ReparseException>()));
    final t = PdfDoc(id: 't', projectId: 'p', name: '笔记', path: '', type: 'txt');
    expect(enginesFor(t), [ReparseEngine.txt]);
    expect(reparseEstimate(t, ch1, ReparseEngine.txt), contains('免费'));
    expect(reparseEstimate(doc, ch2, ReparseEngine.deepseekText, batch: 2), contains('分 2 批'));
  });

  test('TXT：重新读取文件，只替换这一章的小节；文件变了就拒绝', () async {
    final text = [for (var i = 1; i <= 4; i++) '第$i章 标题\n${'这是一段正文。' * 30}'].join('\n\n');
    final sections = splitTextPages(cleanImportedText(text));
    final t = PdfDoc(id: 't', projectId: 'p', name: '笔记', path: '', type: 'txt', pageCount: sections.length);
    await repo.saveDoc(t);
    await repo.savePages([
      for (var i = 0; i < sections.length; i++)
        PageText(docId: 't', projectId: 'p', page: i + 1, text: i == 1 ? '乱码' : sections[i], source: 'txt')
    ]);
    final s = ChapterReparseService(repo, settings, bytesOverride: Uint8List.fromList(utf8.encode(text)));
    final r = await s.run(t, ChapterRange('第2章', 2, 2), ReparseEngine.txt);
    expect(r.changedCount, 1);
    expect(r.pages.single.newText, sections[1]);
    final changed = ChapterReparseService(repo, settings, bytesOverride: Uint8List.fromList(utf8.encode('$text\n\n第5章 新增\n${'内容。' * 400}')));
    await expectLater(changed.run(t, ChapterRange('第2章', 2, 2), ReparseEngine.txt), throwsA(isA<ReparseException>()));
  });

  group('知识点', () {
    test('清除这一章的缓存只影响这一章', () async {
      final s = svc();
      expect(await s.clearChapterKps(doc, ch2), greaterThan(0));
      expect((await s.kpCoverage(doc, ch2)).$1, 0);
      expect(await s.kpCoverage(doc, ch1), (1, 1));
    });

    test('重新分析：清缓存、重新提取、给出新旧对比；之后自动数量直接用新的', () async {
      final s = svc();
      final llm = FakeLlm(['随机变量', '分布函数']);
      final gen = GenerationService(repo, settings, llm, qualityCheck: false);
      final d = await s.reanalyzeKps(doc, ch2, gen);
      expect(d.oldKps.single.title, '第二章 随机变量 知识点');
      expect(d.newKps.map((k) => k.title), ['随机变量', '分布函数']);
      expect(d.addedIds.length, 2);
      expect(d.removedIds.length, 1);
      final calls = llm.calls;
      final plan = await gen.plan('p', GenOptions(scope: 'chapters', chapters: [ch2.title]), (_, _) {});
      expect(llm.calls, calls); // 用缓存，没有再调用模型
      expect(plan.kps.map((k) => k.title), containsAll(['随机变量', '分布函数']));
    });

    test('重新分析失败：保留原来的知识点', () async {
      final s = svc();
      final gen = GenerationService(repo, settings, FakeLlm([]), qualityCheck: false);
      await expectLater(s.reanalyzeKps(doc, ch2, gen), throwsA(isA<LlmException>()));
      expect(await s.kpCoverage(doc, ch2), (1, 1));
    });

    test('没有分章方案时（块 id 不含内容指纹），内容变了的块知识点作废，没变的保留', () async {
      await repo.store.delete('chapters', 'd');
      final s = svc();
      await s.rechunk(doc);
      final cs = await repo.chunks('p');
      await repo.saveKps([
        for (final c in cs) KnowledgePoint(id: '${c.id}_k0', projectId: 'p', docId: 'd', title: 'kp ${c.id}', page: c.pageStart)
      ]);
      final whole = ChapterRange('全文', 1, 6);
      final r = await s.run(doc, whole, ReparseEngine.local);
      for (final p in r.pages) {
        p.useNew = p.page == 6;
      }
      await s.commit(r);
      final after = await repo.chunks('p');
      final kps = await repo.kps('p');
      for (final c in after) {
        final has = kps.any((k) => k.id.startsWith('${c.id}_k'));
        expect(has, c.pageEnd < 6, reason: c.id);
      }
    });

    test('知识点对比', () {
      KnowledgePoint k(String id, String t) => KnowledgePoint(id: id, projectId: 'p', title: t);
      final d = KpDiff.of([k('a', '条件概率的定义'), k('b', '贝叶斯公式')], [k('x', '条件概率的定义'), k('y', '全概率公式')]);
      expect(d.addedIds, {'y'});
      expect(d.removedIds, {'b'});
    });
  });
}
