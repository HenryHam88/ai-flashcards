import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactoryFfi, databaseFactory;

import 'app_state.dart';
import 'data/doc_store.dart';
import 'data/repository.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/platform.dart';
import 'services/reminder.dart';
import 'services/secret_store.dart';
import 'services/settings.dart';
import 'theme/glass.dart';
import 'ui/onboarding_page.dart';
import 'ui/home_page.dart';
import 'ui/me_page.dart';
import 'ui/review_tab.dart';
import 'ui/stats_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final desktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  if (Platform.isLinux || Platform.isWindows) {
    // 桌面没有 sqflite 原生插件：用 FFI，数据库放在固定的应用数据目录（升级后数据还在）
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(p.join((await getApplicationSupportDirectory()).path, 'databases'));
  }
  if (Platform.isMacOS) {
    // macOS 版不启用沙盒，跳过 file_picker 的沙盒权限检查
    await FilePicker.skipEntitlementsChecks();
  }
  final store = await SqliteDocStore.open();
  final prefs = await SharedPreferences.getInstance();
  final repo = Repository(store);
  await repo.loadDocTypes();
  final SecretStore secrets =
      desktop ? await DesktopSecretStore.create(prefs, await getApplicationSupportDirectory()) : SecureSecretStore();
  final settings = Settings(prefs, secrets);
  await settings.ensureMigrated();
  final state = AppState(repo, settings);
  // 老用户升级上来已经有数据，不再显示首次引导
  if (!state.settings.onboarded && (await repo.projects()).isNotEmpty) state.settings.onboarded = true;
  try {
    state.appVersion = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  runApp(StudyApp(state: state));
  // 启动后的轻量后台任务：每周自动备份、重新安排复习提醒（失败不影响使用）
  Future(() async {
    try {
      await (await state.backup()).autoBackupIfDue();
    } catch (_) {}
    try {
      if (state.settings.reminderOn) {
        await Reminder.schedule(on: true, minutes: state.settings.reminderMinutes);
      }
    } catch (_) {}
  });
}

class StudyApp extends StatelessWidget {
  final AppState state;
  final String? fontFamily;
  final Widget? home;
  const StudyApp({super.key, required this.state, this.fontFamily, this.home});
  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
        value: state,
        child: Selector<AppState, String>(
            // 只在外观相关设置变化时重建 MaterialApp
            selector: (_, s) => s.appearanceKey,
            builder: (context, _, _) {
          final st = state.settings;
          final platformDark = MediaQueryData.fromView(View.of(context)).platformBrightness == Brightness.dark;
          final dark = st.themeMode == 'dark' || (st.themeMode == 'system' && platformDark);
          M.apply(dark);
          MathText.mathScale = st.mathScale;
          M.haptics = st.haptics;
          return MaterialApp(
            key: ValueKey('theme-$dark'), // 切换深浅色时整体重建，静态调色板才能生效
            title: '闪卡刷题',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(fontFamily: fontFamily, reduceMotion: st.reduceMotion),
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(
                  textScaler: TextScaler.linear(st.textScale),
                  disableAnimations: mq.disableAnimations || st.reduceMotion,
                ),
                child: child!,
              );
            },
            home: home ?? (st.onboarded ? const AppShell() : const AppOnboarding()),
          );
        }),
      );
}

/// 手机用底部导航（[HomeShell]）；桌面窗口够宽时用左侧栏（[DesktopShell]）。
class AppShell extends StatelessWidget {
  const AppShell({super.key});
  @override
  Widget build(BuildContext context) {
    if (!Desk.platform) return const HomeShell();
    return LayoutBuilder(
        builder: (context, c) => c.maxWidth >= Desk.breakpoint ? const DesktopShell() : const HomeShell());
  }
}

/// 首次引导：桌面上居中显示成窄的向导，不铺满整个窗口。
class AppOnboarding extends StatelessWidget {
  const AppOnboarding({super.key});
  @override
  Widget build(BuildContext context) {
    if (!Desk.platform) return const OnboardingPage();
    return BlobBackground(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: M.sheet.withValues(alpha: 0.6),
                  border: Border.all(color: M.line.withValues(alpha: 0.8)),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const OnboardingPage(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  final int initialTab;
  final DateTime? statsNow; // 截图用：固定统计页的「现在」
  const HomeShell({super.key, this.initialTab = 0, this.statsNow});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.home_rounded, '首页'),
      (Icons.style_rounded, '复习'),
      (Icons.insights_rounded, '统计'),
      (Icons.person_rounded, '我的'),
    ];
    return BlobBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: IndexedStack(index: tab, children: [
          HomePage(onTab: (i) => setState(() => tab = i)),
          const ReviewTab(),
          StatsPage(now: widget.statsNow),
          const MePage(),
        ]),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                height: 66,
                decoration: BoxDecoration(
                  color: M.glass.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: M.line.withValues(alpha: 0.8)),
                ),
                child: Row(children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(26),
                        onTap: () => setState(() => tab = i),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(items[i].$1, color: tab == i ? M.sageDark : M.sub, size: 24),
                          const SizedBox(height: 2),
                          Text(items[i].$2,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: tab == i ? M.sageDark : M.sub,
                                  fontWeight: tab == i ? FontWeight.w700 : FontWeight.w400)),
                        ]),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
