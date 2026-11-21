import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/due_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

Flashcard card(String id, DateTime due, {String p = 'p', int reps = 2, bool suspended = false}) =>
    Flashcard(id: id, projectId: p, front: id, back: id, reps: reps, due: due, suspended: suspended);

void main() {
  final now = DateTime(2026, 3, 5, 14); // 本地时间
  group('按天分组', () {
    test('今天 / 明天 / 逾期；本地时间换日', () {
      expect(dayOffset(DateTime(2026, 3, 5, 23, 59), now), 0);
      expect(dayOffset(DateTime(2026, 3, 6, 0, 1), now), 1);
      expect(dayOffset(DateTime(2026, 3, 4, 23), now), -1);
      expect(dayOffset(DateTime(2026, 3, 1), now), -4);
    });
    test('UTC 时间先换成本地时间再算', () {
      final local = DateTime(2026, 3, 6, 0, 30);
      expect(dayOffset(local.toUtc(), now), 1);
      expect(dayOffset(DateTime(2026, 3, 5, 23).toUtc(), now), 0);
    });
    test('每日开始时间：凌晨仍算前一天', () {
      final late = DateTime(2026, 3, 6, 2); // 次日凌晨 2 点
      expect(dayOffset(late, now, startHour: 4), 0);
      expect(dayOffset(late, now, startHour: 0), 1);
      // 「现在」是凌晨 1 点，开始时间 4 点：今天仍是 3/4
      final night = DateTime(2026, 3, 5, 1);
      expect(dayOffset(DateTime(2026, 3, 4, 20), night, startHour: 4), 0);
      expect(dayOffset(DateTime(2026, 3, 5, 5), night, startHour: 4), 1);
    });
    test('跨夏令时仍按日历日计算', () {
      final before = DateTime(2026, 3, 7, 12);
      expect(dayOffset(DateTime(2026, 3, 9, 0, 30), before), 2);
      expect(dayOffset(DateTime(2026, 11, 2, 23, 30), DateTime(2026, 10, 31, 23, 30)), 2);
    });
    test('分组：逾期放在 -1，暂停和新卡不算，每组按时间排序', () {
      final cards = [
        card('o1', DateTime(2026, 3, 1)),
        card('o2', DateTime(2026, 3, 4, 9)),
        card('t2', DateTime(2026, 3, 5, 20)),
        card('t1', DateTime(2026, 3, 5, 8)),
        card('d3', DateTime(2026, 3, 8, 10)),
        card('s', DateTime(2026, 3, 5, 9), suspended: true),
        card('n', DateTime(2026, 3, 5, 9), reps: 0),
      ];
      final b = bucketByDay(cards, now);
      expect(b[-1]!.map((c) => c.id), ['o1', 'o2']);
      expect(b[0]!.map((c) => c.id), ['t1', 't2']);
      expect(b[3]!.map((c) => c.id), ['d3']);
      expect(b.containsKey(1), isFalse);
      final today = dueDay(b, 0, freshToday: [cards.last]);
      expect(today.overdue.length, 2);
      expect(today.due.length, 2);
      expect(today.fresh.length, 1);
      expect(today.total, 5);
      // 其它天不含逾期和新卡
      final d3 = dueDay(b, 3, freshToday: [cards.last]);
      expect(d3.total, 1);
      expect(d3.overdue, isEmpty);
    });
    test('按项目筛选', () {
      final cards = [card('a', now, p: 'x'), card('b', now, p: 'y'), card('c', now, p: 'x')];
      expect(filterProject(cards, 'x').map((c) => c.id), ['a', 'c']);
      expect(filterProject(cards, null).length, 3);
      expect(bucketByDay(filterProject(cards, 'y'), now)[0]!.single.id, 'b');
    });
    test('日期名称', () {
      expect(dayLabel(0, now), '今天');
      expect(dayLabel(1, now), '明天');
      expect(dayLabel(2, now), '后天');
      expect(dayLabel(27, now), '4/1');
    });
  });

  group('遗忘预测分桶', () {
    final per = List.generate(400, (i) => i < 200 ? 1 : 0);
    test('7 / 30 天按天', () {
      final b = forecastBuckets(per, 7, now);
      expect(b.length, 7);
      expect(b.first.label, '今天');
      expect(b[3].label, '+3');
      expect(b[3].start, 3);
      expect(forecastBuckets(per, 30, now).length, 30);
    });
    test('90 天按周，点柱子跳到该周第一天', () {
      final b = forecastBuckets(per, 90, now);
      expect(b.length, 13); // ceil(90/7)
      expect(b.first.label, '本周');
      expect(b[1].start, 7);
      expect(b[1].end, 13);
      expect(b[1].count, 7);
      expect(b.last.start, 84);
      expect(b.last.end, 89);
      expect(b.fold<int>(0, (a, x) => a + x.count), 90);
    });
    test('全部：跨度不长按周', () {
      final short = List.generate(60, (i) => i == 59 ? 2 : 0);
      final b = forecastBuckets([...short, 0, 0, 0], 0, now);
      expect(b.length, 9); // 60 天 → 9 周，末尾的 0 不算
      expect(b.last.count, 2);
    });
    test('全部：跨度长按自然月，第一根到本月底', () {
      final b = forecastBuckets(per, 0, now); // 200 天
      expect(b.first.label, '本月');
      expect(b.first.start, 0);
      expect(b.first.end, 26); // 3/5 → 3/31
      expect(b[1].label, '4月');
      expect(b[1].start, 27);
      expect(b[1].end, 56);
      expect(b.last.end, 199);
      expect(b.fold<int>(0, (a, x) => a + x.count), 200);
    });
    test('没有到期卡片也不出错', () {
      expect(forecastBuckets([0], 0, now).length, 1);
      expect(forecastBuckets(<int>[], 90, now).length, 13);
    });
  });
}
