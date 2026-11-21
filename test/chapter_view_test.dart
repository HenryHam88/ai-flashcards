import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/chapter_view_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';

void main() {
  test('组装章节页面：缺页标记未解析，小节标在开始页，来源和提示', () {
    final range = ChapterRange('第一章', 3, 6);
    final pages = [
      PageText(docId: 'd', projectId: 'p', page: 3, text: '这一页有足够多的文字内容，用来说明样本空间与随机事件之间的关系，以及它们的基本运算规律。', source: 'kimi'),
      PageText(docId: 'd', projectId: 'p', page: 4, text: '图 1', source: 'local'),
      PageText(docId: 'd', projectId: 'p', page: 5, text: '  '),
      PageText(docId: 'd', projectId: 'p', page: 9, text: '别的章节'),
    ];
    final chunks = [
      Chunk(id: 'a', projectId: 'p', docId: 'd', chapter: '第一章', section: '1.1 样本空间', pageStart: 1, pageEnd: 3, text: ''),
      Chunk(id: 'b', projectId: 'p', docId: 'd', chapter: '第一章', section: '1.1 样本空间', pageStart: 4, pageEnd: 4, text: ''),
      Chunk(id: 'c', projectId: 'p', docId: 'd', chapter: '第一章', section: '1.2 事件', pageStart: 5, pageEnd: 6, text: ''),
    ];
    final ps = buildChapterPages(range, pages, chunks);
    expect(ps.map((p) => p.page), [3, 4, 5, 6]);
    expect(ps[0].sections, ['1.1 样本空间']); // 从上一章延续过来的小节标在本章第一页，重复的不再标
    expect(ps[1].sections, isEmpty);
    expect(ps[2].sections, ['1.2 事件']);
    expect(pageNote(ps[0]), isNull);
    expect(pageNote(ps[1]), contains('文字很少'));
    expect(pageNote(ps[2]), contains('没有识别到文字'));
    expect(pageNote(ps[3], unit: '节'), '这一节还没有解析');
    expect(sourcesOf(ps), ['Kimi', '本地（PDF 文字层）']);
    expect(sourcesOf([ps[2]]), isEmpty);
    final txt = chapterPlainText('第一章', ps);
    expect(txt, startsWith('第一章\n\n【第 3 页】'));
    expect(txt, contains('【第 4 页】\n图 1'));
    expect(txt, isNot(contains('第 5 页')));
  });

  test('搜索计数：不区分大小写，公式源码也算', () {
    expect(countMatches(r'条件概率 $P(A\mid B)$，条件概率的性质', '条件概率'), 2);
    expect(countMatches('Bayes bayes BAYES', 'bayes'), 3);
    expect(countMatches(r'$\frac{a}{b}$', r'\frac'), 1);
    expect(countMatches('abc', '  '), 0);
  });

  test('解析来源显示名；旧数据没有来源时不写入', () {
    expect(PageText.sourceLabel('deepseek_rich'), 'DeepSeek OCR · 版面模式');
    expect(PageText.sourceLabel(''), '');
    expect(PageText(docId: 'd', projectId: 'p', page: 1, text: 'x').toJson().containsKey('source'), isFalse);
    expect(PageText.fromJson({'docId': 'd', 'projectId': 'p', 'page': 1, 'text': 'x', 'source': 'kimi'}).source, 'kimi');
  });

  testWidgets('章节内容：切换章节、搜索高亮计数、「用这章出题」带回预填选项', (t) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    await t.runAsync(() async {
      await seedSampleData(state.repo);
      await seedChapterPages(state.repo);
    });
    final doc = (await t.runAsync(() => state.repo.docs('p1')))!.first;
    t.view.physicalSize = const Size(1170, 4200);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    GenOptions? result;
    await t.pumpWidget(StudyApp(
        state: state,
        home: Builder(
            builder: (ctx) => TextButton(
                onPressed: () async => result = await Navigator.push<GenOptions>(
                    ctx, MaterialPageRoute(builder: (_) => ChapterViewPage(doc: doc, initialIndex: 1))),
                child: const Text('open')))));
    await t.tap(find.text('open'));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('第 11–13 页'), findsOneWidget);
    expect(find.textContaining('DeepSeek OCR · 文字模式、DeepSeek OCR · 版面模式'), findsOneWidget);
    expect(find.textContaining('文字很少'), findsOneWidget);
    expect(find.text('1.4 条件概率'), findsOneWidget);

    await t.tap(find.byIcon(Icons.search_rounded));
    await t.pump();
    await t.enterText(find.byType(TextField), '条件概率');
    await t.pump();
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('2 处匹配'), findsOneWidget);

    // 复制本章
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    await t.tap(find.byTooltip('复制本章文字'));
    await t.pump();
    expect(copied.single, contains('【第 12 页】'));

    // 下一章
    await t.tap(find.byTooltip('下一章'));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('第 14–40 页'), findsOneWidget);
    await t.tap(find.byTooltip('上一章'));
    await t.pump(const Duration(milliseconds: 100));

    ScaffoldMessenger.of(t.element(find.byType(ChapterViewPage))).clearSnackBars(); // 收起复制提示
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await t.tap(find.text('用这章出题'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(result?.scope, 'chapters');
    expect(result?.chapters, ['第一章 随机事件与概率']);
  });
}
