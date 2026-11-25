import 'dart:io';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/help/help_articles.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/services/latex.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/help_page.dart';
import 'package:ai_flashcards/ui/settings_pages.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

String libSource({bool includeHelp = false}) => [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && (includeHelp || !f.path.contains('help_articles'))) f.readAsStringSync()
    ].join('\n');

void main() {
  group('文章内容', () {
    test('必备的文章都在，id 唯一，分类有效', () {
      final ids = helpArticles.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(helpArticles.length, greaterThanOrEqualTo(13));
      for (final a in helpArticles) {
        expect(helpCategories.any((c) => c.id == a.category), isTrue, reason: a.id);
        expect(a.title, isNotEmpty);
        expect(a.body.trim().length, greaterThan(200), reason: a.id);
      }
      for (final t in ['快速开始', '密钥', '上传教材', '章节', '生成闪卡', '质量控制', '复习闪卡', '错题本', '解释历史', '学习数据', '备份', '外观和提醒', '常见问题']) {
        expect(helpArticles.any((a) => a.title.contains(t)), isTrue, reason: t);
      }
      final faq = helpArticle(HelpIds.faq)!.body;
      for (final t in ['识别不出章节', '解析失败', '余额不足', '公式', '生成太少', '换手机', '数据存在哪里', '升级会不会丢数据', '[[contact]]']) {
        expect(faq, contains(t));
      }
    });

    test('公式都能通过 LaTeX 检查，引用的截图都存在且很小', () {
      var total = 0;
      for (final a in helpArticles) {
        expect(LatexUtil.validate(a.body), isEmpty, reason: a.id);
        for (final m in RegExp(r'\[\[img:([^|\]]+)').allMatches(a.body)) {
          final f = File('assets/help/${m[1]}');
          expect(f.existsSync(), isTrue, reason: m[1]);
          total += f.lengthSync();
        }
      }
      expect(total, lessThan(300 * 1024));
      expect(File('pubspec.yaml').readAsStringSync(), contains('assets/help/'));
    });

    test('文中「」里写的按钮和页面名称都能在应用里找到（不编造界面）', () {
      final src = libSource();
      final titles = helpArticles.map((a) => a.title).toSet();
      const examples = {'举个例子', '只出计算题，仿照课后习题的风格'};
      final missing = <String>[];
      for (final a in helpArticles) {
        for (final m in RegExp(r'「([^」]+)」').allMatches(a.body)) {
          final q = m[1]!.replaceAll('**', '');
          if (titles.contains(q) || examples.contains(q) || RegExp(r'\d|N |……').hasMatch(q)) continue;
          for (final part in q.split(RegExp(r' → | / '))) {
            if (!src.contains(part.trim())) missing.add('${a.id}: $part');
          }
        }
      }
      expect(missing, isEmpty);
    });
  });

  group('搜索', () {
    test('按标题、关键词和正文搜索，标题命中排前面', () {
      expect(searchHelp('密钥').first.article.id, HelpIds.keys);
      expect(searchHelp('换手机').map((h) => h.article.id), containsAll([HelpIds.backup, HelpIds.faq]));
      expect(searchHelp('QQ').map((h) => h.article.id), contains(HelpIds.faq));
      expect(searchHelp('fsrs').first.article.id, HelpIds.review);
      expect(searchHelp('章节 AI').first.article.id, HelpIds.chapters);
      expect(searchHelp('没有这种东西xyz'), isEmpty);
      expect(searchHelp('   '), isEmpty);
    });
    test('摘要来自命中处附近，不含 Markdown 符号和特殊块', () {
      final h = searchHelp('每批页数').firstWhere((h) => h.article.id == HelpIds.upload);
      expect(h.snippet, contains('每批页数'));
      expect(h.snippet, isNot(contains('**')));
      expect(helpPlainText('a [[img:x.webp|y]] **b** [[contact]]'), contains('2268739822'));
    });
  });

  test('各处帮助入口都指向存在的文章', () {
    final src = libSource(includeHelp: true);
    final used = RegExp(r'HelpIds\.(\w+)').allMatches(src).map((m) => m[1]!).toSet()..remove('byName');
    expect(used, containsAll(['keys', 'upload', 'chapters', 'generate', 'quality', 'quickStart']));
    for (final n in used) {
      expect(HelpIds.byName.containsKey(n), isTrue, reason: n);
      expect(helpArticle(HelpIds.byName[n]!), isNotNull, reason: n);
    }
    for (final id in HelpIds.byName.values) {
      expect(helpArticle(id), isNotNull, reason: id);
    }
    expect(isKeyError('还没有填写出题模型的 API 密钥，请到「我的 → 出题模型」填写'), isTrue);
    expect(isKeyError('账户余额不足（402）'), isTrue);
    expect(isKeyError('所选范围内没有内容'), isFalse);
  });

  group('界面', () {
    late AppState state;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    });

    Future<void> pump(WidgetTester t, Widget home) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(StudyApp(state: state, home: home));
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets('每篇文章都能打开和渲染，上一篇 / 下一篇可切换', (t) async {
      for (final a in helpArticles) {
        await pump(t, HelpArticlePage(articleId: a.id));
        expect(t.takeException(), isNull, reason: a.id);
        expect(find.text(a.title), findsWidgets, reason: a.id);
      }
      await pump(t, HelpArticlePage(articleId: helpArticles.first.id));
      expect(find.text('上一篇'), findsNothing);
      await t.scrollUntilVisible(find.text('下一篇'), 300, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('下一篇'));
      await t.pumpAndSettle();
      expect(find.text(helpArticles[1].title), findsWidgets);
    });

    testWidgets('帮助首页：分类列表、搜索、联系作者复制 QQ', (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      await pump(t, const HelpHomePage());
      for (final c in helpCategories.take(2)) {
        expect(find.text(c.title), findsOneWidget);
      }
      await t.enterText(find.byType(TextField), '换手机');
      await t.pump();
      expect(find.textContaining('找到'), findsOneWidget);
      expect(find.text('备份、迁移和恢复'), findsOneWidget);
      await t.tap(find.text('备份、迁移和恢复'));
      await t.pumpAndSettle();
      expect(find.textContaining('导出全部数据'), findsWidgets);
      Navigator.of(t.element(find.byType(HelpArticlePage))).pop();
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '');
      await t.pump();
      await t.scrollUntilVisible(find.text('作者 QQ：2268739822'), 300, scrollable: find.byType(Scrollable).first);
      await t.ensureVisible(find.text('作者 QQ：2268739822'));
      await t.pumpAndSettle();
      await t.tap(find.text('作者 QQ：2268739822'));
      await t.pump();
      expect(copied, ['2268739822']);
      expect(find.text('已复制 QQ 号'), findsOneWidget);
    });

    testWidgets('关于页：点作者 QQ 复制', (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      await pump(t, const AboutPage());
      await t.scrollUntilVisible(find.text('作者 QQ：2268739822'), 200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('作者 QQ：2268739822'));
      await t.pump();
      expect(copied, ['2268739822']);
      expect(find.text('已复制 QQ 号'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });
  });
}
