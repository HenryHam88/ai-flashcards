import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';
import '../ui/favorites_page.dart';
import '../ui/home_page.dart' show createProjectDialog;
import '../ui/me_page.dart';
import '../ui/notes_page.dart';
import '../ui/project_page.dart';
import '../ui/review_tab.dart';
import '../ui/settings_pages.dart' show DataPage;
import '../ui/stats_page.dart';
import '../ui/study_page.dart';
import '../ui/wrong_book_page.dart';
import 'desktop_home.dart';
import 'platform.dart';
import 'search_dialog.dart';

/// 桌面版的各个板块。
enum DeskSection { today, review, study, notes, stats, wrong, favorites, data, settings, project }

/// 桌面外壳：左侧栏 + 主区。每个板块有自己的页面栈，切换板块后回来，原来打开的页面还在。
class DesktopShell extends StatefulWidget {
  final DeskSection initial;
  final String? initialProject;
  final DateTime? statsNow; // 截图用
  const DesktopShell({super.key, this.initial = DeskSection.today, this.initialProject, this.statsNow});
  @override
  State<DesktopShell> createState() => DesktopShellState();

  static DesktopShellState? of(BuildContext context) => context.findAncestorStateOfType<DesktopShellState>();
}

class DesktopShellState extends State<DesktopShell> {
  late DeskSection section = widget.initial;
  late String? projectId = widget.initialProject;
  final _navKeys = <String, GlobalKey<NavigatorState>>{};
  final _built = <String, (DeskSection, String?)>{};
  final _focus = FocusNode(debugLabel: 'desktop-shell');

  String _keyOf(DeskSection s, String? pid) => s == DeskSection.project ? 'project:$pid' : s.name;
  String get currentKey => _keyOf(section, projectId);

  /// 当前板块的页面栈。
  NavigatorState? get navigator => _navKeys[currentKey]?.currentState;

  @override
  void initState() {
    super.initState();
    Desk.active = true;
  }

  @override
  void dispose() {
    Desk.active = false;
    _focus.dispose();
    super.dispose();
  }

