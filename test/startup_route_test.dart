import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/review_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';

void main() {
  late AppState state;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    await seedSampleData(state.repo);
    state.settings.reviewSession = {
      'projectId': 'p1',
      'ids': [for (var i = 0; i < 20; i++) 'c$i'],
      'index': 0,
      'flipped': false,
    };
  });

  testWidgets('有未完成的复习时打开应用停在首页，点「继续」才进入闪卡', (t) async {
    await t.pumpWidget(StudyApp(state: state, home: const HomeShell()));
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('今日复习'), findsOneWidget);
    expect(find.text('继续 1/20'), findsOneWidget);
    expect(find.byType(ReviewPage), findsNothing, reason: '不应自动跳进闪卡页');

    await t.tap(find.text('继续 1/20'));
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ReviewPage), findsOneWidget);
    expect(find.text('1 / 20'), findsOneWidget);
  });
}
