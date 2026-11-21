import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/fsrs.dart';
import 'package:flutter_test/flutter_test.dart';

Flashcard _card() => Flashcard(id: 'c', projectId: 'p', front: 'Q', back: 'A');

void main() {
  const f = Fsrs();
  final t0 = DateTime(2026, 1, 1, 9);

  test('首次评分使用初始稳定度和难度', () {
    final c = f.review(_card(), 3, now: t0);
    expect(c.stability, closeTo(Fsrs.w[2], 1e-9));
    expect(c.difficulty, closeTo(Fsrs.initDifficulty(3), 1e-9));
    expect(c.reps, 1);
    expect(c.due.difference(t0).inDays, 3); // S≈3.17 → 3 天
  });

  test('没记住：10 分钟后重来，lapses+1', () {
    final c = f.review(_card(), 1, now: t0);
    expect(c.due, t0.add(const Duration(minutes: 10)));
    expect(c.lapses, 1);
  });

  test('按时复习记住了，间隔变长；忘记则稳定度下降', () {
    final c = f.review(_card(), 3, now: t0);
    final s1 = c.stability;
    final t1 = c.due;
    f.review(c, 3, now: t1);
    expect(c.stability, greaterThan(s1));
    final i2 = c.due.difference(t1).inDays;
    expect(i2, greaterThan(3));
    final s2 = c.stability;
    f.review(c, 1, now: c.due);
    expect(c.stability, lessThan(s2));
    expect(c.difficulty, greaterThan(Fsrs.initDifficulty(3)));
  });

  test('可提取率公式：t=S 时约为 90%', () {
    expect(Fsrs.retrievability(10, 10), closeTo(0.9, 1e-6));
  });

  test('难度限制在 1–10', () {
    var d = 9.9;
    for (var i = 0; i < 20; i++) {
      d = Fsrs.nextDifficulty(d, 1);
    }
    expect(d, lessThanOrEqualTo(10));
    expect(Fsrs.initDifficulty(4), greaterThanOrEqualTo(1));
  });
}
