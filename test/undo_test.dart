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
    final (r2, _) = await s.undoReview(undos.removeLast());
    final (r1, _) = await s.undoReview(undos.removeLast());
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

  test('重做：原样恢复评分结果和同一条记录，多步可用；新评分会替换', () async {
    SharedPreferences.setMockInitialValues({});
    final s = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    final cards = [for (var i = 0; i < 2; i++) Flashcard(id: 'c$i', projectId: 'p', front: 'Q', back: 'A', due: DateTime(2026))];
    await s.repo.saveCards(cards);
    final u0 = await s.reviewCard(cards[0], true);
    final u1 = await s.reviewCard(cards[1], false);
    final post0 = (await s.repo.card('c0'))!.toJson();
    final post1 = (await s.repo.card('c1'))!.toJson();
    final logsBefore = {for (final l in await s.repo.logs()) l.id: l.toJson()};

    final (_, redo1) = await s.undoReview(u1);
    final (_, redo0) = await s.undoReview(u0);
    expect(await s.repo.logs(), isEmpty);

    final again0 = await s.redoReview(redo0);
    final again1 = await s.redoReview(redo1);
    expect((await s.repo.card('c0'))!.toJson(), post0);
    expect((await s.repo.card('c1'))!.toJson(), post1);
    expect({for (final l in await s.repo.logs()) l.id: l.toJson()}, logsBefore); // 同 id、同时间
    expect(again0['log'], u0['log']);

    // 可以再次撤销
    final (back1, _) = await s.undoReview(again1);
    expect(back1.reps, 0);
    // 新评分替换原结果（页面层会清空重做栈）
    await s.reviewCard(back1, true);
    final c1 = (await s.repo.card('c1'))!;
    expect(c1.lapses, 0);
    expect((await s.repo.logs()).where((l) => l.id == u1['log']), isEmpty);
  });
}
