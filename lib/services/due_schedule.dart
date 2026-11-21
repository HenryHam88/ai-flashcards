/// 每日到期安排：按天分组到期的卡片，以及遗忘预测图的按天 / 按周 / 按月汇总。只读，不改变调度。
library;

import '../models.dart';
import 'study_queue.dart';

/// [t] 相对「今天」是第几天（今天 = 0，明天 = 1，逾期为负数）。按本地时间和每日开始时间换日；
/// 用日历日期相减（不受夏令时 23/25 小时的影响），UTC 时间先换成本地时间。
int dayOffset(DateTime t, DateTime now, {int startHour = 0}) {
  DateTime day(DateTime x) {
    final s = x.toLocal().subtract(Duration(hours: startHour));
    return DateTime.utc(s.year, s.month, s.day);
  }

  return day(t).difference(day(now)).inDays;
}

/// 某一天的到期卡片：逾期（只在今天显示）、当天到期、当天可学的新卡（只在今天显示）。
class DueDay {
  final int offset;
  final List<Flashcard> overdue, due, fresh;
  const DueDay(this.offset, {this.overdue = const [], this.due = const [], this.fresh = const []});
  int get total => overdue.length + due.length + fresh.length;
  List<Flashcard> get all => [...overdue, ...due, ...fresh];
}

/// 把已学过的卡按到期日分组（暂停的不算），返回 offset → 卡片（逾期的放在 -1）。每组按到期时间排序。
Map<int, List<Flashcard>> bucketByDay(Iterable<Flashcard> cards, DateTime now, {int startHour = 0}) {
  final out = <int, List<Flashcard>>{};
  for (final c in cards.where((c) => !c.suspended && c.reps > 0)) {
    final d = dayOffset(c.due, now, startHour: startHour);
    out.putIfAbsent(d < 0 ? -1 : d, () => []).add(c);
  }
  for (final l in out.values) {
    l.sort((a, b) => a.due.compareTo(b.due));
  }
  return out;
}

/// 第 [offset] 天的到期安排；今天还包括逾期和 [freshToday]（今天可学的新卡）。
DueDay dueDay(Map<int, List<Flashcard>> buckets, int offset, {List<Flashcard> freshToday = const []}) => offset == 0
    ? DueDay(0, overdue: buckets[-1] ?? const [], due: buckets[0] ?? const [], fresh: freshToday)
    : DueDay(offset, due: buckets[offset] ?? const []);

/// 按项目筛选（null = 全部）。
List<Flashcard> filterProject(Iterable<Flashcard> cards, String? projectId) =>
    projectId == null ? cards.toList() : cards.where((c) => c.projectId == projectId).toList();

/// 遗忘预测图的一根柱子：覆盖 [start, end] 天（含），点开时跳到 [start] 那天。
class ForecastBucket {
  final int start, end, count;
  final String label;
  const ForecastBucket(this.start, this.end, this.count, this.label);
  @override
  String toString() => '$label[$start-$end]=$count';
}

/// 预测范围：7 天、30 天按天；90 天按周；「全部」跨度不超过 120 天按周，更长按月。
/// [perDay]：从今天起每天到期的张数（今天含逾期之外的当天到期）。[range] 为 0 表示全部。
List<ForecastBucket> forecastBuckets(List<int> perDay, int range, DateTime now) {
  var last = perDay.length - 1;
  if (range == 0) {
    while (last > 0 && perDay[last] == 0) {
      last--;
    }
  } else {
    last = range - 1;
  }
  int at(int i) => i < perDay.length ? perDay[i] : 0;
  int sum(int a, int b) {
    var s = 0;
    for (var i = a; i <= b; i++) {
      s += at(i);
    }
    return s;
  }

  if (range == 7 || range == 30) {
    return [for (var i = 0; i <= last; i++) ForecastBucket(i, i, at(i), i == 0 ? '今天' : '+$i')];
  }
  final span = last + 1;
  if (range == 90 || span <= 120) {
    final weeks = (span / 7).ceil().clamp(1, 1 << 20);
    return [
      for (var w = 0; w < weeks; w++)
        ForecastBucket(
          w * 7,
          w * 7 + 6 > last ? last : w * 7 + 6,
          sum(w * 7, w * 7 + 6 > last ? last : w * 7 + 6),
          w == 0 ? '本周' : '+${w * 7}',
        ),
    ];
  }
  // 按自然月：第一根从今天到本月底
  final out = <ForecastBucket>[];
  final today = DateTime(now.year, now.month, now.day);
  var start = 0;
  while (start <= last) {
    final d = DateTime(today.year, today.month, today.day + start);
    final monthEnd = DateTime(d.year, d.month + 1, 0);
    var end =
        start +
        DateTime.utc(
          monthEnd.year,
          monthEnd.month,
          monthEnd.day,
        ).difference(DateTime.utc(d.year, d.month, d.day)).inDays;
    if (end > last) end = last;
    out.add(ForecastBucket(start, end, sum(start, end), start == 0 ? '本月' : '${d.month}月'));
    start = end + 1;
  }
  return out;
}

/// 到期安排页顶部的日期名称。
String dayLabel(int offset, DateTime now) {
  if (offset == 0) return '今天';
  if (offset == 1) return '明天';
  if (offset == 2) return '后天';
  final d = DateTime(now.year, now.month, now.day + offset);
  return '${d.month}/${d.day}';
}

/// 卡片身份标签（新 / 复习 / 重学）。
String badgeOf(Flashcard c) => cardKindLabel(cardKind(c));
