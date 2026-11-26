// 界面截图：flutter test test/kb_export_ui_test.dart --update-goldens
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/kb_export_sheet.dart';
import 'package:ai_flashcards/ui/settings_pages.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'kb_fixture.dart';
import 'screenshots_test.dart' show loadFonts;

void main() {
  late AppState state;
  late Directory dir;
  final saved = <(String, Uint8List, String?)>[];
  Uri? nextUri;

  setUpAll(loadFonts);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    dir = Directory.systemTemp.createTempSync('afc_kbui');
    state.appDirOverride = dir;
    saved.clear();
    nextUri = Uri.parse('content://com.android.externalstorage.documents/document/primary%3ADownload%2Fout.zip');
    saveFileOverride = ({required String fileName, required Uint8List bytes, required String mimeType, String? initialDirectory}) async {
      saved.add((fileName, bytes, initialDirectory));
      return nextUri;
    };
  });
  tearDown(() => saveFileOverride = null);

  Future<void> settle(WidgetTester t, [int n = 12]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester t, Widget home) async {
    t.view.physicalSize = const Size(1170, 2532);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.runAsync(() => seedKbData(state.repo, dir));
    await t.pumpWidget(StudyApp(state: state, fontFamily: 'NotoSansSC', home: home));
    await settle(t);
  }

  testWidgets('数据页 → 导出到 Obsidian / Notion → 保存到自己选的文件夹', (t) async {
    await open(t, const DataPage());
    expect(find.text('导出到 Obsidian / Notion'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/60_data_page_kb.png'));

    await t.tap(find.text('导出到 Obsidian / Notion'));
    await settle(t);
    expect(find.text('导出哪些内容'), findsOneWidget);
    expect(find.text('1 条'), findsNWidgets(2)); // 笔记、伴学
    expect(find.text('2 条'), findsOneWidget); // 解释
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/61_kb_export_sheet.png'));

    // 只选一个项目：数量跟着变
    await t.tap(find.text('常微分方程').last);
    await settle(t);
    expect(find.text('0 条'), findsNWidgets(3));
    await t.tap(find.text('全部').last);
    await settle(t);

    await t.ensureVisible(find.text('导出').last);
    await t.pump();
    await t.tap(find.text('导出').last);
    await settle(t, 20);
    expect(find.text('保存到文件夹'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    await t.tap(find.text('保存到文件夹'));
    await settle(t);
    expect(saved, hasLength(1));
    expect(saved.single.$1, startsWith('闪卡刷题导出-'));
    expect(saved.single.$1, endsWith('.zip'));
    expect(saved.single.$3, isNull); // 第一次：系统默认位置
    final names = ZipDecoder().decodeBytes(saved.single.$2).files.map((f) => f.name).toList();
    expect(names.any((n) => n.endsWith('使用说明.md')), isTrue);
    expect(find.textContaining('已保存到：内部存储/Download/out.zip'), findsOneWidget);
    expect(state.settings.lastSaveUri, nextUri.toString());
  });

  testWidgets('导出备份：保存会打开文件夹选择（面板关掉后也能保存），下次从上次的文件夹打开，取消有提示', (t) async {
    await open(t, const DataPage());
    state.settings.lastSaveUri = 'content://com.android.externalstorage.documents/document/primary%3ADocuments%2Fold.afcbak';
    await t.tap(find.text('导出数据'));
    await settle(t);
    await t.ensureVisible(find.text('导出').last);
    await t.pump();
    await t.tap(find.text('导出').last);
    await settle(t, 20);
    nextUri = null; // 用户在系统窗口里点了返回
    await t.tap(find.text('保存到文件夹'));
    await settle(t);
    expect(saved, hasLength(1));
    expect(saved.single.$1, endsWith('.afcbak'));
    expect(saved.single.$3, contains('Documents'));
    expect(find.text('已取消保存'), findsOneWidget);
    expect(state.settings.lastSaveUri, contains('Documents')); // 取消不改记住的位置
  });

  testWidgets('更新日志页截图', (t) async {
    t.view.physicalSize = const Size(1170, 2532);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(StudyApp(state: state, fontFamily: 'NotoSansSC', home: const ChangelogPage()));
    await settle(t);
    expect(find.textContaining('v1.5.0'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/62_changelog.png'));
    // 滚到较早的版本（之前显示错乱的位置）
    await t.dragUntilVisible(find.textContaining('v1.3.4'), find.byType(ListView), const Offset(0, -300));
    await t.drag(find.byType(ListView), const Offset(0, -700));
    await settle(t, 4);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/63_changelog_older.png'));
  });

  test('保存位置显示成看得懂的路径', () {
    expect(savedLocationLabel(Uri.parse('content://com.android.externalstorage.documents/document/primary%3ADownload%2Fa.zip'), 'a.zip'),
        '内部存储/Download/a.zip');
    expect(savedLocationLabel(Uri.parse('content://com.android.externalstorage.documents/document/1A2B-3C4D%3Abak%2Fa.zip'), 'a.zip'),
        'SD 卡/bak/a.zip');
    expect(savedLocationLabel(Uri.parse('content://com.android.providers.downloads.documents/document/raw%3A%2Fstorage%2Femulated%2F0%2FDownload%2Fa.zip'), 'a.zip'),
        '/storage/emulated/0/Download/a.zip');
    expect(savedLocationLabel(Uri.parse('content://com.android.providers.downloads.documents/document/msf%3A123'), 'a.zip'), '下载/a.zip');
    expect(savedLocationLabel(Uri.parse('content://com.baidu.netdisk.documents/document/xyz'), 'a.zip'), 'a.zip');
    expect(savedLocationLabel(Uri.file('/tmp/a.zip'), 'a.zip'), '/tmp/a.zip');
  });

  testWidgets('面板单独打开也正常（没有项目时按钮不可点）', (t) async {
    await t.pumpWidget(StudyApp(state: state, fontFamily: 'NotoSansSC', home: const Scaffold(body: KbExportSheet())));
    await settle(t);
    expect(find.text('没有可导出的内容'), findsOneWidget);
  });
}
