/// 新卡 / 复习分开（类似 Anki）：分类、每日新卡上限、学习队列。
/// 只决定「今天学哪些卡、按什么顺序」，不改变 FSRS 的调度计算。
library;

import '../models.dart';

/// 学习入口：全部学习（先复习到期的，再学新卡）、只学新卡、只复习。
enum StudyMode { all, newOnly, reviewOnly }

/// 卡片在本次学习中的身份。
enum CardKind { fresh, review, relearn }

StudyMode studyModeOf(String? s) => StudyMode.values.where((m) => m.name == s).firstOrNull ?? StudyMode.all;

/// 新卡：从没学过（reps == 0）。重学：上次点了「没记住」、10 分钟后再来的卡。其余为复习。
CardKind cardKind(Flashcard c) {
  if (c.reps == 0) return CardKind.fresh;
  final last = c.lastReview;
  if (c.lapses > 0 && last != null && !c.due.isAfter(last.add(const Duration(minutes: 10)))) return CardKind.relearn;
  return CardKind.review;
}

String cardKindLabel(CardKind k) => switch (k) {
  CardKind.fresh => '新',
  CardKind.review => '复习',
  CardKind.relearn => '重学',
};

/// 已学过、今天（到 [now] 为止）到期的卡（含逾期和重学）。
bool isDueReview(Flashcard c, DateTime now) => !c.suspended && c.reps > 0 && !c.due.isAfter(now);
bool isNewCard(Flashcard c) => !c.suspended && c.reps == 0;

/// 首页 / 项目页显示的数量。
class StudyCounts {
  /// 今天还能学的新卡（受每日上限限制）。
  final int newAvailable;

  /// 所有没学过的卡。
  final int newTotal;

  /// 今天要复习的卡（受每日复习上限限制）。
  final int due;

  /// 今天已经学了多少张新卡。
  final int newDone;

  /// 每日新卡上限（0 = 不限）和今天额外追加的张数。
  final int newLimit, extra;
  const StudyCounts({
    required this.newAvailable,
    required this.newTotal,
    required this.due,
    required this.newDone,
    required this.newLimit,
    required this.extra,
  });
  int get newCap => newLimit == 0 ? 0 : newLimit + extra;

  /// 新卡已达今日上限，但还有没学的新卡（可以「今天再学 10 张」）。
  bool get newLimitReached => newLimit > 0 && newDone >= newCap && newTotal > 0;

  /// 「今日新卡 12/20」。
  String get newProgress => newLimit == 0 ? '今日新卡 $newDone（不限）' : '今日新卡 $newDone/$newCap';
}

/// 计算今天的数量和队列需要的上限状态。[todayLogs]：今天（按每日开始时间）的闪卡学习记录。
({int newLeft, int revLeft}) _left(List<LogEntry> todayLogs, int newLimit, int reviewLimit, int extra) {
  const inf = 1 << 30;
  final newDone = todayLogs.where((e) => e.kind == 'card' && e.isNew).length;
  final revDone = todayLogs.where((e) => e.kind == 'card' && !e.isNew).length;
  return (
    newLeft: newLimit == 0 ? inf : (newLimit + extra - newDone).clamp(0, inf),
    revLeft: reviewLimit == 0 ? inf : (reviewLimit - revDone).clamp(0, inf),
  );
}

List<Flashcard> _sorted(Iterable<Flashcard> l) => l.toList()..sort((a, b) => a.due.compareTo(b.due));

StudyCounts computeCounts(
  List<Flashcard> cards,
  List<LogEntry> todayLogs, {
  required int newLimit,
  int reviewLimit = 0,
  int extra = 0,
  required DateTime now,
}) {
  final left = _left(todayLogs, newLimit, reviewLimit, extra);
  final newTotal = cards.where(isNewCard).length;
  final due = cards.where((c) => isDueReview(c, now)).length;
  return StudyCounts(
    newAvailable: newTotal < left.newLeft ? newTotal : left.newLeft,
    newTotal: newTotal,
    due: due < left.revLeft ? due : left.revLeft,
    newDone: todayLogs.where((e) => e.kind == 'card' && e.isNew).length,
    newLimit: newLimit,
    extra: extra,
  );
}

/// 学习队列。复习按到期时间排序（逾期最久的在前）；新卡按加入顺序（到期时间即创建时间）。
/// 「全部学习」先复习到期的卡，再学新卡——先保住已学的记忆，新卡放在后面，中途退出也不耽误复习。
List<Flashcard> buildQueue(
  List<Flashcard> cards,
  List<LogEntry> todayLogs,
  StudyMode mode, {
  required int newLimit,
  int reviewLimit = 0,
  int extra = 0,
  required DateTime now,
}) {
  final left = _left(todayLogs, newLimit, reviewLimit, extra);
  final reviews = mode == StudyMode.newOnly
      ? <Flashcard>[]
      : _sorted(cards.where((c) => isDueReview(c, now))).take(left.revLeft);
  final fresh = mode == StudyMode.reviewOnly ? <Flashcard>[] : _sorted(cards.where(isNewCard)).take(left.newLeft);
  return [...reviews, ...fresh];
}

/// 「今天」的日期键（按每日开始时间换日），用于记录当天追加的新卡数。
String dayKey(DateTime now, int startHour) {
  final t = now.toLocal().subtract(Duration(hours: startHour));
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
