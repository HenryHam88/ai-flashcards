import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/fsrs.dart';
import 'package:ai_flashcards/services/review_history.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues({});
  return AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
}

Map<String, dynamic> _fsrs(Flashcard c) => {for (final f in fsrsFields) f: c.toJson()[f]};

void main() {
  test('四档评分：间隔 没记住 < 模糊 < 记住了 < 很简单，复习记录带评分', () async {
    final s = await _state();
    final t = DateTime(2026, 11, 24, 9);
    final cards = [for (var g = 1; g <= 4; g++) Flashcard(id: 'c$g', projectId: 'p', front: 'Q', back: 'A', due: t)];
    await s.repo.saveCards(cards);
    for (var g = 1; g <= 4; g++) {
      await s.rateCard(cards[g - 1], g, now: t);
    }
    final due = [for (var g = 1; g <= 4; g++) (await s.repo.card('c$g'))!.due];
    for (var i = 1; i < 4; i++) {
      expect(due[i].isAfter(due[i - 1]), isTrue);
    }
    final logs = await s.repo.logs();
    expect(logs.map((l) => l.grade).toSet(), {1, 2, 3, 4});
    expect(logs.where((l) => l.correct).length, 3); // 模糊也算记住
    expect(logs.every((l) => l.isNew), isTrue);
  });

  test('改评分 = 从评分前快照按原时间重算，结果与一开始就选对完全一致', () async {
    final s = await _state();
    final t0 = DateTime(2026, 11, 1, 8);
    // 一张已经复习过几次的卡
    final base = Flashcard(id: 'c', projectId: 'p', front: 'Q', back: 'A', due: t0);
    const Fsrs().review(base, 3, now: t0);
    const Fsrs().review(base, 3, now: t0.add(const Duration(days: 3)));
    await s.repo.saveCards([base]);

    final t = DateTime(2026, 11, 24, 9);
    final wrong = Flashcard.fromJson(base.toJson());
    final e = await s.rateCard(wrong, Grade.again, now: t); // 误触「没记住」
    expect((await s.repo.card('c'))!.lapses, 1);

    // 期望值：同一时间直接选「记住了」
    final expected = const Fsrs().review(Flashcard.fromJson(base.toJson()), Grade.good, now: t);

    // 中途用户编辑了卡片文字：改评分不能把文字改回去
    final edited = (await s.repo.card('c'))!..front = '改过的正面';
    await s.repo.saveCards([edited]);

    final fixed = await s.changeRating([e], 0, Grade.good);
    expect(_fsrs(fixed), _fsrs(expected));
    expect(_fsrs((await s.repo.card('c'))!), _fsrs(expected));
    expect((await s.repo.card('c'))!.front, '改过的正面');
    final log = (await s.repo.logs()).single;
    expect(log.correct, isTrue);
    expect(log.grade, Grade.good);
    expect(log.at, t);
  });

  test('多步改评分：改第 1 张不影响第 2、3 张；同一张卡出现两次时后面的评分依次重放', () async {
    final s = await _state();
    final t = DateTime(2026, 11, 24, 9);
    final a = Flashcard(id: 'a', projectId: 'p', front: 'Q', back: 'A', due: t);
    final b = Flashcard(id: 'b', projectId: 'p', front: 'Q', back: 'A', due: t);
    await s.repo.saveCards([a, b]);
    final h = <ReviewEntry>[];
    h.add(await s.rateCard(a, Grade.again, now: t));
    h.add(await s.rateCard(b, Grade.good, now: t.add(const Duration(minutes: 1))));
    // a 十分钟后再出现一次（重学），记住了
    final a2 = (await s.repo.card('a'))!;
    h.add(await s.rateCard(a2, Grade.good, now: t.add(const Duration(minutes: 11))));
    final bAfter = _fsrs((await s.repo.card('b'))!);

    // 把第一次的「没记住」改成「很简单」
    final fixed = await s.changeRating(h, 0, Grade.easy);
    final f = const Fsrs();
    final exp = f.review(Flashcard(id: 'a', projectId: 'p', front: 'Q', back: 'A', due: t), Grade.easy, now: t);
    final exp2Pre = _fsrs(exp);
    f.review(exp, Grade.good, now: t.add(const Duration(minutes: 11)));
    expect(_fsrs(fixed), _fsrs(exp));
    expect(fixed.lapses, 0);
    expect(fixed.reps, 2);
    expect({for (final k in fsrsFields) k: h[2].pre[k]}, exp2Pre); // 第二次出现的快照已更新
    expect(_fsrs((await s.repo.card('b'))!), bAfter); // b 不受影响
    final logs = {for (final l in await s.repo.logs()) l.id: l};
    expect(logs[h[0].logId]!.grade, Grade.easy);
    expect(logs[h[2].logId]!.grade, Grade.good);
    expect(logs.length, 3);
  });

  test('会话记录 JSON 往返；间隔文字', () {
    final e = ReviewEntry(cardId: 'c', pre: {'id': 'c', 'reps': 0}, grade: 2, at: DateTime(2026, 11, 24), logId: 'l');
    final r = ReviewEntry.fromJson(e.toJson());
    expect(r.grade, 2);
    expect(r.isNew, isTrue);
    expect(r.at, DateTime(2026, 11, 24));
    expect(intervalLabel(const Duration(minutes: 10)), '10分钟');
    expect(intervalLabel(const Duration(days: 3)), '3天');
    expect(intervalLabel(const Duration(days: 45)), '1.5月');
    expect(intervalLabel(const Duration(days: 730)), '2年');
    final c = Flashcard(id: 'c', projectId: 'p', front: 'Q', back: 'A');
    final iv = previewIntervals(c, const Fsrs(), now: DateTime(2026));
    expect(iv[Grade.again], '10分钟');
    expect(iv.length, 4);
  });
}
