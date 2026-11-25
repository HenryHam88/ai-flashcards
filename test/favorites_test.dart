import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/favorites_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState s;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    s = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    await s.repo.saveCards([
      Flashcard(id: 'c1', projectId: 'p1', front: 'A', back: 'a', kpId: 'k1'),
      Flashcard(id: 'c2', projectId: 'p1', front: 'B', back: 'b', kpId: 'k1'),
      Flashcard(id: 'c3', projectId: 'p2', front: 'C', back: 'c'),
    ]);
    await s.repo.saveKps([KnowledgePoint(id: 'k1', projectId: 'p1', title: '条件概率')]);
  });

  test('切换收藏：同一目标只有一条，按项目筛选', () async {
    final f = FavoriteItem(projectId: 'p1', kind: 'card', targetId: 'c1', title: 'A');
    expect(await s.repo.toggleFavorite(f), isTrue);
    expect(await s.repo.isFavorite('card', 'c1'), isTrue);
    await s.repo.saveFavorite(f);
    expect((await s.repo.favorites()).length, 1);
    await s.repo.toggleFavorite(FavoriteItem(projectId: 'p2', kind: 'card', targetId: 'c3', title: 'C'));
    expect((await s.repo.favorites(projectId: 'p1')).map((e) => e.targetId), ['c1']);
    expect(await s.repo.toggleFavorite(f), isFalse);
    expect(await s.repo.isFavorite('card', 'c1'), isFalse);
  });

  test('收藏夹：知识点统计关联闪卡，原内容删除后标记为已删除', () async {
    await s.repo.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'kp', targetId: 'k1', title: '条件概率'));
    await s.repo.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'card', targetId: 'c2', title: 'B'));
    await s.repo.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'question', targetId: 'gone', title: '旧题'));
    final l = await loadFavorites(s, projectId: 'p1');
    final kp = l.firstWhere((e) => e.fav.kind == 'kp');
    expect(kp.kp!.title, '条件概率');
    expect(kp.relatedCards, 2);
    expect(l.firstWhere((e) => e.fav.kind == 'card').card!.front, 'B');
    expect(l.firstWhere((e) => e.fav.kind == 'question').gone, isTrue);
  });
}
