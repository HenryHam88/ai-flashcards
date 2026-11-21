// 生成界面截图：flutter test test/screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/services/settings.dart';
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
}
