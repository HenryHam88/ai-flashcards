import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';
import 'project_page.dart';
import 'review_page.dart';

class HomeData {
  final int due;
  final int reviewedToday;
  final List<(Project, int cards, int questions, String firstChapter)> projects;
  HomeData(this.due, this.reviewedToday, this.projects);
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
  return HomeData(due, reviewed, ps);
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
            Glass(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReviewPage())),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.assignment_outlined, color: M.text, size: 20),
                  SizedBox(width: 8),
                  Text('待复习', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 10),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${d?.due ?? 0}', style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w700, height: 1)),
                  const SizedBox(width: 6),
                  const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('张', style: TextStyle(fontSize: 15))),
                  const Spacer(),
                  if (session != null)
                    Text('继续 ${(session['index'] as int) + 1}/${(session['ids'] as List).length}',
                        style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: d == null || d.due + d.reviewedToday == 0 ? 0 : d.reviewedToday / (d.due + d.reviewedToday),
                    minHeight: 6,
                    color: M.rose,
                    backgroundColor: M.glass.withValues(alpha: 0.6),
                  ),
                ),
              ]),
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
}
