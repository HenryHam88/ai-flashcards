import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/fsrs.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/services/study_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final now = DateTime(2026, 3, 2, 15);

Flashcard fresh(String id, {int minAgo = 60, String p = 'p'}) =>
    Flashcard(id: id, projectId: p, front: id, back: id, due: now.subtract(Duration(minutes: minAgo)));
Flashcard studied(String id, Duration dueIn, {int lapses = 0, DateTime? last, String p = 'p'}) => Flashcard(
    id: id,
    projectId: p,
    front: id,
    back: id,
    reps: 2,
    lapses: lapses,
    stability: 3,
    difficulty: 5,
    lastReview: last ?? now.subtract(const Duration(days: 3)),
    due: now.add(dueIn));
LogEntry log(bool isNew, {DateTime? at}) =>
    LogEntry(id: newId(), projectId: 'p', kind: 'card', correct: true, isNew: isNew, at: at ?? now);

void main() {
  group('分类', () {
    test('新卡 / 复习 / 重学', () {
      expect(cardKind(fresh('a')), CardKind.fresh);
      // 刚生成的卡 due = 创建时间（已到），但仍算新卡，不算待复习
      expect(isDueReview(fresh('a'), now), isFalse);
      expect(isNewCard(fresh('a')), isTrue);
      expect(cardKind(studied('b', const Duration(hours: -1))), CardKind.review);
      final lapsed = studied('c', const Duration(minutes: 5), lapses: 1, last: now.subtract(const Duration(minutes: 5)));
      expect(cardKind(lapsed), CardKind.relearn);
      // 之前忘过、但已经按正常间隔到期的卡是复习
      expect(cardKind(studied('d', Duration.zero, lapses: 2)), CardKind.review);
      expect(cardKindLabel(CardKind.fresh), '新');
      expect(cardKindLabel(CardKind.relearn), '重学');
    });

    test('计数：新学不受到期时间影响，待复习只含学过且到期的，暂停的都不算', () {
      final cards = [
        fresh('n1'),
        fresh('n2', minAgo: -600), // 还没到「到期时间」的新卡也算新卡
        fresh('n3')..suspended = true,
        studied('r1', const Duration(hours: -30)), // 逾期
        studied('r2', Duration.zero), // 刚好到期
        studied('r3', const Duration(hours: 1)), // 还没到
        studied('r4', const Duration(hours: -1))..suspended = true,
      ];
      final c = computeCounts(cards, [], newLimit: 20, now: now);
      expect(c.newTotal, 2);
      expect(c.newAvailable, 2);
      expect(c.due, 2);
      expect(c.newProgress, '今日新卡 0/20');
      expect(c.newLimitReached, isFalse);
    });
  });

  group('每日新卡上限', () {
    final cards = [for (var i = 0; i < 30; i++) fresh('n$i', minAgo: 100 - i)];
    test('默认 20，已学的扣除，达到上限后可追加', () {
      var c = computeCounts(cards, [for (var i = 0; i < 8; i++) log(true)], newLimit: 20, now: now);
      expect(c.newAvailable, 12);
      expect(c.newProgress, '今日新卡 8/20');
      final logs20 = [for (var i = 0; i < 20; i++) log(true), log(false), log(false)];
      c = computeCounts(cards, logs20, newLimit: 20, now: now);
      expect(c.newAvailable, 0);
      expect(c.newLimitReached, isTrue);
      expect(buildQueue(cards, logs20, StudyMode.newOnly, newLimit: 20, now: now), isEmpty);
      // 今天再学 10 张
      c = computeCounts(cards, logs20, newLimit: 20, extra: 10, now: now);
      expect(c.newAvailable, 10);
      expect(c.newProgress, '今日新卡 20/30');
      expect(buildQueue(cards, logs20, StudyMode.newOnly, newLimit: 20, extra: 10, now: now).length, 10);
    });
    test('0 = 不限', () {
      final c = computeCounts(cards, [], newLimit: 0, now: now);
      expect(c.newAvailable, 30);
      expect(c.newLimitReached, isFalse);
      expect(c.newProgress, contains('不限'));
    });
    test('换日：按每日开始时间', () {
      expect(dayKey(DateTime(2026, 3, 2, 3), 4), '2026-03-01');
      expect(dayKey(DateTime(2026, 3, 2, 4), 4), '2026-03-02');
      expect(dayKey(DateTime(2026, 3, 2, 0, 30), 0), '2026-03-02');
    });
  });

  group('队列组成', () {
    final cards = [
      fresh('n1', minAgo: 50),
      fresh('n2', minAgo: 40),
      fresh('n3', minAgo: 30),
      studied('r1', const Duration(hours: -2)),
      studied('r2', const Duration(days: -3)),
      studied('later', const Duration(days: 2)),
    ];
    List<String> ids(List<Flashcard> l) => l.map((c) => c.id).toList();
    test('全部学习：先复习（逾期最久在前），再新卡（按加入顺序），新卡受上限', () {
      expect(ids(buildQueue(cards, [], StudyMode.all, newLimit: 2, now: now)), ['r2', 'r1', 'n1', 'n2']);
    });
    test('学新卡：只有新卡', () {
      expect(ids(buildQueue(cards, [], StudyMode.newOnly, newLimit: 20, now: now)), ['n1', 'n2', 'n3']);
    });
    test('复习：只有到期的复习，受每日复习上限', () {
      expect(ids(buildQueue(cards, [], StudyMode.reviewOnly, newLimit: 20, now: now)), ['r2', 'r1']);
      expect(ids(buildQueue(cards, [log(false)], StudyMode.reviewOnly, newLimit: 20, reviewLimit: 2, now: now)), ['r2']);
    });
    test('模式名可持久化', () {
      for (final m in StudyMode.values) {
        expect(studyModeOf(m.name), m);
      }
      expect(studyModeOf(null), StudyMode.all);
      expect(studyModeOf('xx'), StudyMode.all);
    });
  });

  group('AppState', () {
    late AppState s;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      s = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    });
    test('默认每日新卡 20；追加只对今天有效、不进备份', () async {
      expect(s.settings.dailyNewLimit, 20);
      await s.repo.saveCards([for (var i = 0; i < 25; i++) Flashcard(id: 'n$i', projectId: 'p', front: 'Q', back: 'A')]);
      expect((await s.studyCounts()).newAvailable, 20);
      s.extendNewToday(10);
      expect((await s.studyCounts()).newAvailable, 25);
      expect(s.settings.newExtraFor(s.todayKey()), 10);
      expect(s.settings.newExtraFor('2000-01-01'), 0);
      expect(Settings.backupKeys, isNot(contains('new_extra')));
    });
    test('学一张新卡后：新学 -1、今日新卡 +1', () async {
      await s.repo.saveCards([for (var i = 0; i < 3; i++) Flashcard(id: 'n$i', projectId: 'p', front: 'Q', back: 'A')]);
      final q = await s.studyQueue(mode: StudyMode.newOnly);
      await s.reviewCard(q.first, true);
      final c = await s.studyCounts();
      expect(c.newAvailable, 2);
      expect(c.newDone, 1);
      expect(c.due, 0);
      expect((await s.dueCards()).length, 2); // 旧接口 = 全部学习
    });
  });

  test('FSRS 输出不变：同样的评分序列得到同样的结果', () {
    const f = Fsrs();
    final c = Flashcard(id: 'c', projectId: 'p', front: 'Q', back: 'A', due: DateTime.utc(2026, 1, 1, 9));
    var t = DateTime.utc(2026, 1, 1, 9);
    // 由 v1.3.5 的 FSRS 代码生成（[评分, 稳定度, 难度, reps, lapses, 下次到期]）
    const expected = [
      [3, 3.173, 5.282434422319005, 1, 0, '2026-01-04T09:00:00.000Z'],
      [3, 10.73892584613159, 5.272967931287446, 2, 0, '2026-01-15T09:00:00.000Z'],
      [1, 2.185775232039225, 6.790567694566929, 3, 1, '2026-01-15T09:10:00.000Z'],
      [3, 3.077071453551091, 6.774163790483029, 4, 1, '2026-01-18T09:10:00.000Z'],
      [3, 8.672806004323053, 6.7578353443579156, 5, 1, '2026-01-27T09:10:00.000Z'],
      [1, 1.90297815321168, 7.788932435682631, 6, 2, '2026-01-27T09:20:00.000Z'],
      [1, 0.953446335676136, 8.482200381079112, 7, 3, '2026-01-27T09:30:00.000Z'],
      [3, 1.3422343061618514, 8.458014966637256, 8, 3, '2026-01-28T09:30:00.000Z'],
    ];
    for (final e in expected) {
      f.review(c, e[0] as int, now: t);
      expect(c.stability, e[1]);
      expect(c.difficulty, e[2]);
      expect(c.reps, e[3]);
      expect(c.lapses, e[4]);
      expect(c.due.toIso8601String(), e[5]);
      t = c.due;
    }
  });
}
