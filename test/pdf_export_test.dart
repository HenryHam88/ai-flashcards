import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/pdf_export.dart';
import 'package:ai_flashcards/ui/math_raster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'screenshots_test.dart' show loadFonts;

Uint8List font() => File('assets/fonts/NotoSansSC-Regular-subset.ttf').readAsBytesSync();

/// 假的栅格化器：返回 1×1 PNG，记录渲染过的公式。
class FakeRaster implements MathRasterizer {
  final seen = <String>[];
  static final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
    0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
  ]);
  @override
  Future<RasterMath?> render(String tex, {required bool display, required double fontSize}) async {
    seen.add(tex);
    if (tex.contains('bad')) return null;
    return RasterMath(png, 40, display ? 24 : 14, display ? 16 : 10);
  }
}

String pdfText(Uint8List bytes) {
  final d = PdfDocument(inputBytes: bytes);
  final t = PdfTextExtractor(d).extractText();
  d.dispose();
  return t;
}

List<ExportItem> sample(int n) => [
      for (var i = 0; i < n; i++)
        ExportItem(
          question: Question(
            id: 'q$i',
            projectId: 'p1',
            chapter: i < n ~/ 2 ? '第一章 随机事件与概率' : '第二章 随机变量',
            type: '单选',
            stem: '第$i题：已知 \$P(A)=0.3\$，求 \$P(\\bar A)\$。',
            options: ['0.3', '0.7', r'$\frac{1}{2}$', '无法确定'],
            answer: 'B',
            explanation: '由 **对立事件** 公式\n\$\$P(\\bar A)=1-P(A)\$\$\n得 0.7。',
            page: 12,
          ),
          mark: '答错',
          lastAnswer: 'A',
        ),
      ExportItem(card: Flashcard(id: 'c1', projectId: 'p1', front: '条件概率的定义', back: r'$P(A\mid B)=\dfrac{P(AB)}{P(B)}$'), mark: '不确定'),
    ];

void main() {
  test('答案紧跟每题：题干、选项、答案、解析、上次作答都在，公式交给栅格化器', () async {
    final r = FakeRaster();
    final bytes = await PdfExportService(font(), math: r).wrongQuestions('概率论', sample(3), const PdfExportOptions(), now: DateTime(2026, 11, 24));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final t = pdfText(bytes);
    for (final s in ['概率论 · 错题集', '共 4 题', '答案紧跟每题', '2026-11-24', '第一章 随机事件与概率', '第0题', '无法确定', '答案：', '对立事件', '上次作答', '条件概率的定义', '第 1 / ']) {
      expect(t, contains(s), reason: s);
    }
    expect(t.indexOf('答案：'), lessThan(t.indexOf('第1题')), reason: '第一题的答案在第二题前面');
    expect(r.seen, containsAll(['P(A)=0.3', r'P(\bar A)=1-P(A)', r'P(A\mid B)=\dfrac{P(AB)}{P(B)}']));
  });

  test('答案放到最后：题目部分没有答案，最后一节是「答案与解析」；可以不含解析', () async {
    final bytes = await PdfExportService(font(), math: FakeRaster())
        .wrongQuestions('概率论', sample(4), const PdfExportOptions(layout: AnswerLayout.end, explanation: false, lastAnswer: false));
    final t = pdfText(bytes);
    final ans = t.indexOf('答案与解析');
    expect(ans, greaterThan(0));
    expect(t.indexOf('答案：'), greaterThan(ans));
    expect(t, isNot(contains('对立事件')));
    expect(t, isNot(contains('上次作答')));
  });

  test('很多题自动分页；公式渲染失败时按原文显示；没有栅格化器也能导出', () async {
    final items = sample(40)..add(ExportItem(question: Question(id: 'x', projectId: 'p1', type: '填空', stem: r'公式 $\bad{x}$ 渲染失败', answer: '1|一')));
    final bytes = await PdfExportService(font(), math: FakeRaster()).wrongQuestions('概率论', items, const PdfExportOptions());
    final d = PdfDocument(inputBytes: bytes);
    expect(d.pages.count, greaterThan(3));
    d.dispose();
    final t = pdfText(bytes);
    expect(t, contains(r'\bad{x}'));
    expect(t, contains('1 / 一'));
    final plain = await PdfExportService(font()).wrongQuestions('概率论', sample(2), const PdfExportOptions());
    expect(pdfText(plain), contains(r'P(A)=0.3'));
  });

  testWidgets('真实栅格化：flutter_math_fork 离屏渲染出 PNG，带基线', (t) async {
    await loadFonts();
    final r = FlutterMathRasterizer(pixelRatio: 2);
    final m = await t.runAsync(() => r.render(r'\frac{a}{b}+x^2', display: false, fontSize: 12));
    expect(m, isNotNull);
    expect(m!.width, greaterThan(10));
    expect(m.baseline, inInclusiveRange(1, m.height));
    expect(m.png.sublist(1, 4), 'PNG'.codeUnits);
    final bad = await t.runAsync(() => r.render(r'\frac{', display: true, fontSize: 12));
    expect(bad, isNull);
    // 生成一份真实 PDF 方便人工检查
    final bytes = await t.runAsync(() => PdfExportService(font(), math: r).wrongQuestions('概率论', sample(3), const PdfExportOptions()));
    Directory('build').createSync(recursive: true);
    File('build/wrong_sample.pdf').writeAsBytesSync(bytes!);
  });
}
