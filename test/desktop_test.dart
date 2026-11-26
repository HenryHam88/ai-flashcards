// 桌面版：外壳、快捷键和几个纯函数。
import 'dart:convert';
import 'dart:io';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/desktop/desktop_shell.dart';
import 'package:ai_flashcards/desktop/platform.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/services/reminder.dart';
import 'package:ai_flashcards/services/secret_store.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/review_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_flashcards/ui/settings_pages.dart' show pickReleaseAsset, lastSaveDirFor;

import 'sample_data.dart';

void main() {
  group('纯函数', () {
    test('按平台挑选更新安装包', () {
      final assets = [
        {'name': 'ai-flashcards-v1.5.0-arm64-v8a.apk', 'browser_download_url': 'https://x/a.apk'},
        {'name': 'ai-flashcards-v1.5.0-linux-x64.tar.gz', 'browser_download_url': 'https://x/l.tar.gz'},
        {'name': 'ai-flashcards-v1.5.0-windows-x64.zip', 'browser_download_url': 'https://x/w.zip'},
        {'name': 'ai-flashcards-v1.5.0-macos.zip', 'browser_download_url': 'http://insecure/m.zip'},
      ];
      expect(pickReleaseAsset(assets, '-linux-x64.tar.gz'), ('ai-flashcards-v1.5.0-linux-x64.tar.gz', 'https://x/l.tar.gz'));
      expect(pickReleaseAsset(assets, '-windows-x64.zip')?.$2, 'https://x/w.zip');
      expect(pickReleaseAsset(assets, '-macos.zip'), isNull, reason: '只接受 https');
      expect(pickReleaseAsset(null, '-macos.zip'), isNull);
      expect(pickReleaseAsset('oops', '-macos.zip'), isNull);
    });

    test('记住上次保存的文件夹', () {
      expect(lastSaveDirFor(''), '');
      expect(lastSaveDirFor(Uri.file('/home/u/Documents/a.apkg').toString()), '/home/u/Documents');
      expect(lastSaveDirFor('/tmp/x/b.json'), '/tmp/x');
      expect(lastSaveDirFor('content://com.android.externalstorage/tree/abc'), '');
    });

    test('应用开着时的每日提醒：到点后 2 小时内提醒一次', () {
      final m = 20 * 60; // 20:00
      expect(Reminder.dueInApp(m, DateTime(2026, 11, 25, 19, 59), ''), isFalse);
      expect(Reminder.dueInApp(m, DateTime(2026, 11, 25, 20, 0), ''), isTrue);
      expect(Reminder.dueInApp(m, DateTime(2026, 11, 25, 21, 59), ''), isTrue);
      expect(Reminder.dueInApp(m, DateTime(2026, 11, 25, 22, 1), ''), isFalse);
      expect(Reminder.dueInApp(m, DateTime(2026, 11, 25, 20, 30), '2026-11-25'), isFalse, reason: '今天已经提醒过');
      expect(Reminder.dueInApp(m, DateTime(2026, 11, 26, 20, 30), '2026-11-25'), isTrue);
    });

    test('本机加密文件保存密钥：可读回、不出现明文、被改动就作废', () async {
      final dir = Directory.systemTemp.createTempSync('afc_secret');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = FileSecretStore(dir);
      expect(await a.read('k'), isNull);
      await a.write('k', 'sk-test-123');
      await a.write('k2', '第二个');
      final b = FileSecretStore(dir);
      expect(await b.read('k'), 'sk-test-123');
      expect(await b.read('k2'), '第二个');
      final raw = File('${dir.path}/secrets.dat').readAsBytesSync();
      expect(latin1.decode(raw, allowInvalid: true).contains('sk-test-123'), isFalse);
      final key = File('${dir.path}/secret.key').readAsBytesSync();
      final enc = FileSecretStore.encrypt(key, Uint8List.fromList(utf8.encode('hello')));
      expect(utf8.decode(FileSecretStore.decrypt(key, enc)!), 'hello');
      enc[enc.length - 1] ^= 1;
      expect(FileSecretStore.decrypt(key, enc), isNull);
    });
  });

  group('桌面外壳', () {
    late AppState state;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
      state.appDirOverride = Directory.systemTemp.createTempSync('afc_desk');
      await seedSampleData(state.repo);
    });

    Future<void> settle(WidgetTester t, [int n = 8]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> pumpDesk(WidgetTester t, Size size) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(StudyApp(state: state, home: const AppShell()));
      await settle(t);
    }

    Future<void> ctrl(WidgetTester t, LogicalKeyboardKey k) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(k);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(t, 4);
    }

    testWidgets('宽窗口显示侧边栏，窄窗口退回手机布局', (t) async {
      await pumpDesk(t, const Size(1440, 900));
      expect(Desk.platform, isTrue);
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(Desk.active, isTrue);
      for (final label in ['今日', '复习', '学习板块', '笔记', '统计', '错题', '收藏', '数据', '设置']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('今日复习'), findsOneWidget);

      // Ctrl+K 打开搜索
      await ctrl(t, LogicalKeyboardKey.keyK);
      expect(find.text('搜索项目、笔记、闪卡和题目'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t, 4);
      expect(find.text('搜索项目、笔记、闪卡和题目'), findsNothing);

      // Ctrl+, 打开设置
      await ctrl(t, LogicalKeyboardKey.comma);
      expect(find.text('设置'), findsWidgets);

      t.view.physicalSize = const Size(700, 900);
      await settle(t, 3);
      expect(find.byType(DesktopShell), findsNothing);
      expect(find.byType(HomeShell), findsOneWidget);
      expect(Desk.active, isFalse);
      await t.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('复习：空格翻面，数字键评分', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(StudyApp(state: state, home: const ReviewPage()));
      await settle(t);
      final total = RegExp(r'^1 / (\d+)$');
      final title = find.byWidgetPredicate((w) => w is Text && total.hasMatch(w.data ?? ''));
      expect(title, findsOneWidget);
      final n = total.firstMatch((t.widget(title) as Text).data!)!.group(1);
      expect(find.textContaining('空格'), findsWidgets, reason: '桌面显示快捷键提示');

      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(t, 4);
      expect(find.text('记住了'), findsWidgets);
      await t.sendKeyEvent(LogicalKeyboardKey.digit3);
      await settle(t, 6);
      expect(find.text('2 / $n'), findsOneWidget);
      // 没翻面时按数字键不评分
      await t.sendKeyEvent(LogicalKeyboardKey.digit1);
      await settle(t, 4);
      expect(find.text('2 / $n'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
