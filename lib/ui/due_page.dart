import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/due_schedule.dart';
import '../services/study_queue.dart';
import '../theme/glass.dart';
import 'review_page.dart';

/// 每日到期卡片：按天查看哪些卡什么时候到期（只读，不改变调度）。
/// 今天包含逾期和今天可学的新卡；可按项目筛选，点卡片预览正反面，可「现在复习这些」或暂停单张卡。
class DueByDayPage extends StatefulWidget {
  final int initialOffset;
  final String? projectId;
  final DateTime? now; // 测试用
  const DueByDayPage({super.key, this.initialOffset = 0, this.projectId, this.now});
  @override
  State<DueByDayPage> createState() => _DueByDayPageState();
}

class _DueByDayPageState extends State<DueByDayPage> {
  late int offset = max(0, widget.initialOffset);
  late String? filter = widget.projectId;
  bool loading = true;
  List<Flashcard> cards = [];
  List<Flashcard> freshToday = [];
  Map<String, String> names = {};
  final dayScroll = ScrollController();

  AppState get s => context.read<AppState>();
  DateTime get now => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await s.repo.cards();
    final ps = await s.repo.projects();
    final fresh = await s.studyQueue(projectId: filter, mode: StudyMode.newOnly, now: now);
    if (!mounted) return;
    setState(() {
      cards = all;
      freshToday = fresh;
      names = {for (final p in ps) p.id: p.name};
      loading = false;
    });
  }

  Future<void> _setFilter(String? pid) async {
    filter = pid;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final startHour = s.settings.dayStartHour;
    final buckets = bucketByDay(filterProject(cards, filter), now, startHour: startHour);
    final maxDay = buckets.keys.fold<int>(0, max);
    // 日期条：今天起 14 天都显示，之后只显示有卡片到期的日子
    final days = <int>{
      for (var i = 0; i < 14; i++) i,
      for (final k in buckets.keys)
        if (k > 0) k,
      offset,
    }.toList()..sort();
    int countOf(int d) => dueDay(buckets, d, freshToday: freshToday).total;
    final day = dueDay(buckets, offset, freshToday: freshToday);
    return GlassScaffold(
      title: '到期安排',
      body: loading
          ? Center(child: CircularProgressIndicator(color: M.sage))
          : Column(
              children: [
                SizedBox(
                  height: 64,
                  child: ListView(
                    controller: dayScroll,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                    children: [
                      for (final d in days)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Glass(
                            radius: 16,
                            tint: d == offset ? M.sage : null,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            onTap: () => setState(() => offset = d),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  dayLabel(d, now),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: d == offset ? Colors.white : M.text,
                                  ),
                                ),
                                Text(
                                  '${countOf(d)} 张',
                                  style: TextStyle(fontSize: 11, color: d == offset ? Colors.white70 : M.sub),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (names.length > 1)
                  ProjectFilterChips(
                    projects: [for (final e in names.entries) (e.key, e.value)],
                    value: filter,
                    onChanged: _setFilter,
                  ),
                Expanded(
                  child: day.total == 0
                      ? Center(
                          child: Text(
                            maxDay == 0 && offset > 0 ? '之后还没有到期的卡片' : '${dayLabel(offset, now)}没有到期的卡片',
                            style: TextStyle(color: M.sub),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                          children: [
                            if (day.overdue.isNotEmpty) ..._group('已逾期', day.overdue, M.roseDark),
                            if (day.due.isNotEmpty)
                              ..._group(offset == 0 ? '今天到期' : '${dayLabel(offset, now)}到期', day.due, M.sageDark),
                            if (day.fresh.isNotEmpty) ..._group('今日新卡（每日上限内）', day.fresh, M.text),
                          ],
                        ),
                ),
                if (day.total > 0)
                  SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: GlassButton(
                      label: '现在复习这些（${day.total} 张）',
                      icon: Icons.play_arrow_rounded,
                      tint: M.sage,
                      expand: true,
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ReviewPage(cardIds: day.all.map((c) => c.id).toList())),
                        );
                        await _load();
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  List<Widget> _group(String title, List<Flashcard> l, Color color) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Text(
        '$title · ${l.length}',
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13),
      ),
    ),
    for (final c in l) _tile(c),
  ];

  String _when(Flashcard c) {
    if (c.reps == 0) return '新卡';
    final d = dayOffset(c.due, now, startHour: s.settings.dayStartHour);
    final t = c.due.toLocal();
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (d < 0) return '逾期 ${-d} 天';
    return d == 0 ? '今天 $hm' : '${dayLabel(d, now)} $hm';
  }

  Widget _tile(Flashcard c) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Glass(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      onTap: () => _preview(c),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MathText(c.front, style: const TextStyle(fontSize: 14, height: 1.45)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    KindBadge(cardKind(c)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        [_when(c), names[c.projectId] ?? '', c.chapter].where((e) => e.isNotEmpty).join(' · '),
                        style: TextStyle(color: M.sub, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) => v == 'suspend' ? _suspend(c) : _preview(c),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'preview', child: Text('预览')),
              PopupMenuItem(value: 'suspend', child: Text('暂停这张卡')),
            ],
          ),
        ],
      ),
    ),
  );

  Future<void> _suspend(Flashcard c) async {
    await s.repo.saveCards([c..suspended = true]);
    s.changed();
    if (mounted) toast(context, '已暂停，不再出现在复习里；可在项目页长按恢复');
    await _load();
  }

  Future<void> _preview(Flashcard c) => showGlassSheet(
    context,
    (ctx, sc) => ListView(
      controller: sc,
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            KindBadge(cardKind(c)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [_when(c), names[c.projectId] ?? '', c.chapter].where((e) => e.isNotEmpty).join(' · '),
                style: TextStyle(color: M.sub, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '问题',
          style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w700, fontSize: 13),
        ),
        const SizedBox(height: 6),
        MathText(c.front, style: const TextStyle(fontSize: 16, height: 1.5)),
        const SizedBox(height: 16),
        Text(
          '答案',
          style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w700, fontSize: 13),
        ),
        const SizedBox(height: 6),
        MathText(c.back, style: const TextStyle(fontSize: 15, height: 1.5)),
        if (c.explanation.isNotEmpty) ...[
          const SizedBox(height: 10),
          MathText(c.explanation, style: TextStyle(fontSize: 13, height: 1.5, color: M.sub)),
        ],
      ],
    ),
  );
}
