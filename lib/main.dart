import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'data/doc_store.dart';
import 'data/repository.dart';
import 'services/settings.dart';
import 'theme/glass.dart';
import 'ui/home_page.dart';
import 'ui/me_page.dart';
import 'ui/review_page.dart';
import 'ui/review_tab.dart';
import 'ui/stats_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await SqliteDocStore.open();
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(Repository(store), Settings(prefs, SecureSecretStore()));
  runApp(StudyApp(state: state));
}

class StudyApp extends StatelessWidget {
  final AppState state;
  final String? fontFamily;
  final Widget? home;
  const StudyApp({super.key, required this.state, this.fontFamily, this.home});
  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          title: '闪卡刷题',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(fontFamily: fontFamily),
          home: home ?? const HomeShell(),
        ),
      );
}

class HomeShell extends StatefulWidget {
  final int initialTab;
  final bool restoreSession;
  const HomeShell({super.key, this.initialTab = 0, this.restoreSession = true});
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
          const StatsPage(),
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
                  color: Colors.white.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.8)),
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
