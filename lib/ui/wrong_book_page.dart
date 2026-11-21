import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';
import 'quiz_page.dart';

class WrongBookPage extends StatelessWidget {
  final String? projectId;
  const WrongBookPage({super.key, this.projectId});
  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '错题本',
    body: WrongList(projectId: projectId),
  );
}

/// 每组题目生成唯一的会话键，避免和其他测验会话冲突。
String wrongRedoKey(String? projectId, List<String> ids) =>
    'wrongredo_${projectId ?? 'all'}_${ids.length}_${Object.hashAll(ids).toUnsigned(32).toRadixString(36)}';

class WrongList extends StatefulWidget {
  final String? projectId; // null：全部项目（顶部显示项目筛选）
  const WrongList({super.key, this.projectId});
  @override
  State<WrongList> createState() => _WrongListState();
}

class _WrongListState extends State<WrongList> {
  String? filter;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final mixed = widget.projectId == null;
    final projectId = widget.projectId ?? filter;
    Future<(List<(WrongEntry, Question?, Flashcard?)>, List<(String, String)>)> load() async {
      final out = <(WrongEntry, Question?, Flashcard?)>[];
      final projects = mixed ? [for (final p in await s.repo.projects()) (p.id, p.name)] : <(String, String)>[];
      for (final w in await s.repo.wrong(projectId: projectId)) {
        out.add((
          w,
          w.questionId.isEmpty ? null : await s.repo.question(w.questionId),
          w.cardId.isEmpty ? null : await s.repo.card(w.cardId),
        ));
      }
      return (out, projects);
    }

    return FutureBuilder(
      key: ValueKey(s.version),
      future: load(),
      builder: (context, snap) {
        final items = snap.data?.$1 ?? [];
        final projects = snap.data?.$2 ?? [];
        final qIds = items.where((e) => e.$2 != null).map((e) => e.$2!.id).toList();
        final header = <Widget>[
          if (items.isEmpty)
            const Glass(
              child: Text('错题本是空的。答错的题会自动收进来，连续答对 3 次后自动移出。', style: TextStyle(color: M.sub)),
            ),
          if (qIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassButton(
                label: '重做错题（${qIds.length} 道）',
                icon: Icons.replay_rounded,
                tint: M.sage,
                expand: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        QuizPage(projectId: projectId, questionIds: qIds, sessionKey: wrongRedoKey(projectId, qIds)),
                  ),
                ),
              ),
            ),
        ];
        final visible = items.where((e) => e.$2 != null || e.$3 != null).toList();
        // 懒加载：只构建屏幕上可见的错题卡片
        final list = ListView.builder(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          itemCount: header.length + visible.length,
          itemBuilder: (context, i) {
            if (i < header.length) return header[i];
            final (w, q, c) = visible[i - header.length];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: (w.mark == 'AI出错了' ? M.greyBlue : (w.mark == '不确定' ? M.oat : M.rose)).withValues(
                              alpha: 0.5,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(w.mark, style: const TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(width: 8),
                        Text(q != null ? '${q.type}题' : '闪卡', style: const TextStyle(color: M.sub, fontSize: 12)),
                        const Spacer(),
                        Text('连续答对 ${w.streak}/3', style: const TextStyle(color: M.sub, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    MathText(q?.stem ?? c!.front, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (w.lastAnswer.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      MathText('上次作答：${w.lastAnswer}', style: const TextStyle(color: M.roseDark, fontSize: 13)),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final m in ['不确定', 'AI出错了'])
                          TextButton(
                            onPressed: () => s.mark(q: q, card: q == null ? c : null, mark: m),
                            child: Text('标记$m'),
                          ),
                        TextButton(
                          onPressed: () async {
                            toast(context, '正在针对这个知识点出新题…');
                            try {
                              final qs = await s.relatedQuestions(w.projectId, w.kpId);
                              if (context.mounted) {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => QuizPage(
                                      projectId: w.projectId,
                                      questionIds: qs.map((e) => e.id).toList(),
                                      sessionKey: 'related_${w.kpId}_${qs.length}',
                                    ),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (context.mounted) toast(context, '$e');
                            }
                          },
                          child: const Text('一键出新题'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await s.repo.deleteWrong(w.id);
                            s.changed();
                          },
                          child: const Text('移出', style: TextStyle(color: M.sub)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
        if (!mixed) return list;
        return Column(
          children: [
            if (projects.length > 1)
              ProjectFilterChips(projects: projects, value: filter, onChanged: (v) => setState(() => filter = v)),
            Expanded(child: list),
          ],
        );
      },
    );
  }
}