  /// 切换板块；再点一次当前板块会回到这个板块的首页。
  void go(DeskSection s, {String? project}) {
    final k = _keyOf(s, project);
    if (k == currentKey) {
      navigator?.popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      section = s;
      projectId = project;
    });
  }

  /// 切到某个板块后，在它上面再打开一页。
  void openIn(DeskSection s, Widget page, {String? project}) {
    go(s, project: project);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navKeys[_keyOf(s, project)]?.currentState?.push(MaterialPageRoute(builder: (_) => page));
    });
  }

  Future<void> search() async {
    final r = await showDesktopSearch(context);
    if (r == null || !mounted) return;
    switch (r) {
      case SearchProject(:final id):
        go(DeskSection.project, project: id);
      case SearchNote(:final note):
        openIn(DeskSection.notes, NoteEditorPage(note: note));
      case SearchItem(:final projectId):
        go(DeskSection.project, project: projectId);
    }
  }

  Widget _root(DeskSection s, String? pid) => switch (s) {
        DeskSection.today => const DesktopHome(),
        DeskSection.review => const DeskPane(child: ReviewTab()),
        DeskSection.study => const ProjectChooser(kind: ChooserKind.study),
        DeskSection.notes => const ProjectChooser(kind: ChooserKind.notes),
        DeskSection.stats => DeskPane(child: StatsPage(now: widget.statsNow)),
        DeskSection.wrong => const WrongBookPage(),
        DeskSection.favorites => const FavoritesPage(),
        DeskSection.data => const DataPage(),
        DeskSection.settings => const DeskPane(child: MePage()),
        DeskSection.project => ProjectPage(projectId: pid!),
      };

  void _rootRemoved(String k) {
    // 板块首页被关掉（例如删除了正在看的项目）：回到「今日」
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _built.remove(k);
        _navKeys.remove(k);
        if (currentKey == k) {
          section = DeskSection.today;
          projectId = null;
        }
      });
    });
  }

  Widget _navigator(String k, DeskSection s, String? pid) => Navigator(
        key: _navKeys.putIfAbsent(k, () => GlobalKey<NavigatorState>(debugLabel: k)),
        pages: [MaterialPage<void>(key: ValueKey(k), child: _root(s, pid))],
        onDidRemovePage: (_) => _rootRemoved(k),
      );

  Map<ShortcutActivator, VoidCallback> get _keys {
    final mac = Desk.isMac;
    SingleActivator k(LogicalKeyboardKey key) => SingleActivator(key, control: !mac, meta: mac);
    final order = [DeskSection.today, DeskSection.review, DeskSection.study, DeskSection.notes, DeskSection.stats,
      DeskSection.wrong, DeskSection.favorites];
    final digits = [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7];
    return {
      for (var i = 0; i < order.length; i++) k(digits[i]): () => go(order[i]),
      k(LogicalKeyboardKey.keyK): search,
      k(LogicalKeyboardKey.comma): () => go(DeskSection.settings),
      k(LogicalKeyboardKey.keyN): () => createProjectDialog(navigator?.context ?? context),
      const SingleActivator(LogicalKeyboardKey.escape): () => navigator?.maybePop(),
    };
  }

  @override
  Widget build(BuildContext context) {
    Desk.active = true;
    final k = currentKey;
    if (!_built.containsKey(k)) {
      // 项目页只保留当前这个，其他板块打开过就一直保留
      _built.removeWhere((key, _) => key.startsWith('project:'));
      _built[k] = (section, projectId);
    }
    return CallbackShortcuts(
      bindings: _keys,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: BlobBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DeskSidebar(section: section, projectId: projectId, onGo: go, onSearch: search),
              Expanded(
                child: Stack(children: [
                  for (final e in _built.entries)
                    Offstage(
                      key: ValueKey('slot-${e.key}'),
                      offstage: e.key != k,
                      child: TickerMode(enabled: e.key == k, child: _navigator(e.key, e.value.$1, e.value.$2)),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 没有自带背景的页面（复习、统计、设置）放进主区时用：同样的背景，内容限宽居中。
class DeskPane extends StatelessWidget {
  final Widget child;
  final double max;
  const DeskPane({super.key, required this.child, this.max = 1000});
  @override
  Widget build(BuildContext context) =>
      BlobBackground(child: Material(type: MaterialType.transparency, child: DeskWidth(max: max, child: child)));
}

// ------------------------------------------------------------------ 左侧栏

class _SideData {
  final int due, wrong;
  final List<(Project, int)> projects;
  _SideData(this.due, this.wrong, this.projects);
}

Future<_SideData> _loadSide(AppState s) async {
  final projects = await s.repo.projects();
  final list = <(Project, int)>[];
  for (final p in projects) {
    list.add((p, (await s.studyCounts(projectId: p.id)).due));
  }
  return _SideData((await s.studyCounts()).due, (await s.repo.wrong()).length, list);
}

class DeskSidebar extends StatelessWidget {
  final DeskSection section;
  final String? projectId;
  final void Function(DeskSection s, {String? project}) onGo;
  final VoidCallback onSearch;
  const DeskSidebar({super.key, required this.section, required this.projectId, required this.onGo, required this.onSearch});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: 236,
          decoration: BoxDecoration(
            color: M.sheet.withValues(alpha: M.dark ? 0.82 : 0.72),
            border: Border(right: BorderSide(color: M.line.withValues(alpha: 0.7))),
          ),
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: FutureBuilder<_SideData>(
            key: ValueKey(s.version),
            future: _loadSide(s),
            builder: (context, snap) {
              final d = snap.data;
              Widget item(DeskSection sec, IconData icon, String label, {int badge = 0, Color? badgeColor}) => DeskNavItem(
                    icon: icon,
                    label: label,
                    active: section == sec,
                    badge: badge,
                    badgeColor: badgeColor,
                    onTap: () => onGo(sec),
                  );
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 14),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset('assets/logo.png', width: 32, height: 32,
                          errorBuilder: (_, _, _) => Icon(Icons.style_rounded, color: M.sageDark, size: 28)),
                    ),
                    const SizedBox(width: 10),
                    Text('闪卡刷题', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: M.text)),
                  ]),
                ),
                _SearchBox(onTap: onSearch),
                const SizedBox(height: 12),
                item(DeskSection.today, Icons.home_rounded, '今日', badge: d?.due ?? 0),
                item(DeskSection.review, Icons.style_rounded, '复习'),
                item(DeskSection.study, Icons.account_tree_outlined, '学习板块'),
                item(DeskSection.notes, Icons.edit_note_rounded, '笔记'),
                item(DeskSection.stats, Icons.insights_rounded, '统计'),
                item(DeskSection.wrong, Icons.bookmark_border_rounded, '错题', badge: d?.wrong ?? 0, badgeColor: M.roseDark),
                item(DeskSection.favorites, Icons.star_outline_rounded, '收藏'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
                  child: Text('我的项目', style: TextStyle(fontSize: 11.5, color: M.sub, fontWeight: FontWeight.w600, letterSpacing: 0.6)),
                ),
                Expanded(
                  child: ListView(padding: EdgeInsets.zero, children: [
                    for (var i = 0; i < (d?.projects.length ?? 0); i++)
                      _ProjectRow(
                        name: d!.projects[i].$1.name,
                        due: d.projects[i].$2,
                        color: i.isEven ? M.sage : M.greyBlue,
                        active: section == DeskSection.project && projectId == d.projects[i].$1.id,
                        onTap: () => onGo(DeskSection.project, project: d.projects[i].$1.id),
                      ),
                    DeskNavItem(
                      icon: Icons.add_rounded,
                      label: '新建项目',
                      active: false,
                      accent: true,
                      onTap: () => createProjectDialog(DesktopShell.of(context)?.navigator?.context ?? context),
                    ),
                  ]),
                ),
                Divider(height: 16, color: M.sub.withValues(alpha: 0.15)),
                item(DeskSection.data, Icons.swap_horiz_rounded, '数据'),
                item(DeskSection.settings, Icons.settings_outlined, '设置'),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchBox({required this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: M.glass.withValues(alpha: M.dark ? 0.35 : 0.7),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12), side: BorderSide(color: M.line.withValues(alpha: 0.9))),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                Icon(Icons.search_rounded, size: 17, color: M.sub),
                const SizedBox(width: 8),
                Expanded(child: Text('搜索', style: TextStyle(color: M.sub, fontSize: 13))),
                KeyCap('${Desk.mod} K'),
              ]),
            ),
          ),
        ),
      );
}

