import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/number_input.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('输入的数量限制在范围内，非数字忽略', () {
    expect(parseClampedInt('37', 0, maxGenCount), 37);
    expect(parseClampedInt('99999', 0, maxGenCount), 1500);
    expect(parseClampedInt(' 0 ', 0, maxGenCount), 0);
    expect(parseClampedInt('0', 1, 2500), 1);
    expect(parseClampedInt('', 0, 10), isNull);
    expect(parseClampedInt('abc', 0, 10), isNull);
  });

  test('设置：并发数 1–2500（默认 4），自动数量上限 5–3000', () async {
    SharedPreferences.setMockInitialValues({});
    final s = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    expect(s.concurrency, 4);
    s.concurrency = 0;
    expect(s.concurrency, 1);
    s.concurrency = 9999;
    expect(s.concurrency, 2500);
    s.autoCap = 1;
    expect(s.autoCap, 5);
    s.autoCap = 5000;
    expect(s.autoCap, 3000);
    expect(Settings.backupKeys, contains('concurrency'));
  });

  testWidgets('点数字弹出数字键盘输入，超出范围取上限；± 按钮也受上限约束', (t) async {
    var v = 20;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (ctx, set) => NumberStepper(label: '闪卡', value: v, onChanged: (n) => set(() => v = n))))));
    await t.tap(find.text('20'));
    await t.pumpAndSettle();
    final field = t.widget<TextField>(find.byKey(const ValueKey('number_input')));
    expect(field.keyboardType, TextInputType.number);
    await t.enterText(find.byKey(const ValueKey('number_input')), '9999');
    await t.tap(find.text('确定'));
    await t.pumpAndSettle();
    expect(v, 1500);
    await t.tap(find.byIcon(Icons.add_circle_outline));
    await t.pump();
    expect(v, 1500);
    await t.tap(find.byIcon(Icons.remove_circle_outline));
    await t.pump();
    expect(v, 1495);
    // 取消不改变
    await t.tap(find.text('1495'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('number_input')), '3');
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(v, 1495);
  });
}
