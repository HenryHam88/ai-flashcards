import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/chapters.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<PageText> pagesOf(List<String> texts) =>
    [for (var i = 0; i < texts.length; i++) PageText(docId: 'd', projectId: 'p', page: i + 1, text: texts[i])];

String body(int n) => '正文内容' * n;

class FakeLlm extends LlmClient {
  final Map<String, dynamic>? reply;
  int calls = 0;
  FakeLlm(this.reply) : super(baseUrl: 'http://x', apiKey: 'k', model: 'm');
  @override
  Future<Map<String, dynamic>> chatJson(String prompt, {String? system, int retries = 3}) async {
    calls++;
    if (reply == null) throw LlmException('网络错误');
    return reply!;
  }
}

void main() {
  group('标题识别', () {
    test('第X章（含 OCR 空格）+ 页眉重复只取第一次', () {
      final r = rangesFromHeadings(pagesOf([
        '封面',
        '第 一 章  随机事件与概率\n${body(5)}',
        '第一章 随机事件与概率\n${body(5)}', // 页眉
        '第2章 随机变量\n${body(5)}',
        body(5),
        '第三章 数字特征\n${body(5)}',
      ]));
      expect(r.map((c) => (c.title, c.start, c.end)).toList(), [
        ('前置内容', 1, 1),
        ('第 一 章 随机事件与概率', 2, 3),
        ('第2章 随机变量', 4, 5),
        ('第三章 数字特征', 6, 6),
      ]);
    });

    test('Chapter / Lecture / Unit', () {
      expect(rangesFromHeadings(pagesOf(['Chapter 1 Limits', body(3), 'CHAPTER 2 Derivatives'])).length, 2);
      expect(rangesFromHeadings(pagesOf(['Lecture 1 Intro', 'Lecture 2 Sets', 'Lecture 3 Maps'])).length, 3);
      expect(rangesFromHeadings(pagesOf(['Unit 1 Basics', body(2), 'Unit 2 Advanced'])).length, 2);
    });

    test('Markdown 标题（OCR / Kimi 输出）', () {
      final r = rangesFromHeadings(pagesOf(['# 概率基础\n## 样本空间', body(3), '# 随机变量\n## 分布函数']));
      expect(r.map((c) => c.title), ['概率基础', '随机变量']);
    });

    test('一、二、 与 （一）/1.2 兜底', () {
      expect(rangesFromHeadings(pagesOf(['一、集合', body(2), '二、映射', '三、函数'])).map((c) => c.title), ['一、集合', '二、映射', '三、函数']);
      expect(rangesFromHeadings(pagesOf(['§1 极限', '§2 连续'])).length, 2);
      expect(rangesFromHeadings(pagesOf(['1.1 极限的定义', body(2), '1.2 极限的性质'])).length, 2);
    });

    test('跳过目录页，没有标题时返回空', () {
      final toc = '目录\n第一章 集合 ........ 1\n第二章 映射 ........ 5\n第三章 函数 ........ 9';
      expect(rangesFromHeadings(pagesOf([toc, body(3), body(3)])), isEmpty);
      expect(rangesFromHeadings(pagesOf([body(3), body(3)])), isEmpty);
    });
  });

  test('目录页：按正文标题推算页码偏移', () {
    final pages = pagesOf([
      '封面',
      '目 录\n第一章 集合 ……… 1\n第二章 映射 ……… 3\n第三章 函数 ……… 5',
      '集合\n${body(3)}', // 正文第 1 页（实际第 3 页），标题被 OCR 漏掉
      body(3),
      '第二章 映射\n${body(3)}', // 印刷第 3 页 → 实际第 5 页（偏移 2）
      body(3),
      body(3),
      body(3),
    ]);
    final r = rangesFromToc(pages);
    expect(r.map((c) => (c.title, c.start)).toList(), [('前置内容', 1), ('第一章 集合', 3), ('第二章 映射', 5), ('第三章 函数', 7)]);
    expect(r.last.end, 8);
  });

  test('PDF 书签优先，单一根书签自动下钻', () {
    final outline = [('全书', 1, 0), ('第一章', 3, 1), ('第二章', 10, 1), ('1.1', 4, 2)];
    final (r, src) = detectChapters(pagesOf(List.filled(20, body(2))), outline: outline);
    expect(src, 'outline');
    expect(r.map((c) => (c.title, c.start, c.end)).toList(), [('前置内容', 1, 2), ('第一章', 3, 9), ('第二章', 10, 20)]);
  });

  group('AI 分章校验', () {
    test('乱序、越界、重复起始页被整理为连续覆盖', () {
      final r = rangesFromAi({
        'chapters': [
          {'title': '函数', 'startPage': 30, 'endPage': 99},
          {'title': '集合', 'startPage': 1, 'endPage': 20},
          {'title': '重复', 'startPage': 30},
          {'title': '越界', 'startPage': 500},
          {'title': '', 'startPage': 12},
        ]
      }, 50);
      expect(r.map((c) => (c.title, c.start, c.end)).toList(), [('集合', 1, 29), ('函数', 30, 50)]);
      expect(validRanges(r, 50), isTrue);
    });

    test('无效回复返回空', () {
      expect(rangesFromAi({'chapters': 'oops'}, 50), isEmpty);
      expect(rangesFromAi({'chapters': [{'title': '全部', 'startPage': 1}]}, 50), isEmpty); // 长文档只有 1 章不接受
    });

    test('识别不到 → 调用一次 AI；AI 失败或没有密钥 → 按页数切分', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
      final repo = Repository(MemoryDocStore());
      final doc = PdfDoc(id: 'd', projectId: 'p', name: '讲义', path: '', pageCount: 25);
      await repo.savePages(pagesOf(List.generate(25, (i) => '第${i + 1}页的内容 ${body(2)}')));

      final ok = FakeLlm({
        'chapters': [
          {'title': '基础', 'startPage': 1, 'endPage': 12},
          {'title': '进阶', 'startPage': 13, 'endPage': 25},
        ]
      });
      var plan = await ChapterService(repo, settings, llm: () async => ok).autoPlan(doc);
      expect(ok.calls, 1);
      expect(plan.source, 'ai');
      expect(plan.chapters.map((c) => c.title), ['基础', '进阶']);

      final bad = FakeLlm(null);
      plan = await ChapterService(repo, settings, llm: () async => bad).autoPlan(doc);
      expect(plan.source, 'fixed');
      expect(plan.chapters.map((c) => c.title), ['第 1–10 页', '第 11–20 页', '第 21–25 页']);

      plan = await ChapterService(repo, settings, llm: () async => null).autoPlan(doc);
      expect(plan.source, 'fixed');
    });
  });

  group('编辑操作', () {
    final base = [ChapterRange('一', 1, 10), ChapterRange('二', 11, 20), ChapterRange('三', 21, 30)];
    test('重命名 / 拆分 / 新增', () {
      expect(renameChapter(base, 1, ' 第二章 ')[1].title, '第二章');
      final s = splitChapter(base, 0, 6, '一（下）');
      expect(s.map((c) => (c.title, c.start, c.end)).toList(), [('一', 1, 5), ('一（下）', 6, 10), ('二', 11, 20), ('三', 21, 30)]);
      expect(splitChapter(base, 0, 1, 'x').length, 3); // 起始页不能拆
      final a = addChapter(base, 25, '三（下）');
      expect(a.map((c) => (c.start, c.end)).toList(), [(1, 10), (11, 20), (21, 24), (25, 30)]);
      expect(base.first.end, 10); // 原列表不变
    });

    test('合并 / 删除 / 调整起始页，结果始终有效', () {
      final m = mergeWithNext(base, 0);
      expect(m.map((c) => (c.title, c.start, c.end)).toList(), [('一', 1, 20), ('三', 21, 30)]);
      expect(deleteChapter(base, 0).first.start, 1);
      expect(deleteChapter(base, 2).last.end, 30);
      final st = setChapterStart(base, 1, 8);
      expect(st.map((c) => (c.start, c.end)).toList(), [(1, 7), (8, 20), (21, 30)]);
      expect(setChapterStart(base, 1, 1).map((c) => c.start).toList(), [1, 11, 21]); // 非法不改
      for (final l in [m, deleteChapter(base, 1), st, fixedRanges(30, 7)]) {
        expect(validRanges(l, 30), isTrue);
      }
    });
  });

  test('保存方案后：重新切块，已生成的闪卡/题目/知识点按页码重新归章', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    final repo = Repository(MemoryDocStore());
    final doc = PdfDoc(id: 'd', projectId: 'p', name: '讲义', path: '', pageCount: 30);
    await repo.saveDoc(doc);
    await repo.savePages(pagesOf(List.generate(30, (i) => '内容 ${i + 1}\n${body(3)}')));
    await repo.saveCards([
      Flashcard(id: 'c1', projectId: 'p', docId: 'd', chapter: '未分章', section: '旧小节', front: 'a', back: 'b', page: 5),
      Flashcard(id: 'c2', projectId: 'p', docId: 'd', chapter: '未分章', front: 'a', back: 'b', page: 25),
      Flashcard(id: 'c3', projectId: 'p', docId: 'other', chapter: '别的资料', front: 'a', back: 'b', page: 25),
      Flashcard(id: 'c4', projectId: 'p', docId: 'd', chapter: '无出处', front: 'a', back: 'b'),
    ]);
    await repo.saveQuestions([Question(id: 'q1', projectId: 'p', docId: 'd', chapter: '未分章', type: '单选', stem: 's', answer: 'A', page: 12)]);
    await repo.saveKps([KnowledgePoint(id: 'k1', projectId: 'p', docId: 'd', chapter: '未分章', title: 't', page: 21)]);

    final svc = ChapterService(repo, settings);
    final plan = ChapterPlan(docId: 'd', projectId: 'p', source: 'manual', chapters: fixedRanges(30, 10));
    await svc.apply(doc, renamePlan(plan));

    final cards = {for (final c in await repo.cards(projectId: 'p')) c.id: c};
    expect(cards['c1']!.chapter, '集合');
    expect(cards['c1']!.section, '');
    expect(cards['c2']!.chapter, '函数');
    expect(cards['c3']!.chapter, '别的资料');
    expect(cards['c4']!.chapter, '无出处');
    expect((await repo.questions(projectId: 'p')).single.chapter, '映射');
    expect((await repo.kps('p')).single.chapter, '函数');
    final chunks = await repo.chunks('p');
    expect(chunks.map((c) => c.chapter).toSet(), {'集合', '映射', '函数'});
    expect((await repo.chapterPlan('d'))!.source, 'manual');

    // 手动方案在重新解析时保留
    final again = await svc.autoPlan(doc);
    expect(again.chapters.map((c) => c.title), ['集合', '映射', '函数']);
  });
}

ChapterPlan renamePlan(ChapterPlan p) {
  var l = p.chapters;
  for (final (i, t) in [(0, '集合'), (1, '映射'), (2, '函数')]) {
    l = renameChapter(l, i, t);
  }
  return ChapterPlan(docId: p.docId, projectId: p.projectId, source: 'manual', chapters: l);
}
