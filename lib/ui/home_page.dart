import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/study_queue.dart';
import '../theme/glass.dart';
import 'favorites_page.dart';
import 'notes_page.dart';
import 'project_page.dart';
import 'review_page.dart';
import 'study_counts.dart';
import 'study_page.dart';

class HomeData {
  final int due;
  final int reviewedToday;
  final StudyCounts counts;
  final List<(Project, int cards, int questions, String firstChapter)> projects;
  HomeData(this.due, this.reviewedToday, this.projects, this.counts);
}

Future<HomeData> loadHomeData(AppState s) async {
  final due = (await s.dueCards()).length;
  final today = DateTime.now();
  final logs = await s.repo.logs();
  final reviewed = logs
      .where((l) => l.kind == 'card' && l.at.year == today.year && l.at.month == today.month && l.at.day == today.day)
      .length;
  final cards = await s.repo.cards();
  final qs = await s.repo.questions();
  final ps = <(Project, int, int, String)>[];
  for (final p in await s.repo.projects()) {
    final pc = cards.where((c) => c.projectId == p.id).toList();
    final ch = pc.map((c) => c.chapter).where((c) => c.isNotEmpty).toSet().take(2).join('、');
    ps.add((p, pc.length, qs.where((q) => q.projectId == p.id).length, ch));
  }
  return HomeData(due, reviewed, ps, await s.studyCounts());
}

Future<void> createProjectDialog(BuildContext context) async {
  final s = context.read<AppState>();
  final name = await promptText(context, '新建项目', hint: '例如：概率论');
  if (name == null || name.trim().isEmpty) return;
  final p = Project(id: newId(), name: name.trim());
  await s.repo.saveProject(p);
  s.changed();
  if (context.mounted) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProjectPage(projectId: p.id)));
  }
}

Future<String?> promptText(BuildContext context, String title, {String hint = '', String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: M.sheet,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('确定')),
      ],
    ),
  );
}

class HomePage extends StatelessWidget {
  final void Function(int tab) onTab;
  const HomePage({super.key, required this.onTab});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return FutureBuilder<HomeData>(
      key: ValueKey(s.version),
      future: loadHomeData(s),
      builder: (context, snap) {
        final d = snap.data;
        final session = s.settings.reviewSession;
        return SafeArea(
          bottom: false,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 110), children: [
            Row(children: [
              Glass(
                  radius: 20,
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.spa_rounded, color: M.sageDark, size: 22)),
              const Spacer(),
              IconButton(onPressed: () => onTab(2), icon: Icon(Icons.notifications_none_rounded, color: M.text)),
            ]),
            const SizedBox(height: 14),
            Text('今日复习', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: M.text)),
            const SizedBox(height: 4),
            Text('今日计划 · 保持节奏，稳步前进', style: TextStyle(color: M.sub, fontSize: 14)),
            const SizedBox(height: 16),
            StudyCountsCard(
              counts: d?.counts,
              resumeText: session == null
                  ? null
                  : '继续 ${(session['index'] as int) + 1}/${(session['ids'] as List).length}',
              onResume: session == null
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ReviewPage(projectId: session['projectId'] as String?, resume: true))),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: Glass(
                  onTap: () => createProjectDialog(context),
                  child: Row(children: [
                    Icon(Icons.create_new_folder_outlined, color: M.text),
                    SizedBox(width: 10),
                    Text('新建项目', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Glass(
                  onTap: () async {
                    final ps = d?.projects ?? [];
                    if (ps.isEmpty) {
                      await createProjectDialog(context);
                    } else {
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ProjectPage(projectId: ps.first.$1.id, autoUpload: true)));
                    }
                  },
                  child: Row(children: [
                    Icon(Icons.cloud_upload_outlined, color: M.text),
                    SizedBox(width: 10),
                    Text('上传资料', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Padding(
              padding: EdgeInsets.only(left: 4, top: 6),
              child: Text('支持 PDF / Word / TXT 自动解析与生成卡片', style: TextStyle(color: M.sub, fontSize: 12)),
            ),
            const SizedBox(height: 12),
            _sectionsRow(context, d?.projects.map((e) => e.$1).toList() ?? const []),
            SectionTitle('我的项目',
                trailing: Text('共 ${d?.projects.length ?? 0} 个', style: TextStyle(color: M.sub, fontSize: 13))),
            if (d != null && d.projects.isEmpty)
              Glass(child: Text('还没有项目，点「新建项目」开始，例如「概率论」。', style: TextStyle(color: M.sub))),
            for (final (p, nc, nq, ch) in d?.projects ?? <(Project, int, int, String)>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Glass(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProjectPage(projectId: p.id))),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                          color: M.greyBlue.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(12)),
                      child: Icon(Icons.menu_book_rounded, color: M.text, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('$nc 张卡片 · $nq 道题${ch.isEmpty ? '' : ' · $ch'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: M.sub, fontSize: 12)),
                      ]),
                    ),
                    Icon(Icons.chevron_right_rounded, color: M.sub),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
  }

  /// 跨项目入口：学习板块和笔记要先选项目（只有一个项目时直接打开），收藏显示全部项目。
  Widget _sectionsRow(BuildContext context, List<Project> projects) {
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    Future<void> pick(String what, Widget Function(String id) page) async {
      if (projects.isEmpty) {
        await createProjectDialog(context);
        return;
      }
      if (projects.length == 1) return open(page(projects.first.id));
      final id = await showGlassSheet<String>(
        context,
        (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
          Text('打开哪个项目的$what', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          for (final p in projects)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Glass(
                radius: 16,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                onTap: () => Navigator.pop(ctx, p.id),
                child: Row(children: [
                  Icon(Icons.menu_book_rounded, color: M.sageDark, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(p.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                  Icon(Icons.chevron_right_rounded, color: M.sub),
                ]),
              ),
            ),
        ]),
        initial: 0.5,
      );
      if (id != null && context.mounted) open(page(id));
    }

    Widget entry(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: Glass(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            onTap: onTap,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 18, color: M.sageDark),
              const SizedBox(width: 6),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
            ]),
          ),
        );
    return Row(children: [
      entry(Icons.account_tree_outlined, '学习板块', () => pick('学习板块', (id) => StudyPage(projectId: id))),
      const SizedBox(width: 8),
      entry(Icons.edit_note_rounded, '笔记', () => pick('笔记', (id) => NotesPage(projectId: id))),
      const SizedBox(width: 8),
      entry(Icons.star_outline_rounded, '收藏', () => open(const FavoritesPage())),
    ]);
  }
}
