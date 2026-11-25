import '../models.dart';
import 'fsrs.dart';

/// FSRS 四档评分。
class Grade {
  static const again = 1, hard = 2, good = 3, easy = 4;
  static const labels = {again: '没记住', hard: '模糊', good: '记住了', easy: '很简单'};
  static String label(int g) => labels[g] ?? '';
}

/// 本轮复习里的一次评分：评分前的 FSRS 快照 + 评分 + 当时的时间 + 写入的复习记录 id。
///
/// 改评分时不「撤销再重评」，而是从快照出发，按原来的时间重新计算（重放），
/// 所以改第 3 张不会影响第 4、5 张已经评好的结果；同一张卡在本轮出现多次时，后面的评分也会依次重放。
class ReviewEntry {
  final String cardId;
  Map<String, dynamic> pre; // 评分前的卡片（只用其中的 FSRS 字段）
  int grade;
  final DateTime at;
  final String logId;
  ReviewEntry({required this.cardId, required this.pre, required this.grade, required this.at, required this.logId});

  bool get isNew => (pre['reps'] ?? 0) == 0;

  Map<String, dynamic> toJson() => {'cardId': cardId, 'card': pre, 'grade': grade, 'at': at.toIso8601String(), 'log': logId};
  factory ReviewEntry.fromJson(Map<String, dynamic> j) {
    final pre = (j['card'] as Map).cast<String, dynamic>();
    return ReviewEntry(
      cardId: j['cardId'] ?? pre['id'],
      pre: pre,
      grade: j['grade'] ?? Grade.good,
      at: DateTime.tryParse(j['at'] ?? '') ?? DateTime.now(),
      logId: j['log'] ?? '',
    );
  }
}

/// FSRS 相关字段（改评分时只动这些，卡片文字等其他编辑保持不变）。
const fsrsFields = ['stability', 'difficulty', 'reps', 'lapses', 'due', 'lastReview'];

/// 把快照里的 FSRS 状态写回卡片（不动正面 / 背面 / 暂停等其他字段）。
Flashcard withFsrsState(Flashcard c, Map<String, dynamic> snapshot) {
  final j = c.toJson();
  for (final f in fsrsFields) {
    j[f] = snapshot[f];
  }
  return Flashcard.fromJson(j);
}

/// 修改第 [i] 次评分为 [grade] 并重放同一张卡在它之后的所有评分。
/// 返回重新计算后的卡片（基于 [current] 的非 FSRS 字段）；[entries] 里后续记录的快照会被更新。
Flashcard replayFrom(List<ReviewEntry> entries, int i, int grade, Flashcard current, Fsrs fsrs) {
  final id = entries[i].cardId;
  entries[i].grade = grade;
  var c = withFsrsState(current, entries[i].pre);
  for (var k = i; k < entries.length; k++) {
    final e = entries[k];
    if (e.cardId != id) continue;
    e.pre = {...e.pre, for (final f in fsrsFields) f: c.toJson()[f]};
    fsrs.review(c, e.grade, now: e.at);
  }
  return c;
}

/// 下次复习的间隔，用在评分按钮上（如「10分钟」「3天」「2.5月」）。
String intervalLabel(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)}分钟';
  if (d.inHours < 24) return '${d.inHours}小时';
  final days = d.inHours / 24;
  if (days < 30) return '${days.round()}天';
  if (days < 365) {
    final m = days / 30;
    return '${m < 10 ? m.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '') : m.round()}月';
  }
  final y = days / 365;
  return '${y < 10 ? y.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '') : y.round()}年';
}

/// 四档评分各自的下次间隔（从 [pre] 状态在 [now] 评分）。
Map<int, String> previewIntervals(Flashcard card, Fsrs fsrs, {Map<String, dynamic>? pre, DateTime? now}) {
  final t = now ?? DateTime.now();
  return {
    for (final g in [Grade.again, Grade.hard, Grade.good, Grade.easy])
      g: intervalLabel(fsrs.review(withFsrsState(card, pre ?? card.toJson()), g, now: t).due.difference(t)),
  };
}