/// 快捷键小标签。
class KeyCap extends StatelessWidget {
  final String text;
  const KeyCap(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: M.glass.withValues(alpha: M.dark ? 0.3 : 0.75),
          border: Border.all(color: M.line),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(text, style: TextStyle(fontSize: 10.5, color: M.text)),
      );
}

class DeskNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool accent;
  final int badge;
  final Color? badgeColor;
  final VoidCallback onTap;
  const DeskNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.accent = false,
    this.badge = 0,
    this.badgeColor,
  });
  @override
  Widget build(BuildContext context) {
    final fg = active || accent ? M.sageDark : M.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: active ? M.sage.withValues(alpha: 0.28) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(icon, size: 19, color: active || accent ? M.sageDark : M.sub),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5, color: fg, fontWeight: active || accent ? FontWeight.w700 : FontWeight.w500)),
              ),
              if (badge > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: badgeColor ?? M.sageDark, borderRadius: BorderRadius.circular(9)),
                  child: Text(badge > 999 ? '999+' : '$badge',
                      style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  final String name;
  final int due;
  final Color color;
  final bool active;
  final VoidCallback onTap;
  const _ProjectRow({required this.name, required this.due, required this.color, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: active ? M.sage.withValues(alpha: 0.28) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          color: active ? M.sageDark : M.text,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
                ),
                if (due > 0) Text('$due 待复习', style: TextStyle(fontSize: 11.5, color: M.sub)),
              ]),
            ),
          ),
        ),
      );
}

// ------------------------------------------------------------------ 学习板块 / 笔记：先选项目

enum ChooserKind { study, notes }

class ProjectChooser extends StatelessWidget {
  final ChooserKind kind;
  const ProjectChooser({super.key, required this.kind});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final title = kind == ChooserKind.study ? '学习板块' : '笔记';
    final hint = kind == ChooserKind.study ? '选一个项目，按章节看导图、和 AI 伴学' : '选一个项目，查看和整理这个项目的笔记';
    return GlassScaffold(
      title: title,
      body: FutureBuilder<List<Project>>(
        key: ValueKey(s.version),
        future: s.repo.projects(),
        builder: (context, snap) {
          final ps = snap.data;
          if (ps == null) return const SizedBox();
          return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 40), children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(hint, style: TextStyle(color: M.sub, fontSize: 13)),
            ),
            if (ps.isEmpty)
              Glass(
                onTap: () => createProjectDialog(context),
                child: Text('还没有项目，点这里新建一个，例如「概率论」。', style: TextStyle(color: M.sub)),
              ),
            DeskGrid(children: [
              for (final p in ps)
                Glass(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => kind == ChooserKind.study ? StudyPage(projectId: p.id) : NotesPage(projectId: p.id))),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: M.greyBlue.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(12)),
                      child: Icon(kind == ChooserKind.study ? Icons.account_tree_outlined : Icons.edit_note_rounded,
                          color: M.text, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(p.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                    Icon(Icons.chevron_right_rounded, color: M.sub),
                  ]),
                ),
            ]),
          ]);
        },
      ),
    );
  }
}

/// 两列网格（宽度不够时一列），卡片等高不拉伸。
class DeskGrid extends StatelessWidget {
  final List<Widget> children;
  final double gap;
  const DeskGrid({super.key, required this.children, this.gap = 12});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth >= 620 ? 2 : 1;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
      });
}
