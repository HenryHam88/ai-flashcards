import 'dart:math';

import '../models.dart';
import 'fsrs.dart';

// ============================================================================
// 学习数据统计：全部是纯函数，方便测试。
// ============================================================================

DateTime _day(DateTime t, int startHour) {
  final shifted = t.subtract(Duration(hours: startHour));
  return DateTime(shifted.year, shifted.month, shifted.day);
}

/// 卡片当前的可回忆概率 R（0–1）。没学过的卡为 0。
double cardRetrievability(Flashcard c, DateTime now) {
  if (c.reps == 0 || c.stability <= 0 || c.lastReview == null) return 0;
  final days = max(0, now.difference(c.lastReview!).inMinutes) / 1440.0;
  return Fsrs.retrievability(days, c.stability);
}

class DailyOverview {
  final int reviews; // 今日闪卡复习次数
  final int answers; // 今日答题数
  final int newCards; // 今日新学
  final int reviewCards; // 今日复习（非新卡）
  final double? accuracy; // 今日正确率（闪卡 + 测验），无记录为 null
  final int seconds; // 今日学习时长
  final int streak; // 连续学习天数
  final Map<DateTime, int> heatmap; // 日期 → 当天操作次数
  DailyOverview(this.reviews, this.answers, this.newCards, this.reviewCards, this.accuracy, this.seconds, this.streak,
      this.heatmap);
}

/// 每日概览 + 打卡 + 热力图（最近 [days] 天）。
DailyOverview dailyOverview(List<LogEntry> logs, List<StudySession> sessions,
    {required DateTime now, int startHour = 0, int days = 182}) {
  final today = _day(now, startHour);
  final heat = <DateTime, int>{};
  for (final l in logs) {
    final d = _day(l.at, startHour);
    if (today.difference(d).inDays < days) heat[d] = (heat[d] ?? 0) + 1;
  }
  final todays = logs.where((l) => _day(l.at, startHour) == today).toList();
  final cardsToday = todays.where((l) => l.kind == 'card').toList();
  final secs = sessions.where((x) => _day(x.start, startHour) == today).fold<int>(0, (a, b) => a + b.seconds);
  // 连续天数：今天还没学时，从昨天往前算（不打断连胜）
  var streak = 0;
  var d = heat.containsKey(today) ? today : today.subtract(const Duration(days: 1));
  while ((heat[d] ?? 0) > 0) {
    streak++;
    d = DateTime(d.year, d.month, d.day - 1);
  }
  return DailyOverview(
    cardsToday.length,
    todays.where((l) => l.kind == 'quiz').length,
    cardsToday.where((l) => l.isNew).length,
    cardsToday.where((l) => !l.isNew).length,
    todays.isEmpty ? null : todays.where((l) => l.correct).length / todays.length,
    secs,
    streak,
    heat,
  );
}

class Mastery {
  final String projectId;
  final String chapter; // 空 = 整个项目
  final int total; // 卡片数（不含暂停）
  final int learned; // 学过的
  final double mastery; // 平均可回忆概率（新卡按 0 计），0–1
  final double avgStability; // 学过的卡平均稳定性（天）
  final int lapses;
  Mastery(this.projectId, this.chapter, this.total, this.learned, this.mastery, this.avgStability, this.lapses);
}

Mastery _mastery(String pid, String ch, List<Flashcard> cs, DateTime now) {
  final learned = cs.where((c) => c.reps > 0).toList();
  final r = cs.isEmpty ? 0.0 : cs.map((c) => cardRetrievability(c, now)).fold<double>(0, (a, b) => a + b) / cs.length;
  final st = learned.isEmpty ? 0.0 : learned.map((c) => c.stability).reduce((a, b) => a + b) / learned.length;
  return Mastery(pid, ch, cs.length, learned.length, r, st, cs.fold<int>(0, (a, b) => a + b.lapses));
}

/// 掌握度：每个项目一条（chapter 为空），以及每个章节一条。
(List<Mastery> projects, List<Mastery> chapters) masteryOf(List<Flashcard> cards, DateTime now) {
  final active = cards.where((c) => !c.suspended);
  final byP = <String, List<Flashcard>>{}, byC = <(String, String), List<Flashcard>>{};
  for (final c in active) {
    byP.putIfAbsent(c.projectId, () => []).add(c);
    byC.putIfAbsent((c.projectId, c.chapter.isEmpty ? '未分章' : c.chapter), () => []).add(c);
  }
  return (
    [for (final e in byP.entries) _mastery(e.key, '', e.value, now)],
    [for (final e in byC.entries) _mastery(e.key.$1, e.key.$2, e.value, now)],
  );
}

