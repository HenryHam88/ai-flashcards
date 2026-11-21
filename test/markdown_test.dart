import 'package:ai_flashcards/theme/rich_text.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> pumpMd(WidgetTester t, String md) => t.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: MathText(md, style: const TextStyle(fontSize: 15))))));

String allText(WidgetTester t) =>
    t.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('\n');

void main() {
  test('块级解析：标题、列表、引用、分隔线、独立公式', () {
    final d = MdMath.parse('### 1. 通俗解释\n正文 \$x^2\$\n\n- 第一点\n  - 子项\n2. 第二步\n> 引用\n---\n\$\$\\int_0^1 x\\,dx\$\$');
    expect(d.blocks.map((b) => b.type).toList(), [
      MdBlockType.heading,
      MdBlockType.paragraph,
      MdBlockType.bullet,
      MdBlockType.bullet,
      MdBlockType.ordered,
      MdBlockType.quote,
      MdBlockType.rule,
      MdBlockType.math,
    ]);
    expect(d.blocks[0].level, 3);
    expect(d.blocks[0].text, '1. 通俗解释');
    expect(d.blocks[3].level, 1);
    expect(d.blocks[4].marker, '2.');
    expect(d.math.length, 2);
  });

  test('公式里的 * _ 不被当成 Markdown', () {
    final d = MdMath.parse(r'**重点** $a*b*c + x_1 \cdot y_2$ 结束');
    expect(d.math.single.text, r'a*b*c + x_1 \cdot y_2');
    expect(d.blocks.single.type, MdBlockType.paragraph);
  });

  test('去掉开头的元话语', () {
    expect(stripMetaPreamble('下面完整重写，公式均使用 LaTeX。\n### 1. 通俗解释\n内容'), '### 1. 通俗解释\n内容');
    expect(stripMetaPreamble('好的，以下是修正后的回答：\n条件概率是……'), '条件概率是……');
    expect(stripMetaPreamble('条件概率是在已知 B 发生时 A 的概率。'), '条件概率是在已知 B 发生时 A 的概率。');
  });

  testWidgets('### 标题不再显示井号，并加粗放大', (t) async {
    await pumpMd(t, '### 1. 通俗解释\n内容');
    final txt = allText(t);
    expect(txt.contains('#'), isFalse);
    expect(txt.contains('1. 通俗解释'), isTrue);
    final heading = t.widgetList<RichText>(find.byType(RichText)).firstWhere((r) => r.text.toPlainText().contains('通俗解释'));
    expect((heading.text as TextSpan).style!.fontWeight, FontWeight.w700);
    expect((heading.text as TextSpan).style!.fontSize, greaterThan(15));
  });

  testWidgets('粗体里含公式、列表里含公式、独立公式都用排版引擎渲染', (t) async {
    await pumpMd(t, '**定义：\$P(A\\mid B)\$**\n\n- 乘法公式 \$P(AB)=P(B)P(A\\mid B)\$\n\n\$\$P(A)=\\sum_i P(B_i)P(A\\mid B_i)\$\$');
    expect(find.byType(Math), findsNWidgets(3));
    expect(allText(t).contains('**'), isFalse);
    expect(find.text('•'), findsOneWidget);
  });

  testWidgets('未闭合的 \$ 按普通文字显示，不崩溃', (t) async {
    await pumpMd(t, '正在输出 \$P(A\\mid');
    expect(find.byType(Math), findsNothing);
    expect(allText(t).contains(r'$P(A\mid'), isTrue);
    expect(t.takeException(), isNull);
  });
}
