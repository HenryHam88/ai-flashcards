import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/study_queue.dart';
import '../theme/glass.dart';
import 'quiz_page.dart';
import 'review_page.dart';
import 'study_counts.dart';
import 'wrong_book_page.dart';

class ReviewTab extends StatelessWidget {
  const ReviewTab({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    Future<(StudyCounts, List<(Project, StudyCounts, int, int)>)> load() async {
      final qs = await s.repo.questions();
      final wrong = await s.repo.wrong();
      return (
        await s.studyCounts(),
        [
          for (final p in await s.repo.projects())
            (
              p,
              await s.studyCounts(projectId: p.id),
              qs.where((q) => q.projectId == p.id).length,
              wrong.where((w) => w.projectId == p.id).length,
            )
        ]
      );
    }

    final session = s.settings.reviewSession;
    return FutureBuilder(
      key: ValueKey(s.version),
      future: load(),
      builder: (context, snap) => SafeArea(
        bottom: false,
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 110), children: [
          const Text('复习', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          if (session != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassButton(
                label: '继续上次复习（${(session['index'] as int) + 1}/${(session['ids'] as List).length}）',
                icon: Icons.play_arrow_rounded,
                tint: M.sage,
                expand: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ReviewPage(projectId: session['projectId'] as String?, resume: true))),
              ),
            ),
          StudyCountsCard(counts: snap.data?.$1, title: '全部项目'),
          const SizedBox(height: 10),
          GlassButton(
            label: '错题本',
            icon: Icons.bookmark_border_rounded,
            expand: true,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WrongBookPage())),
          ),
          const SectionTitle('按项目'),
          for (final (p, c, nq, nw) in snap.data?.$2 ?? <(Project, StudyCounts, int, int)>[])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('新学 ${c.newAvailable} · 待复习 ${c.due} 张 · 题目 $nq 道 · 错题 $nw 道', style: TextStyle(color: M.sub, fontSize: 13)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                        child: GlassButton(
                            label: '闪卡',
                            icon: Icons.style_outlined,
                            onTap: c.newAvailable + c.due == 0
                                ? null
                                : () => Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => ReviewPage(projectId: p.id))))),
                    const SizedBox(width: 10),
                    Expanded(
                        child: GlassButton(
                            label: '测验',
                            icon: Icons.quiz_outlined,
                            onTap: nq == 0
                                ? null
                                : () => Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => QuizPage(projectId: p.id))))),
                  ]),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