class Forecast {
  final int overdue; // 已经过期（早于今天）还没复习
  final List<int> perDay; // 从今天起每天到期多少张（今天含今天到期的）
  Forecast(this.overdue, this.perDay);
}

/// 遗忘预测：未来 [days] 天每天到期的卡片数。
Forecast forecast(List<Flashcard> cards, DateTime now, {int days = 30, int startHour = 0}) {
  final today = _day(now, startHour);
  final per = List.filled(days, 0);
  var overdue = 0;
  for (final c in cards.where((c) => !c.suspended && c.reps > 0)) {
    final d = _day(c.due, startHour).difference(today).inDays;
    if (d < 0) {
      overdue++;
    } else if (d < days) {
      per[d]++;
    }
  }
  return Forecast(overdue, per);
}

class WeakSpot {
  final String projectId;
  final String chapter;
  final double score; // 越高越弱
  final double mastery;
  final int lapses;
  final int wrong;
  final List<String> cardIds;
  final List<String> reasons;
  WeakSpot(this.projectId, this.chapter, this.score, this.mastery, this.lapses, this.wrong, this.cardIds, this.reasons);
}

/// 薄弱点：综合 低可回忆概率、遗忘次数、错题数，按章节排序。只看学过的内容，至少 [minCards] 张卡或有错题。
List<WeakSpot> weakSpots(List<Flashcard> cards, List<Question> questions, List<WrongEntry> wrong, DateTime now,
    {int top = 3, int minCards = 2}) {
  final chOfQ = {for (final q in questions) q.id: (q.projectId, q.chapter.isEmpty ? '未分章' : q.chapter)};
  final chOfC = {for (final c in cards) c.id: (c.projectId, c.chapter.isEmpty ? '未分章' : c.chapter)};
  final wrongBy = <(String, String), int>{};
  for (final w in wrong.where((w) => w.mark != 'AI出错了')) {
    final k = w.questionId.isNotEmpty ? chOfQ[w.questionId] : chOfC[w.cardId];
    if (k != null) wrongBy[k] = (wrongBy[k] ?? 0) + 1;
  }
  final by = <(String, String), List<Flashcard>>{};
  for (final c in cards.where((c) => !c.suspended && c.reps > 0)) {
    by.putIfAbsent((c.projectId, c.chapter.isEmpty ? '未分章' : c.chapter), () => []).add(c);
  }
  final keys = {...by.keys, ...wrongBy.keys};
  final out = <WeakSpot>[];
  for (final k in keys) {
    final cs = by[k] ?? const <Flashcard>[];
    final w = wrongBy[k] ?? 0;
    if (cs.length < minCards && w == 0) continue;
    final r = cs.isEmpty ? 1.0 : cs.map((c) => cardRetrievability(c, now)).reduce((a, b) => a + b) / cs.length;
    final lapses = cs.fold<int>(0, (a, b) => a + b.lapses);
    final lapseRate = cs.isEmpty ? 0.0 : min(1.0, lapses / cs.length);
    final score = 0.5 * (1 - r) + 0.3 * lapseRate + 0.2 * min(1.0, w / 5);
    if (score < 0.12) continue; // 都掌握得不错就不推荐
    out.add(WeakSpot(k.$1, k.$2, score, r, lapses, w, [for (final c in cs) c.id], [
      if (cs.isNotEmpty && r < 0.85) '记忆率 ${(r * 100).round()}%',
      if (lapses > 0) '遗忘 $lapses 次',
      if (w > 0) '错题 $w 道',
    ]));
  }
  out.sort((a, b) => b.score.compareTo(a.score));
  return out.take(top).toList();
}

String fmtDuration(int secs) {
  if (secs < 60) return secs == 0 ? '0 分钟' : '$secs 秒';
  final m = secs ~/ 60;
  if (m < 60) return '$m 分钟';
  return '${m ~/ 60} 小时 ${m % 60} 分';
}
