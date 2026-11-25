import 'package:ai_flashcards/services/latex.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/theme/rich_text.dart';
import 'package:ai_flashcards/ui/ai_widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

String richPlain(WidgetTester t) =>
    t.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('\n');

Future<void> pump(WidgetTester t, Widget child) => t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));

List<String> mockClipboard(WidgetTester t) {
  final copied = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  return copied;
}

void main() {
  test('复制公式源码：行内是 \$...\$，独立公式是 \$\$...\$\$', () {
    expect(latexCopySource(const TexSegment(r'a^2', isMath: true)), r'$a^2$');
    expect(latexCopySource(const TexSegment(r'\int x', isMath: true, display: true)), r'$$\int x$$');
    expect(latexCopySource(const TexSegment(r'\int x', isMath: true), display: true), r'$$\int x$$');
  });

  testWidgets('可选中的 MathText 在文字里带上原始 LaTeX，方便复制', (t) async {
    await pump(t, MathText(r'定义：$P(A\mid B)$', selectable: true, style: const TextStyle(fontSize: 15)));
    expect(richPlain(t), contains(r'$P(A\mid B)$'));
    await pump(t, MathText(r'$$\int_0^1 x\,dx$$', selectable: true, style: const TextStyle(fontSize: 15)));
    expect(richPlain(t), contains(r'$$\int_0^1 x\,dx$$'));
  });

  testWidgets(r'默认 MathText 不把公式源码掺进可见文字（避免闪卡等界面多出 $）', (t) async {
    await pump(t, MathText(r'定义：$P(A)$', style: const TextStyle(fontSize: 15)));
    expect(richPlain(t).contains(r'$P(A)$'), isFalse);
    expect(richPlain(t), contains('定义：'));
  });

  testWidgets('「复制」把 Markdown / LaTeX 原文放进剪贴板，并提示已复制', (t) async {
    const src = r'**重点**：条件概率 $P(A\mid B)$';
    await pump(t, ChatMessageView(text: src));
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('参考网页 · 1'), findsNothing);
    final copied = mockClipboard(t);
    await t.tap(find.text('复制'));
    await t.pump();
    expect(copied, [src]);
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('用户消息也可以复制；来源链接仍显示在回答下方', (t) async {
    await pump(
      t,
      ChatMessageView(
        text: '请解释一下',
        user: true,
      ),
    );
    expect(find.text('请解释一下'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    final copied = mockClipboard(t);
    await t.tap(find.text('复制'));
    await t.pump();
    expect(copied, ['请解释一下']);
    expect(find.text('已复制'), findsOneWidget);

    await pump(
      t,
      ChatMessageView(
        text: '这是回答',
        sources: const [WebSource(url: 'https://example.com/p', title: '例站')],
      ),
    );
    expect(find.text('参考网页 · 1'), findsOneWidget);
    expect(find.text('例站'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
  });
}
