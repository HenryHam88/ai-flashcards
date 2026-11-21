import 'dart:math';

import '../models.dart';

/// FSRS-5 间隔重复算法（与 Anki 现用算法同源），默认参数。
/// 评分：1=Again(没记住) 2=Hard 3=Good(记住了) 4=Easy
class Fsrs {
  static const List<double> w = [
    0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192, //
    1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621
  ];
  static const double decay = -0.5;
  static const double factor = 19 / 81;
  final double requestRetention;
  final int maxInterval;
  const Fsrs({this.requestRetention = 0.9, this.maxInterval = 36500});

  static double retrievability(double elapsedDays, double stability) =>
      pow(1 + factor * elapsedDays / stability, decay).toDouble();

  double nextIntervalDays(double s) {
    final i = s / factor * (pow(requestRetention, 1 / decay) - 1);
    return i.clamp(1, maxInterval.toDouble()).roundToDouble();
  }

  static double initStability(int g) => max(w[g - 1], 0.1);
  static double initDifficulty(int g) => (w[4] - exp(w[5] * (g - 1)) + 1).clamp(1, 10).toDouble();

  static double nextDifficulty(double d, int g) {
    final delta = -w[6] * (g - 3);
    final dp = d + delta * (10 - d) / 9; // 线性衰减
    final target = initDifficulty(4);
    return (w[7] * target + (1 - w[7]) * dp).clamp(1, 10).toDouble();
  }

  static double recallStability(double d, double s, double r, int g) {
    final hard = g == 2 ? w[15] : 1.0;
    final easy = g == 4 ? w[16] : 1.0;
    return s * (exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hard * easy + 1);
  }

  static double forgetStability(double d, double s, double r) {
    final sf = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - r));
    return min(sf, s);
  }

  static double shortTermStability(double s, int g) => s * exp(w[17] * (g - 3 + w[18]));

  /// 根据评分更新卡片，返回同一对象。
  Flashcard review(Flashcard c, int grade, {DateTime? now}) {
    final t = now ?? DateTime.now();
    if (c.reps == 0 || c.stability <= 0) {
      c.stability = initStability(grade);
      c.difficulty = initDifficulty(grade);
    } else {
      final elapsed = c.lastReview == null ? 0.0 : t.difference(c.lastReview!).inMinutes / 1440.0;
      if (elapsed < 1) {
        c.stability = shortTermStability(c.stability, grade);
      } else {
        final r = retrievability(elapsed, c.stability);
        c.stability = grade == 1
            ? forgetStability(c.difficulty, c.stability, r)
            : recallStability(c.difficulty, c.stability, r, grade);
      }
      c.difficulty = nextDifficulty(c.difficulty, grade);
    }
    c.reps += 1;
    if (grade == 1) {
      c.lapses += 1;
      c.due = t.add(const Duration(minutes: 10)); // 没记住：10 分钟后再来
    } else {
      c.due = t.add(Duration(days: nextIntervalDays(c.stability).toInt()));
    }
    c.lastReview = t;
    return c;
  }
}
