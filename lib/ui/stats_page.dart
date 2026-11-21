import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';

class StatsPage extends StatelessWidget {
  const StatsPage({super.key});
  static Future<(List<LogEntry>, int, int)> _load(AppState s) async =>
      (await s.repo.logs(), (await s.repo.cards()).length, (await s.repo.wrong()).length);
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return FutureBuilder<(List<LogEntry>, int, int)>(
      key: ValueKey(s.version),
      future: _load(s),
      builder: (context, snap) {
        final logs = snap.data?.$1 ?? [];
        final now = DateTime.now();
        bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
        final cardLogs = logs.where((l) => l.kind == 'card').toList();
        final quizLogs = logs.where((l) => l.kind == 'quiz').toList();
        String pct(List<LogEntry> l) =>
            l.isEmpty ? '—' : '${(100 * l.where((e) => e.correct).length / l.length).round()}%';
        final days = List.generate(7, (i) => DateTime(now.year, now.month, now.day).subtract(Duration(days: 6 - i)));
        final perDay = [for (final d in days) logs.where((l) => sameDay(l.at, d)).length];
        final maxDay = perDay.fold<int>(1, (a, b) => b > a ? b : a);
        Widget stat(String label, String value, {Color? color}) => Expanded(
              child: Glass(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                child: Column(children: [
                  Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: color)),
                  const SizedBox(height: 4),
                  Text(label, style: TextStyle(color: M.sub, fontSize: 12)),
                ]),
              ),
            );
        const wd = ['一', '二', '三', '四', '五', '六', '日'];
        return SafeArea(
          bottom: false,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 110), children: [
            const Text('统计', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            Row(children: [
              stat('今日复习', '${cardLogs.where((l) => sameDay(l.at, now)).length}'),
              const SizedBox(width: 10),
              stat('今日答题', '${quizLogs.where((l) => sameDay(l.at, now)).length}'),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              stat('闪卡记住率', pct(cardLogs), color: M.sageDark),
              const SizedBox(width: 10),
              stat('答题正确率', pct(quizLogs), color: M.sageDark),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              stat('累计复习', '${cardLogs.length}'),
              const SizedBox(width: 10),
              stat('闪卡总数', '${snap.data?.$2 ?? 0}'),
              const SizedBox(width: 10),
              stat('错题', '${snap.data?.$3 ?? 0}', color: M.roseDark),
            ]),
            const SectionTitle('近 7 天'),
            Glass(
              child: SizedBox(
                height: 150,
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                        Text('${perDay[i]}', style: TextStyle(fontSize: 11, color: M.sub)),
                        const SizedBox(height: 4),
                        Container(
                          height: 100 * perDay[i] / maxDay + 2,
                          width: 18,
                          decoration: BoxDecoration(
                            color: i == 6 ? M.sage : M.greyBlue.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(wd[days[i].weekday - 1], style: TextStyle(fontSize: 12, color: M.sub)),
                      ]),
                    ),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}
