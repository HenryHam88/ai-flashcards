import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/stats.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 20, 15);

LogEntry log(String id, DateTime at, {String kind = 'card', bool correct = true, bool isNew = false}) =>
    LogEntry(id: id, projectId: 'p', kind: kind, correct: correct, at: at, isNew: isNew);

Flashcard card(String id, String ch, {int reps = 1, double stability = 10, int daysAgo = 1, int dueIn = 5, int lapses = 0}) =>
    Flashcard(id: id, projectId: 'p', front: id, back: id, chapter: ch)
      ..reps = reps
      ..stability = reps == 0 ? 0 : stability
      ..lapses = lapses
      ..lastReview = reps == 0 ? null : now.subtract(Duration(days: daysAgo))
      ..due = now.add(Duration(days: dueIn));

void main() {
  group('每日概览', () {
    test('今日次数、新卡/复习、正确率、时长', () {
      final o = dailyOverview([
        log('1', now.subtract(const Duration(hours: 1)), isNew: true),
        log('2', now.subtract(const Duration(hours: 2)), correct: false),
        log('3', now.subtract(const Duration(hours: 3))),
        log('4', now.subtract(const Duration(hours: 4)), kind: 'quiz', correct: false),
        log('5', now.subtract(const Duration(days: 1))),
      ], [
        StudySession(id: 's1', projectId: 'p', kind: 'review', start: now.subtract(const Duration(hours: 2)), seconds: 600),
        StudySession(id: 's2', projectId: 'p', kind: 'quiz', start: now.subtract(const Duration(hours: 1)), seconds: 300),
        StudySession(id: 's3', projectId: 'p', kind: 'quiz', start: now.subtract(const Duration(days: 1)), seconds: 999),
      ], now: now);
      expect(o.reviews, 3);
      expect(o.answers, 1);
      expect(o.newCards, 1);
      expect(o.reviewCards, 2);
      expect(o.accuracy, 0.5);
      expect(o.seconds, 900);
      expect(o.streak, 2);
    });

    test('连续天数：今天没学不打断，中间断一天就重新算', () {
      DateTime d(int ago) => DateTime(2026, 11, 20 - ago, 10);
      expect(dailyOverview([log('a', d(1)), log('b', d(2)), log('c', d(3)), log('x', d(5))], [], now: now).streak, 3);
      expect(dailyOverview([log('a', d(0)), log('b', d(2))], [], now: now).streak, 1);
      expect(dailyOverview([log('a', d(2))], [], now: now).streak, 0);
      expect(dailyOverview([], [], now: now).accuracy, isNull);
    });

    test('热力图：按天聚合，只保留最近 182 天；每日开始时间生效', () {
      final o = dailyOverview([
        log('a', DateTime(2026, 11, 19, 9)),
        log('b', DateTime(2026, 11, 19, 21)),
        log('old', DateTime(2026, 1, 1)),
      ], [], now: now);
      expect(o.heatmap[DateTime(2026, 11, 19)], 2);
      expect(o.heatmap.length, 1);
      // 凌晨 2 点、每天 4 点开始 → 算前一天
      final o2 = dailyOverview([log('a', DateTime(2026, 11, 20, 2))], [], now: now, startHour: 4);
      expect(o2.heatmap.keys.single, DateTime(2026, 11, 19));
      expect(o2.reviews, 0);
    });
  });

  test('掌握度：按项目和章节，新卡算 0，暂停的不算', () {
    final cards = [
      card('a', '第一章', stability: 1000, daysAgo: 0),
      card('b', '第一章', reps: 0),
      card('c', '第二章', stability: 1, daysAgo: 30, lapses: 2),
      card('s', '第二章')..suspended = true,
      card('n', ''),
    ];
    final (ps, chs) = masteryOf(cards, now);
    expect(ps.single.total, 4);
    expect(ps.single.learned, 3);
    final c1 = chs.firstWhere((m) => m.chapter == '第一章');
    expect(c1.mastery, closeTo(0.5, 0.01));
    final c2 = chs.firstWhere((m) => m.chapter == '第二章');
    expect(c2.total, 1);
    expect(c2.mastery, lessThan(0.5));
    expect(c2.lapses, 2);
    expect(chs.any((m) => m.chapter == '未分章'), isTrue);
  });

  test('可回忆概率随时间下降', () {
    final c = card('a', '', stability: 10, daysAgo: 0);
    expect(cardRetrievability(c, now), closeTo(1, 1e-6));
    expect(cardRetrievability(c, now.add(const Duration(days: 10))), closeTo(0.9, 0.01));
    expect(cardRetrievability(c, now.add(const Duration(days: 100))), lessThan(0.6));
    expect(cardRetrievability(card('n', '', reps: 0), now), 0);
  });

  test('遗忘预测：过期数 + 每天到期数，新卡和暂停不计', () {
    final f = forecast([
      card('o1', '', dueIn: -3),
      card('o2', '', dueIn: -1),
      card('t', '')..due = DateTime(2026, 11, 20, 23),
      card('d1', '', dueIn: 1),
      card('d1b', '', dueIn: 1),
      card('d6', '', dueIn: 6),
      card('far', '', dueIn: 60),
      card('new', '', reps: 0, dueIn: 0),
      card('sus', '', dueIn: 1)..suspended = true,
    ], now, days: 7);
    expect(f.overdue, 2);
    expect(f.perDay, [1, 2, 0, 0, 0, 0, 1]);
    expect(forecast([], now).perDay, hasLength(30));
  });

  test('薄弱点：记忆差、遗忘多、错题多的章节排前面；都掌握好就不推荐', () {
    final cards = [
      card('g1', '好章', stability: 500, daysAgo: 1),
      card('g2', '好章', stability: 500, daysAgo: 1),
      card('w1', '弱章', stability: 1, daysAgo: 20, lapses: 3),
      card('w2', '弱章', stability: 2, daysAgo: 20, lapses: 1),
      card('m1', '中章', stability: 5, daysAgo: 10),
      card('m2', '中章', stability: 5, daysAgo: 10),
    ];
    final qs = [
      for (var i = 1; i <= 4; i++) Question(id: 'q$i', projectId: 'p', type: QType.judge, stem: 's$i', answer: '对', chapter: '错题章')
    ];
    final wrong = [
      for (var i = 1; i <= 3; i++) WrongEntry(id: 'q$i', projectId: 'p', questionId: 'q$i', mark: '答错'),
      WrongEntry(id: 'q4', projectId: 'p', questionId: 'q4', mark: 'AI出错了'),
    ];
    final ws = weakSpots(cards, qs, wrong, now, top: 5);
    expect(ws.first.chapter, '弱章');
    expect(ws.first.cardIds, ['w1', 'w2']);
    expect(ws.first.reasons, contains('遗忘 4 次'));
    expect(ws.any((w) => w.chapter == '好章'), isFalse);
    final e = ws.firstWhere((w) => w.chapter == '错题章');
    expect(e.wrong, 3); // AI出错了 不算用户的薄弱点
    expect(weakSpots(cards, qs, wrong, now, top: 1), hasLength(1));
  });

  test('学习计时：空闲超过 2 分钟只算 2 分钟，少于 5 秒不记录', () {
    int? saved;
    final t = SessionTimer((s, _) => saved = s);
    final s0 = t.start;
    t.touch(s0.add(const Duration(seconds: 30)));
    t.touch(s0.add(const Duration(minutes: 30)));
    expect(t.seconds, 150);
    final t2 = SessionTimer((s, _) => saved = -1);
    t2.end();
    expect(saved, isNot(-1));
    expect(fmtDuration(0), '0 分钟');
    expect(fmtDuration(45), '45 秒');
    expect(fmtDuration(3900), '1 小时 5 分');
  });
}
