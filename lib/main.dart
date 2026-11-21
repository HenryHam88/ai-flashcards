import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'data/doc_store.dart';
import 'data/repository.dart';
import 'services/reminder.dart';
import 'services/settings.dart';
import 'theme/glass.dart';
import 'ui/onboarding_page.dart';
import 'ui/home_page.dart';
import 'ui/me_page.dart';
import 'ui/review_page.dart';
import 'ui/review_tab.dart';
import 'ui/stats_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await SqliteDocStore.open();
  final prefs = await SharedPreferences.getInstance();
  final repo = Repository(store);
  await repo.loadDocTypes();
  final state = AppState(repo, Settings(prefs, SecureSecretStore()));
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
            home: home ?? (st.onboarded ? const HomeShell() : const OnboardingPage()),
          );
        }),
      );
}

class HomeShell extends StatefulWidget {
  final int initialTab;
  final bool restoreSession;
  final DateTime? statsNow; // 截图用：固定统计页的「现在」
  const HomeShell({super.key, this.initialTab = 0, this.restoreSession = true, this.statsNow});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int tab = widget.initialTab;

  @override
  void initState() {
    super.initState();
    // 进程被系统杀掉后重新打开：自动回到上次的复习位置
    if (widget.restoreSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final s = context.read<AppState>().settings.reviewSession;
        if (s != null && mounted) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ReviewPage(projectId: s['projectId'] as String?, resume: true)));
        }
      });
    }
  }

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
