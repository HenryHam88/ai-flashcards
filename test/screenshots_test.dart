// 生成界面截图：flutter test test/screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/theme/glass.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/ui/auto_count_sheet.dart';
import 'package:ai_flashcards/ui/chapter_editor_page.dart';
import 'package:ai_flashcards/ui/chapter_view_page.dart';
import 'package:ai_flashcards/ui/explain_history_page.dart';
import 'package:ai_flashcards/ui/inbox_page.dart';
import 'package:ai_flashcards/ui/onboarding_page.dart';
import 'package:ai_flashcards/ui/settings_pages.dart';
import 'package:ai_flashcards/ui/me_page.dart';
import 'package:ai_flashcards/ui/project_page.dart';
import 'package:ai_flashcards/ui/quiz_page.dart';
import 'package:ai_flashcards/ui/review_page.dart';
import 'package:ai_flashcards/ui/wrong_book_page.dart';
import 'package:ai_flashcards/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';

Future<void> _load(String family, List<String> paths) async {
  final l = FontLoader(family);
  for (final p in paths) {
    final b = File(p).readAsBytesSync();
    l.addFont(Future.value(ByteData.view(Uint8List.fromList(b).buffer)));
  }
  await l.load();
}

Future<void> loadFonts() async {
  await _load('NotoSansSC', ['test/fonts/NotoSansSC.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/workspace/toolchains/flutter';
  await _load('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  final pubCache = Platform.environment['PUB_CACHE'] ?? '${Platform.environment['HOME']}/.pub-cache';
  final katex = Directory('$pubCache/hosted/pub.dev/flutter_math_fork-0.7.4/lib/katex_fonts/fonts');
  final byFamily = <String, List<String>>{};
  for (final f in katex.listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'))) {
    final name = f.uri.pathSegments.last.split('-').first;
    byFamily.putIfAbsent(name, () => []).add(f.path);
  }
  for (final e in byFamily.entries) {
    await _load('packages/flutter_math_fork/${e.key}', e.value);
  }
}

void main() {
  late AppState state;

  setUpAll(loadFonts);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    await seedSampleData(state.repo);
  });

  Future<void> shoot(WidgetTester t, Widget home, String name, {Future<void> Function()? after}) async {
    t.view.physicalSize = const Size(1170, 2532);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(StudyApp(state: state, fontFamily: 'NotoSansSC', home: home));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    if (after != null) await after();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  }

  testWidgets('首页', (t) async {
    await shoot(t, const HomeShell(restoreSession: false), '1_home');
  });

  testWidgets('闪卡 12/32', (t) async {
    state.settings.reviewSession = {
      'projectId': 'p1',
      'ids': [for (var i = 0; i < 32; i++) 'c$i'],
      'index': 11,
      'flipped': false,
    };
    await shoot(t, const ReviewPage(projectId: 'p1', resume: true), '2_flashcard');
  });

  testWidgets('答题', (t) async {
    await shoot(t, const QuizPage(projectId: 'p2'), '3_quiz', after: () async {
      await t.tap(find.text('B'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
  });

  testWidgets('AI 解释面板', (t) async {
    state.settings.reviewSession = {
      'projectId': 'p1',
      'ids': [for (var i = 0; i < 32; i++) 'c$i'],
      'index': 11,
      'flipped': true,
    };
    await shoot(t, const ReviewPage(projectId: 'p1', resume: true), '4_ai_explain', after: () async {
      await t.tap(find.text('AI 解释'));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
  });

  testWidgets('统计', (t) async {
    await shoot(t, const HomeShell(initialTab: 2, restoreSession: false), '5_stats');
  });

  testWidgets('PDF 解析设置（两种模式都选）', (t) async {
    state.settings.ocrModes = [Settings.ocrText, Settings.ocrRich];
    await shoot(t, const OcrSettingsPage(), '6_pdf_settings');
  });

  testWidgets('混合复习：项目筛选，筛选结果写入会话并可恢复', (t) async {
    // 让「运筹学」的卡片也到期
    final ys = (await state.repo.cards(projectId: 'p3'))..forEach((c) => c.due = DateTime.now().subtract(const Duration(minutes: 5)));
    await state.repo.saveCards(ys);
    await shoot(t, const ReviewPage(), '7_review_filter', after: () async {
      expect(find.text('1 / 44'), findsOneWidget);
      await t.tap(find.text('运筹学'));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('1 / 12'), findsOneWidget);
    });
    final sess = state.settings.reviewSession!;
    expect(sess['projectId'], isNull);
    expect(sess['filter'], 'p3');
    expect((sess['ids'] as List).length, 12);
  });

  testWidgets('全部错题：项目筛选 + 跨项目重做', (t) async {
    await state.repo.saveQuestions([
      Question(id: 'q9', projectId: 'p1', type: QType.judge, stem: r'$P(A\mid B)=P(A)$ 总成立', answer: '错'),
    ]);
    await state.repo.saveWrong(WrongEntry(id: 'q1', projectId: 'p2', questionId: 'q1', lastAnswer: 'A'));
    await state.repo.saveWrong(WrongEntry(id: 'q9', projectId: 'p1', questionId: 'q9', mark: '不确定'));
    await shoot(t, const WrongBookPage(), '8_wrong_mixed', after: () async {
      expect(find.text('重做错题（2 道）'), findsOneWidget);
    });
    await t.tap(find.text('常微分方程'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('重做错题（1 道）'), findsOneWidget);
    await t.tap(find.text('全部'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.text('重做错题（2 道）'));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('测验  1/2'), findsOneWidget);
    expect(wrongRedoKey(null, ['a', 'b']), isNot(wrongRedoKey('p1', ['a', 'b'])));
  });

  testWidgets('项目页（闪卡列表）', (t) async {
    await shoot(t, const ProjectPage(projectId: 'p1'), 'project', after: () async {
      await t.tap(find.text('闪卡'));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.tap(find.text('第一章 随机事件与概率'));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
  });

  testWidgets('闪卡上一张：撤销评分并写入会话', (t) async {
    state.settings.reviewSession = {
      'projectId': 'p1',
      'ids': [for (var i = 0; i < 32; i++) 'c$i'],
      'index': 0,
      'flipped': false,
    };
    await shoot(t, const ReviewPage(projectId: 'p1', resume: true), '11_review_undo', after: () async {
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }
      expect(find.text('右滑 = 记得，左滑 = 忘了，点按翻面；上一张 / 下一张可回看'), findsOneWidget);
      await t.tap(find.text('记住了'));
      await settle();
      await t.tap(find.text('没记住'));
      await settle();
      expect(find.text('3 / 32'), findsOneWidget);
      expect(state.settings.reviewSession!['index'], 2);
      expect((state.settings.reviewSession!['undo'] as List).length, 2);
      await t.tap(find.text('上一张'));
      await settle();
      expect(find.text('2 / 32'), findsOneWidget);
      expect(state.settings.reviewSession!['index'], 1);
      expect((await state.repo.card('c1'))!.reps, 0);
      expect(find.text('•  点击翻面  •'), findsOneWidget); // 回到正面
    });
  });

  testWidgets('测验上一题：只读回看，不重复判分', (t) async {
    await state.repo.saveQuestions([
      Question(id: 'q2', projectId: 'p2', type: QType.judge, stem: '一阶方程的通解含一个任意常数', answer: '对'),
    ]);
    await shoot(t, const QuizPage(projectId: 'p2', questionIds: ['q1', 'q2'], sessionKey: 't'), 'quiz_prev', after: () async {
      await t.tap(find.text('A'));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('下一题 →'));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('上一题'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('回答错误，已加入错题本'), findsOneWidget);
      await t.tap(find.text('C'), warnIfMissed: false); // 已作答：点击无效
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('下一题 →')); // 回看后向前，回到当前题
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('测验  2/2'), findsOneWidget);
      await t.tap(find.text('上一题'));
      await t.pump(const Duration(milliseconds: 300));
    });
    expect((await state.repo.logs(projectId: 'p2')).length, 1);
    expect((await state.repo.wrong()).length, 1);
  });

  testWidgets('闪卡下一张：退回后原样前进，不重新评分', (t) async {
    state.settings.reviewSession = {
      'projectId': 'p1',
      'ids': [for (var i = 0; i < 32; i++) 'c$i'],
      'index': 0,
      'flipped': false,
    };
    await shoot(t, const ReviewPage(projectId: 'p1', resume: true), '13_review_next', after: () async {
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }
      await t.tap(find.text('记住了'));
      await settle();
      await t.tap(find.text('没记住'));
      await settle();
      final rated = (await state.repo.card('c1'))!.toJson();
      await t.tap(find.text('上一张'));
      await settle();
      await t.tap(find.text('上一张'));
      await settle();
      expect(find.text('1 / 32'), findsOneWidget);
      expect((state.settings.reviewSession!['redo'] as List).length, 2);
      await t.tap(find.text('下一张'));
      await settle();
      await t.tap(find.text('下一张'));
      await settle();
      expect(find.text('3 / 32'), findsOneWidget);
      expect((await state.repo.card('c1'))!.toJson(), rated);
      expect((await state.repo.logs(projectId: 'p1')).where((l) => l.id.startsWith('l')).length, 40);
      await t.tap(find.text('上一张'));
      await settle();
      expect(find.text('2 / 32'), findsOneWidget);
    });
    // 退回后重新评分：替换原结果，重做栈清空
    expect((state.settings.reviewSession!['redo'] as List).length, 1);
    await t.tap(find.text('记住了'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect((state.settings.reviewSession!['redo'] as List), isEmpty);
    expect((await state.repo.card('c1'))!.lapses, 0);
  });

  testWidgets('AI 解释：Markdown 标题 + 公式', (t) async {
    await state.repo.saveExplain(ExplainCache(id: 'c11', projectId: 'p1', messages: [
      {'role': 'user', 'content': '...'},
      {
        'role': 'assistant',
        'content': '下面完整重写，公式均使用 LaTeX。\n'
            '### 1. 通俗解释\n'
            r'条件概率就是**已知 $B$ 发生后** $A$ 发生的可能性，相当于把样本空间缩小到 $B$：' '\n'
            r'$$P(A\mid B)=\frac{P(AB)}{P(B)},\quad P(B)>0$$' '\n'
            '### 2. 例子\n'
            r'- 掷骰子，$B=\{2,4,6\}$，$A$ 为点数大于 3' '\n'
            r'- $P(A\mid B)=\dfrac{2/6}{3/6}=\dfrac{2}{3}$' '\n'
            '### 3. 常见误区\n'
            r'> $P(A\mid B)$ 与 $P(B\mid A)$ 一般**不相等**。'
      },
    ]));
    state.settings.reviewSession = {
      'projectId': 'p1',
      'ids': [for (var i = 0; i < 32; i++) 'c$i'],
      'index': 11,
      'flipped': false,
    };
    await shoot(t, const ReviewPage(projectId: 'p1', resume: true), '14_explain_markdown', after: () async {
      await t.tap(find.text('AI 解释'));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.drag(find.text('AI 解释').last, const Offset(0, -400));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
  });

  testWidgets('文档解析设置：各模式支持的格式', (t) async {
    await shoot(t, const OcrSettingsPage(), '15_word_doc');
  });

  testWidgets('资料列表：Word 文档', (t) async {
    await state.repo.saveDoc(PdfDoc(
        id: 'w1', projectId: 'p1', name: '第三章 讲义（老师版）', path: '', type: 'docx', pageCount: 12, parsedPages: 12, status: '已解析'));
    await state.repo.saveDoc(PdfDoc(
        id: 'w2', projectId: 'p1', name: '习题课笔记（旧版 .doc）', path: '', type: 'doc', status: '不支持',
        note: '当前解析模型不支持 Word，请在「文档解析」设置里切换到支持 Word 的模型（DeepSeek OCR 或 Kimi），或把文档另存为 PDF'));
    await shoot(t, const ProjectPage(projectId: 'p1'), '16_word_doc_list');
  });

  testWidgets('编辑章节', (t) async {
    await state.repo.saveChapterPlan(ChapterPlan(docId: 'd1', projectId: 'p1', source: 'toc', chapters: [
      ChapterRange('前置内容', 1, 8),
      ChapterRange('第一章 随机事件与概率', 9, 38),
      ChapterRange('第二章 随机变量及其分布', 39, 72),
      ChapterRange('第三章 多维随机变量及其分布', 73, 104),
      ChapterRange('第四章 随机变量的数字特征', 105, 130),
      ChapterRange('第五章 大数定律及中心极限定理', 131, 146),
      ChapterRange('第六章 样本及抽样分布', 147, 166),
      ChapterRange('第七章 参数估计', 167, 186),
    ]));
    final doc = (await state.repo.docs('p1')).firstWhere((d) => d.id == 'd1');
    await shoot(t, ChapterEditorPage(doc: doc), '18_chapter_editor');
  });

  testWidgets('我的：分组设置', (t) async {
    state.appVersion = '1.2.0';
    state.settings.dailyNewLimit = 30;
    state.settings.reminderOn = true;
    state.settings.autoBackup = true;
    await shoot(t, const HomeShell(initialTab: 3, restoreSession: false), '19_settings');
  });

  testWidgets('关于', (t) async {
    state.appVersion = '1.2.0';
    await shoot(t, const AboutPage(), '20_about', after: () async {
      await t.runAsync(() async {
        final el = t.element(find.byType(AboutPage));
        await precacheImage(const AssetImage('assets/logo.png'), el);
      });
      await t.pump(const Duration(milliseconds: 100));
    });
  });

  testWidgets('首次启动引导', (t) async {
    await shoot(t, const OnboardingPage(), '21_onboarding', after: () async {
      await t.drag(find.byType(PageView), const Offset(-300, 0));
      await t.pumpAndSettle();
    });
  });

  testWidgets('深色模式', (t) async {
    state.settings.themeMode = 'dark';
    addTearDown(() => M.apply(false));
    await shoot(t, const HomeShell(restoreSession: false), '22_dark');
  });

  testWidgets('解释历史', (t) async {
    final now = DateTime.now();
    await state.repo.saveExplain(ExplainCache(
        id: 'c11', projectId: 'p1', kind: 'card', title: '什么是条件概率？', starred: true,
        createdAt: now.subtract(const Duration(minutes: 8)),
        messages: [
          {'role': 'user', 'content': '...'},
          {'role': 'assistant', 'content': r'**通俗理解**：条件概率就是「已知 $B$ 已经发生」之后，再看 $A$ 发生的可能性。相当于把样本空间缩小到 $B$。'},
          {'role': 'user', 'content': '再举个例子'},
          {'role': 'assistant', 'content': '掷骰子……'},
        ]));
    await state.repo.saveExplain(ExplainCache(
        id: 'c2', projectId: 'p1', kind: 'card', title: '全概率公式',
        createdAt: now.subtract(const Duration(hours: 3)),
        messages: [
          {'role': 'user', 'content': '...'},
          {'role': 'assistant', 'content': r'把复杂事件 $A$ 按一组完备事件 $B_1,\dots,B_n$ 拆开分别计算，再加权求和。'},
        ]));
    await state.repo.saveExplain(ExplainCache(
        id: 'q-demo', projectId: 'p2', kind: 'question', title: r'求解微分方程 $y\prime + y = 0$ 的通解',
        createdAt: now.subtract(const Duration(days: 2)),
        messages: [
          {'role': 'user', 'content': '...'},
          {'role': 'assistant', 'content': r'这是一阶线性齐次方程，分离变量得 $\frac{dy}{y}=-dx$，积分得 $y=Ce^{-x}$。'},
        ]));
    await shoot(t, const ExplainHistoryPage(), '23_explain_history');
  });

  testWidgets('质量控制：审核这批', (t) async {
    final cards = [
      Flashcard(id: 'n1', projectId: 'p1', chapter: '第一章 随机事件与概率', front: '条件概率的乘法公式', back: r'$P(AB)=P(B)\,P(A\mid B)$，其中 $P(B)>0$', explanation: r'由条件概率定义两边同乘 $P(B)$ 得到。', page: 12),
      Flashcard(id: 'n2', projectId: 'p1', chapter: '第一章 随机事件与概率', front: r'事件 $A,B$ 独立时，$P(A\mid B)$ 等于什么？', back: r'$P(A\mid B)=P(A)$', explanation: r'独立意味着 $B$ 是否发生不影响 $A$。', page: 13),
      Flashcard(id: 'n3', projectId: 'p1', chapter: '第一章 随机事件与概率', front: '全概率公式中的完备事件组要满足什么？', back: r'两两互斥，且 $\bigcup_i B_i=\Omega$，$P(B_i)>0$', page: 14),
    ];
    final qs = [
      Question(id: 'nq1', projectId: 'p1', chapter: '第一章 随机事件与概率', type: QType.single, stem: r'已知 $P(B)=0.5$，$P(AB)=0.2$，则 $P(A\mid B)=$', options: ['0.1', '0.25', '0.4', '0.7'], answer: 'C', explanation: r'$P(A\mid B)=0.2/0.5=0.4$', page: 12),
    ];
    await state.repo.saveCards(cards);
    await state.repo.saveQuestions(qs);
    await shoot(t, InboxPage(projectId: 'p1', cardIds: [for (final c in cards) c.id], questionIds: ['nq1'],
        summary: '生成 30 张（闪卡 20，题目 10），自动修正 2 张，去重 3 张'), '24_quality_review');
  });

  final statsNow = DateTime(2026, 11, 20, 20, 30);

  testWidgets('学习数据：概览', (t) async {
    await seedStudyHistory(state.repo, statsNow);
    await shoot(t, HomeShell(initialTab: 2, restoreSession: false, statsNow: statsNow), '25_stats_overview');
  });

  testWidgets('学习数据：掌握度和薄弱点', (t) async {
    await seedStudyHistory(state.repo, statsNow);
    await shoot(t, HomeShell(initialTab: 2, restoreSession: false, statsNow: statsNow), '26_mastery', after: () async {
      await t.dragFrom(const Offset(200, 500), const Offset(0, -700));
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.text('概率论 第3章').hitTestable().first);
      await t.pump(const Duration(milliseconds: 200));
      await t.dragFrom(const Offset(200, 500), const Offset(0, -80));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
  });

  testWidgets('自动数量：预计数量与知识点列表', (t) async {
    const kps1 = [
      ('样本空间与随机事件', '定义', 9), ('事件的关系与运算', '定义', 10), ('频率与概率', '定义', 11),
      (r'概率的有限可加性', '定理', 11), (r'$P(\bar A)=1-P(A)$', '公式', 11), ('古典概型', '方法', 12),
      (r'条件概率 $P(A\mid B)$', '定义', 12), ('乘法公式', '公式', 12), ('全概率公式', '定理', 13),
      ('贝叶斯公式', '定理', 13), ('不放回抽样例题', '例题', 12), ('事件的独立性', '定义', 14),
    ];
    const kps2 = [
      ('随机变量', '定义', 39), ('分布律', '定义', 40), ('二项分布', '公式', 41),
      ('泊松分布', '公式', 42), ('分布函数的性质', '定理', 44), ('正态分布标准化', '方法', 48),
    ];
    final kps = [
      for (final (i, k) in kps1.indexed)
        KnowledgePoint(id: 'a$i', projectId: 'p1', chapter: '第一章 随机事件与概率', title: k.$1, type: k.$2, page: k.$3),
      for (final (i, k) in kps2.indexed)
        KnowledgePoint(id: 'b$i', projectId: 'p1', chapter: '第二章 随机变量及其分布', title: k.$1, type: k.$2, page: k.$3),
    ];
    final plan = GenPlan(kps, deriveAutoCount(kps.length, difficulty: '中等', cap: 40), 2);
    await shoot(t, const ProjectPage(projectId: 'p1'), '27_auto_count', after: () async {
      showAutoCountConfirm(t.element(find.byType(ProjectPage)), plan, expandList: true);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
  });

  testWidgets('章节内容：按页查看与搜索', (t) async {
    await seedChapterPages(state.repo);
    final doc = (await state.repo.docs('p1')).firstWhere((d) => d.id == 'd1');
    await shoot(t, ChapterViewPage(doc: doc, initialIndex: 1), '28_chapter_view', after: () async {
      await t.tap(find.byTooltip('在本章搜索'));
      await t.pump();
      await t.enterText(find.byType(TextField), '条件概率');
      FocusManager.instance.primaryFocus?.unfocus();
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    });
  });
}
