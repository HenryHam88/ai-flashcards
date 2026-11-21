import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/stats.dart';
import '../theme/glass.dart';
import 'project_page.dart';
import 'review_page.dart';
import '../services/due_schedule.dart';
import 'due_page.dart';

class StatsData {
  final List<LogEntry> logs;
  final List<StudySession> sessions;
  final List<Flashcard> cards;
  final List<Question> questions;
  final List<WrongEntry> wrong;
  final Map<String, String> projectNames;
  StatsData(this.logs, this.sessions, this.cards, this.questions, this.wrong, this.projectNames);
}

Future<StatsData> loadStats(AppState s) async => StatsData(
  await s.repo.logs(),
  await s.repo.sessions(),
  await s.repo.cards(),
  await s.repo.questions(),
  await s.repo.wrong(),
  {for (final p in await s.repo.projects()) p.id: p.name},
);

/// 学习数据：每日概览、热力图、遗忘预测、掌握度、薄弱点推荐。
class StatsPage extends StatefulWidget {
  /// 截图 / 测试用：固定「现在」。
  final DateTime? now;
  const StatsPage({super.key, this.now});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  int horizon = 7;
  final expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return FutureBuilder<StatsData>(
      key: ValueKey(s.version),
      future: loadStats(s),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const SizedBox();
        final now = widget.now ?? DateTime.now();
        final hour = s.settings.dayStartHour;
        final ov = dailyOverview(d.logs, d.sessions, now: now, startHour: hour);
        // 90 天 / 全部：天数取到最远一张卡的到期日（最多 10 年）
        var far = 30;
        if (horizon == 0 || horizon > 30) {
          for (final c in d.cards) {
            if (!c.suspended && c.reps > 0) far = max(far, dayOffset(c.due, now, startHour: hour) + 1);
          }
          far = min(max(far, horizon), 3650);
        }
        final fc = forecast(d.cards, now, days: far, startHour: hour);
        final (pm, cm) = masteryOf(d.cards, now);
        final weak = weakSpots(d.cards, d.questions, d.wrong, now);
        return SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 110),
            children: [
              const Text('统计', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              _overview(ov),
              const SectionTitle('学习热力图'),
              Glass(
                child: Heatmap(data: ov.heatmap, today: now, startHour: hour),
              ),
              SectionTitle(
                '遗忘预测',
                trailing: _seg(
                  {7: '7 天', 30: '30 天', 90: '90 天', 0: '全部'},
                  horizon,
                  (v) => setState(() => horizon = v),
                ),
              ),
              _forecast(fc, now),
              const SectionTitle('掌握度'),
              _mastery(pm, cm, d.projectNames),
              const SectionTitle('薄弱点推荐'),
              _weak(weak, d),
              const SectionTitle('累计'),
              Row(
                children: [
                  _stat('累计复习', '${d.logs.where((l) => l.kind == 'card').length}'),
                  const SizedBox(width: 10),
                  _stat('闪卡总数', '${d.cards.length}'),
                  const SizedBox(width: 10),
                  _stat('错题', '${d.wrong.length}', color: M.roseDark),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stat(String label, String value, {Color? color, String? sub}) => Expanded(
    child: Glass(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      child: Column(
        children: [
          FittedBox(
            child: Text(
              value,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: color),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: M.sub, fontSize: 12)),
          if (sub != null) Text(sub, style: TextStyle(color: M.sub, fontSize: 11)),
        ],
      ),
    ),
  );

  Widget _seg(Map<int, String> opts, int value, ValueChanged<int> on) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final e in opts.entries)
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Glass(
            radius: 14,
            tint: value == e.key ? M.sage : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            onTap: () => on(e.key),
            child: Text(
              e.value,
              style: TextStyle(
                fontSize: 12,
                color: value == e.key ? Colors.white : M.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
    ],
  );

  Widget _overview(DailyOverview ov) => Column(
    children: [
      Glass(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('今日', style: TextStyle(color: M.sub, fontSize: 13)),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${ov.reviews + ov.answers}',
                        style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 4),
                      Text('次练习', style: TextStyle(color: M.sub)),
                    ],
                  ),
                  Text(
                    '新学 ${ov.newCards} · 复习 ${ov.reviewCards} · 答题 ${ov.answers}',
                    style: TextStyle(color: M.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
            Column(
              children: [
                Icon(Icons.local_fire_department_rounded, color: ov.streak > 0 ? M.roseDark : M.mist, size: 30),
                Text('${ov.streak} 天', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                Text('连续学习', style: TextStyle(color: M.sub, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _stat('正确率', ov.accuracy == null ? '—' : '${(ov.accuracy! * 100).round()}%', color: M.sageDark),
          const SizedBox(width: 10),
          _stat('学习时长', fmtDuration(ov.seconds)),
        ],
      ),
    ],
  );

  Widget _forecast(Forecast fc, DateTime now) {
    final daily = horizon == 7 || horizon == 30;
    final buckets = forecastBuckets(fc.perDay, horizon, now);
    final data = daily ? fc.perDay.take(horizon).toList() : [for (final b in buckets) b.count];
    final total = daily ? data.fold<int>(0, (a, b) => a + b) : fc.perDay.fold<int>(0, (a, b) => a + b);
    final unit = buckets.length > 1 && buckets[1].label.endsWith('月') ? '按月' : '按周';
    final title = horizon == 0 ? '全部到期 $total 张' : '未来 $horizon 天到期 $total 张';
    void openDay(int i) => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DueByDayPage(initialOffset: daily ? i : buckets[i].start, now: widget.now),
      ),
    );
    return Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (fc.overdue > 0)
                Text(
                  '已逾期 ${fc.overdue} 张',
                  style: TextStyle(color: M.roseDark, fontSize: 12, fontWeight: FontWeight.w600),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: BarChart(
              values: data,
              labelEvery: daily ? (horizon == 7 ? 1 : 5) : (data.length > 8 ? (data.length / 6).ceil() : 1),
              highlightFirst: true,
              labels: daily ? null : [for (final b in buckets) b.label],
              onTap: openDay,
            ),
          ),
          const SizedBox(height: 6),
          Text(daily ? '点柱子查看那天要复习哪些卡' : '$unit合计 · 点柱子查看那段时间第一天的卡', style: TextStyle(color: M.sub, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _bar(double v, {Color? color}) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: LinearProgressIndicator(
      value: v.clamp(0, 1),
      minHeight: 7,
      backgroundColor: M.mist.withValues(alpha: 0.6),
      color: color ?? M.sage,
    ),
  );

  Widget _mastery(List<Mastery> pm, List<Mastery> cm, Map<String, String> names) {
    if (pm.isEmpty) {
      return Glass(
        child: Text('还没有卡片', style: TextStyle(color: M.sub)),
      );
    }
    pm.sort((a, b) => b.total.compareTo(a.total));
    return Glass(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          for (final p in pm) ...[
            InkWell(
              onTap: () => setState(
                () => expanded.contains(p.projectId) ? expanded.remove(p.projectId) : expanded.add(p.projectId),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            names[p.projectId] ?? '未命名',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${(p.mastery * 100).round()}%',
                          style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w700),
                        ),
                        Icon(
                          expanded.contains(p.projectId) ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          color: M.sub,
                          size: 20,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _bar(p.mastery),
                    const SizedBox(height: 4),
                    Text(
                      '已学 ${p.learned}/${p.total} 张 · 平均稳定性 ${p.avgStability.toStringAsFixed(1)} 天',
                      style: TextStyle(color: M.sub, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
            if (expanded.contains(p.projectId)) ..._chapters(cm.where((c) => c.projectId == p.projectId).toList()),
          ],
        ],
      ),
    );
  }

  List<Widget> _chapters(List<Mastery> l) {
    l.sort((a, b) => a.mastery.compareTo(b.mastery));
    final learned = l.where((c) => c.learned > 0).toList();
    final weakest = learned.isEmpty ? null : learned.first;
    return [
      for (final c in l)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 0, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(c.chapter, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                  ),
                  if (identical(c, weakest))
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: M.rose.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '最薄弱',
                        style: TextStyle(fontSize: 10, color: M.roseDark, fontWeight: FontWeight.w700),
                      ),
                    ),
                  Text(
                    c.learned == 0 ? '未学' : '${(c.mastery * 100).round()}%',
                    style: TextStyle(color: M.sub, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _bar(c.mastery, color: identical(c, weakest) ? M.rose : M.greyBlue),
            ],
          ),
        ),
    ];
  }

  Widget _weak(List<WeakSpot> l, StatsData d) {
    if (l.isEmpty) {
      return Glass(
        child: Text(
          '目前没有明显的薄弱点。多复习几轮后，这里会根据遗忘次数、错题和记忆率给出建议。',
          style: TextStyle(color: M.sub, fontSize: 13, height: 1.6),
        ),
      );
    }
    return Column(
      children: [
        for (final w in l)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Glass(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.trending_down_rounded, color: M.roseDark, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          w.chapter,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [d.projectNames[w.projectId] ?? '', ...w.reasons].where((e) => e.isNotEmpty).join(' · '),
                    style: TextStyle(color: M.sub, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: GlassButton(
                          label: '复习这些',
                          icon: Icons.style_outlined,
                          onTap: w.cardIds.isEmpty
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ReviewPage(projectId: w.projectId, cardIds: w.cardIds),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 3,
                        child: GlassButton(
                          label: '针对这些出新题',
                          icon: Icons.auto_awesome_rounded,
                          tint: M.sage,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ProjectPage(
                                projectId: w.projectId,
                                genPreset: GenOptions(
                                  scope: w.chapter == '未分章' ? 'whole' : 'chapters',
                                  chapters: [if (w.chapter != '未分章') w.chapter],
                                  cardCount: 10,
                                  questionCount: 10,
                                  focus: ['易错点', '计算应用'],
                                  custom: '这是我的薄弱环节（${w.reasons.join('，')}），请重点考查容易遗忘和出错的地方，换角度出题，不要与已有内容重复。',
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// GitHub 风格热力图：最近 26 周，每列一周（周一在上）。
class Heatmap extends StatelessWidget {
  final Map<DateTime, int> data;
  final DateTime today;
  final int startHour;
  final int weeks;
  const Heatmap({super.key, required this.data, required this.today, this.startHour = 0, this.weeks = 26});
  @override
  Widget build(BuildContext context) {
    final t = today.subtract(Duration(hours: startHour));
    final day0 = DateTime(t.year, t.month, t.day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: weeks / 7 * 0.92,
          child: CustomPaint(painter: _HeatPainter(data, day0, weeks, M.mist, M.sage, M.sageDark, M.dark)),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('近半年 · ${data.values.where((v) => v > 0).length} 天有学习', style: TextStyle(color: M.sub, fontSize: 11)),
            const Spacer(),
            Text('少 ', style: TextStyle(color: M.sub, fontSize: 11)),
            for (final k in [0, 1, 2, 3, 4])
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: _HeatPainter.levelColor(k, M.mist, M.sage, M.sageDark, M.dark),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            Text(' 多', style: TextStyle(color: M.sub, fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

class _HeatPainter extends CustomPainter {
  final Map<DateTime, int> data;
  final DateTime today;
  final int weeks;
  final Color empty, mid, full;
  final bool dark;
  _HeatPainter(this.data, this.today, this.weeks, this.empty, this.mid, this.full, this.dark);

  static Color levelColor(int level, Color empty, Color mid, Color full, bool dark) => switch (level) {
    0 => empty.withValues(alpha: dark ? 0.5 : 0.7),
    1 => mid.withValues(alpha: 0.35),
    2 => mid.withValues(alpha: 0.65),
    3 => mid,
    _ => full,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final cell = min(size.width / weeks, size.height / 7);
    final gap = cell * 0.18;
    final maxV = max(1, data.values.fold<int>(0, max));
    // 最后一列是本周，today 在它的 weekday 行
    final lastMonday = today.subtract(Duration(days: today.weekday - 1));
    final p = Paint();
    for (var w = 0; w < weeks; w++) {
      for (var d = 0; d < 7; d++) {
        final day = DateTime(lastMonday.year, lastMonday.month, lastMonday.day - (weeks - 1 - w) * 7 + d);
        if (day.isAfter(today)) continue;
        final v = data[day] ?? 0;
        final level = v == 0 ? 0 : (1 + (3 * v / maxV).ceil()).clamp(1, 4);
        p.color = levelColor(level, empty, mid, full, dark);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * cell, d * cell, cell - gap, cell - gap),
            Radius.circular(cell * 0.2),
          ),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HeatPainter old) => old.data != data || old.today != today || old.dark != dark;
}

/// 简单柱状图（遗忘预测）。
class BarChart extends StatelessWidget {
  final List<int> values;
  final int labelEvery;
  final bool highlightFirst;

  /// 自定义横轴标签（按周 / 按月聚合时）；为空时用「今天 / +i」。
  final List<String>? labels;
  final ValueChanged<int>? onTap;
  const BarChart({
    super.key,
    required this.values,
    this.labelEvery = 1,
    this.highlightFirst = false,
    this.labels,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final maxV = max(1, values.fold<int>(0, max));
    final dense = values.length > 10;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap == null ? null : () => onTap!(i),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (!dense || values[i] == maxV)
                    Text(
                      '${values[i]}',
                      style: TextStyle(fontSize: dense ? 9 : 11, color: M.sub),
                    ),
                  const SizedBox(height: 3),
                  Container(
                    height: 76 * values[i] / maxV + 2,
                    margin: EdgeInsets.symmetric(horizontal: dense ? 1 : 6),
                    decoration: BoxDecoration(
                      color: i == 0 && highlightFirst ? M.sage : M.greyBlue.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(dense ? 2 : 6),
                    ),
                  ),
                  const SizedBox(height: 5),
                  SizedBox(
                    height: 14,
                    child: i % labelEvery == 0
                        ? FittedBox(
                            child: Text(
                              labels != null ? labels![i] : (i == 0 ? '今天' : (dense ? '$i' : '+$i')),
                              style: TextStyle(fontSize: 11, color: M.sub),
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
