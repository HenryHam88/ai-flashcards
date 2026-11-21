import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('撤销评分：恢复 FSRS 状态与到期时间、删除复习记录，支持多步', () async {
    SharedPreferences.setMockInitialValues({});
    final s = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    final due = DateTime(2026, 1, 1);
    final cards = [for (var i = 0; i < 3; i++) Flashcard(id: 'c$i', projectId: 'p', front: 'Q$i', back: 'A', due: due)];
    await s.repo.saveCards(cards);
    final before = {for (final c in cards) c.id: c.toJson()};

    final undos = <Map<String, dynamic>>[];
    undos.add(await s.reviewCard(cards[0], true));
    undos.add(await s.reviewCard(cards[1], false));
    undos.add(await s.reviewCard(cards[2], true));
    expect((await s.repo.logs()).length, 3);
    expect((await s.repo.card('c1'))!.lapses, 1);

    // 退回两步
    final r2 = await s.undoReview(undos.removeLast());
    final r1 = await s.undoReview(undos.removeLast());
    expect(r2.toJson(), before['c2']);
    expect(r1.toJson(), before['c1']);
    expect((await s.repo.card('c1'))!.toJson(), before['c1']);
    expect((await s.repo.card('c2'))!.due, due);
    expect((await s.repo.card('c2'))!.reps, 0);
    final logs = await s.repo.logs();
    expect(logs.length, 1);
    expect(logs.single.correct, isTrue);
    // 第一张仍保持已评分状态
    expect((await s.repo.card('c0'))!.reps, 1);

    // 重新评分正常生效
    await s.reviewCard(r1, true);
    expect((await s.repo.card('c1'))!.reps, 1);
    expect((await s.repo.card('c1'))!.lapses, 0);
    expect((await s.repo.logs()).length, 2);
  });
}
