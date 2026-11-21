import 'package:ai_flashcards/services/latex.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('拆分行内与独立公式', () {
    final s = LatexUtil.split(r'若 $y=x^2$，则 $$\frac{dy}{dx}=2x$$ 成立');
    expect(s, [
      const TexSegment('若 '),
      const TexSegment('y=x^2', isMath: true),
      const TexSegment('，则 '),
      const TexSegment(r'\frac{dy}{dx}=2x', isMath: true, display: true),
      const TexSegment(' 成立'),
    ]);
  });

  test(r'\( \) 与 \[ \] 统一为 $ 分隔', () {
    expect(LatexUtil.normalize(r'\(a+b\) 和 \[c\]'), r'$a+b$ 和 $$c$$');
  });

  test(r'转义的 \$ 当作普通字符', () {
    final s = LatexUtil.split(r'价格 \$5，公式 $a$');
    expect(s.first.text, r'价格 $5，公式 ');
    expect(s.last, const TexSegment('a', isMath: true));
  });

  test('合格文本通过校验', () {
    expect(LatexUtil.validate(r"一阶线性方程 $y'+p(x)y=q(x)$，解为 $$y=e^{-\int p\,dx}\left(\int q e^{\int p\,dx}dx+C\right)$$"), isEmpty);
  });

  test('不成对的 \$ 与无法解析的公式被拒绝', () {
    expect(LatexUtil.validate(r'设 $x^2 + 1'), isNotEmpty);
    expect(LatexUtil.validate(r'$\frac{1}{$'), isNotEmpty);
  });

  test('裸写的 x^2、\\frac 被检测出来', () {
    expect(LatexUtil.validate('求 x^2 的导数'), isNotEmpty);
    expect(LatexUtil.validate(r'结果是 \frac{1}{2}'), isNotEmpty);
    expect(LatexUtil.validate('普通中文句子，没有公式。'), isEmpty);
  });

  test('autoFix 把裸露公式包上 \$', () {
    final f = LatexUtil.autoFix(r'结果是 \frac{1}{2}，对吗');
    expect(f, r'结果是 $\frac{1}{2}$，对吗');
    expect(LatexUtil.validate(f), isEmpty);
  });
}
