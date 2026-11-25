import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models.dart';
import '../theme/latex_text.dart' show Mk;
import '../theme/rich_text.dart' show MdMath, MdBlockType;

/// 公式栅格化的结果：PNG + 尺寸（单位：PDF 点，1 点 ≈ 屏幕上 1 逻辑像素）+ 基线位置（距顶部）。
class RasterMath {
  final Uint8List png;
  final double width;
  final double height;
  final double baseline;
  const RasterMath(this.png, this.width, this.height, this.baseline);
}

/// 把 LaTeX 渲染成图片（应用里用 flutter_math_fork 离屏绘制，和屏幕上的公式完全一样）。
/// 渲染失败返回 null，导出时按原文显示。
abstract class MathRasterizer {
  Future<RasterMath?> render(String tex, {required bool display, required double fontSize});
}

/// 导出版式：答案紧跟每道题，或全部放到最后。
enum AnswerLayout { inline, end }

class PdfColors {
  static final text = PdfColor(0x3E, 0x3C, 0x39);
  static final sub = PdfColor(0x7D, 0x79, 0x73);
  static final sage = PdfColor(0x8F, 0xA6, 0x8B);
  static final sageDark = PdfColor(0x66, 0x80, 0x5F);
  static final rose = PdfColor(0xA8, 0x6F, 0x6F);
  static final line = PdfColor(0xD5, 0xD3, 0xCF);
  static final quoteBg = PdfColor(0xF4, 0xF1, 0xEC);
}

/// 行内的一段：文字或公式图片。
class PdfRun {
  final String text;
  final RasterMath? img;
  final bool bold;
  final bool mono; // 代码 / 公式渲染失败时的原文
  final PdfColor color;
  final double size;
  PdfRun.text(this.text, {required this.size, required this.color, this.bold = false, this.mono = false}) : img = null;
  PdfRun.image(RasterMath this.img, {required this.size, required this.color})
      : text = '',
        bold = false,
        mono = false;
}

class _Item {
  final PdfRun run;
  final double x;
  final double w;
  _Item(this.run, this.x, this.w);
}

/// 简单的流式排版器：A4 纵向，中文按字断行、英文按词断行，行内公式按基线对齐，自动分页，最后加页脚页码。
class PdfFlow {
  static const pageW = 595.0, pageH = 842.0, margin = 50.0, footer = 28.0;
  // Noto Sans SC：syncfusion 把基线放在框顶下方 1.16 倍字号处（hhea ascender）；排行时用字形实际高度（约 0.9 / 0.25）
  static const drawAscent = 1.16, ascentRatio = 0.9, descentRatio = 0.25;

  final Uint8List fontBytes;
  final MathRasterizer? math;
  final String footerTitle;
  final PdfDocument doc = PdfDocument();
  final _fonts = <double, PdfTrueTypeFont>{};
  final _widths = <String, double>{};
  late PdfPage page;
  double y = margin;
  int formulas = 0, formulaFailures = 0;

  PdfFlow(this.fontBytes, {this.math, this.footerTitle = ''}) {
    doc.pageSettings
      ..size = PdfPageSize.a4
      ..margins.all = 0;
    page = doc.pages.add();
  }

  double get contentW => pageW - margin * 2;
  double get bottom => pageH - margin - footer;

  PdfTrueTypeFont font(double size) => _fonts.putIfAbsent(size, () => PdfTrueTypeFont(fontBytes, size));

  double measure(String s, double size) {
    if (s.isEmpty) return 0;
    if (s.length == 1) return _widths.putIfAbsent('$size|$s', () => font(size).measureString(s).width);
    var w = 0.0;
    for (final r in s.runes) {
      w += measure(String.fromCharCode(r), size);
    }
    return w;
  }

  void newPage() {
    page = doc.pages.add();
    y = margin;
  }

  void ensure(double h) {
    if (y + h > bottom && y > margin + 1) newPage();
  }

  void gap(double h) {
    y += h;
    if (y > bottom) newPage();
  }

  void divider({double before = 6, double after = 10}) {
    gap(before);
    page.graphics.drawLine(PdfPen(PdfColors.line, width: 0.6), Offset(margin, y), Offset(pageW - margin, y));
    gap(after);
  }

  void pageBreak() {
    if (y > margin + 1) newPage();
  }

  /// 画一行（已经排好的若干项）。
  void _drawLine(List<_Item> items, double size, double lineGap, {double indent = 0, PdfColor? bar}) {
    var asc = size * ascentRatio * 1.0, desc = size * descentRatio;
    for (final it in items) {
      final m = it.run.img;
      if (m != null) {
        if (m.baseline > asc) asc = m.baseline;
        if (m.height - m.baseline > desc) desc = m.height - m.baseline;
      }
    }
    ensure(asc + desc);
    final base = y + asc;
    final g = page.graphics;
    if (bar != null) {
      g.drawRectangle(brush: PdfSolidBrush(bar), bounds: Rect.fromLTWH(margin + indent - 9, y - lineGap / 2, 2.5, asc + desc + lineGap));
    }
    for (final it in items) {
      final r = it.run;
      final x = margin + indent + it.x;
      if (r.img != null) {
        g.drawImage(PdfBitmap(r.img!.png), Rect.fromLTWH(x, base - r.img!.baseline, r.img!.width, r.img!.height));
      } else if (r.text.trim().isNotEmpty) {
        final f = font(r.size);
        g.drawString(r.text, f,
            brush: PdfSolidBrush(r.color),
            pen: r.bold ? PdfPen(r.color, width: r.size * 0.035) : null,
            bounds: Rect.fromLTWH(x, base - r.size * drawAscent, 0, 0));
      }
    }
    y = base + desc + lineGap;
  }

  static final _token = RegExp(r"[A-Za-z0-9_.,;:!?'%+\-=/<>()\[\]{}@#&*^~|\\$]+ ?| +|\n|.", unicode: true);
  static const _noLineStart = '，。、；：？！）》」』】,.;:?!)]}%';

  /// 排一段行内内容（自动换行）。
  void runs(List<PdfRun> rs, {double size = 11, double indent = 0, double lineGap = 5, String prefix = '', PdfColor? bar}) {
    final maxW = contentW - indent;
    var line = <_Item>[];
    var x = 0.0;
    var pre = 0.0;
    if (prefix.isNotEmpty) {
      pre = measure(prefix, size) + 4;
      line.add(_Item(PdfRun.text(prefix, size: size, color: PdfColors.sub), -pre, pre));
    }
    void flush() {
      _drawLine(line, size, lineGap, indent: indent + pre, bar: bar);
      line = [];
      x = 0;
    }

    for (final r in rs) {
      if (r.img != null) {
        var m = r.img!;
        if (m.width > maxW - pre) {
          final k = (maxW - pre) / m.width;
          m = RasterMath(m.png, m.width * k, m.height * k, m.baseline * k);
        }
        if (x + m.width > maxW - pre && line.isNotEmpty) flush();
        line.add(_Item(PdfRun.image(m, size: r.size, color: r.color), x + 1.5, m.width));
        x += m.width + 3;
        continue;
      }
      for (final t in _token.allMatches(r.text).map((e) => e[0]!)) {
        if (t == '\n') {
          flush();
          continue;
        }
        final w = measure(t, r.size);
        if (x + w > maxW - pre && line.isNotEmpty && !(t.length == 1 && _noLineStart.contains(t))) {
          if (t.trim().isEmpty) {
            flush();
            continue;
          }
          flush();
        }
        if (w > maxW - pre && t.length > 1) {
          // 超长的英文串：按字符断开
          for (final c in t.split('')) {
            final cw = measure(c, r.size);
            if (x + cw > maxW - pre && line.isNotEmpty) flush();
            _append(line, r, c, x, cw);
            x += cw;
          }
          continue;
        }
        _append(line, r, t, x, w);
        x += w;
      }
    }
    if (line.isNotEmpty || rs.isEmpty) flush();
  }

  /// 相邻同样式的文字合并成一次 drawString，PDF 更小、文字可以整段选中。
  void _append(List<_Item> line, PdfRun r, String t, double x, double w) {
    if (line.isNotEmpty) {
      final last = line.last;
      final lr = last.run;
      if (lr.img == null && lr.bold == r.bold && lr.size == r.size && lr.color == r.color && lr.mono == r.mono && (last.x + last.w - x).abs() < 0.01) {
        line[line.length - 1] = _Item(PdfRun.text(lr.text + t, size: r.size, color: r.color, bold: r.bold, mono: r.mono), last.x, last.w + w);
        return;
      }
    }
    line.add(_Item(PdfRun.text(t, size: r.size, color: r.color, bold: r.bold, mono: r.mono), x, w));
  }

  /// 纯文字（不解析 Markdown 和公式）。
  void text(String s, {double size = 11, PdfColor? color, bool bold = false, double indent = 0, double lineGap = 5}) =>
      runs([PdfRun.text(s, size: size, color: color ?? PdfColors.text, bold: bold)], size: size, indent: indent, lineGap: lineGap);

  Future<RasterMath?> _tex(String tex, bool display, double size) async {
    if (math == null) return null;
    formulas++;
    try {
      final r = await math!.render(tex, display: display, fontSize: size * (display ? 1.1 : 1.05));
      if (r == null) formulaFailures++;
      return r;
    } catch (_) {
      formulaFailures++;
      return null;
    }
  }

  /// 行内 Markdown：**粗体**、*斜体*、`代码`、公式占位符。
  Future<List<PdfRun>> _inline(String s, List<dynamic> mathSegs, {required double size, required PdfColor color, bool bold = false}) async {
    final out = <PdfRun>[];
    var last = 0;
    for (final m in MdMath.inlineRe.allMatches(s)) {
      if (m.start > last) out.add(PdfRun.text(_clean(s.substring(last, m.start)), size: size, color: color, bold: bold));
      final idx = m[5];
      if (idx != null) {
        final seg = mathSegs[int.parse(idx)];
        final img = await _tex(seg.text as String, false, size);
        out.add(img != null ? PdfRun.image(img, size: size, color: color) : PdfRun.text('\$${seg.text}\$', size: size, color: color, mono: true));
      } else if (m[1] != null || m[2] != null || m[6] != null) {
        out.addAll(await _inline(m[1] ?? m[2] ?? m[6]!, mathSegs, size: size, color: color, bold: true));
      } else if (m[3] != null || m[7] != null || m[8] != null) {
        out.addAll(await _inline(m[3] ?? m[7] ?? m[8]!, mathSegs, size: size, color: color, bold: bold));
      } else {
        out.add(PdfRun.text(m[4] ?? m[9] ?? '', size: size, color: PdfColors.sub, mono: true));
      }
      last = m.end;
    }
    if (last < s.length) out.add(PdfRun.text(_clean(s.substring(last)), size: size, color: color, bold: bold));
    return out;
  }

  static String _clean(String s) => Mk.restore(s);

  /// Markdown + LaTeX 混排内容（和应用里 MathText 用同一个解析器）。
  Future<void> rich(String md, {double size = 11, PdfColor? color, double indent = 0, String prefix = '', bool bold = false, double lineGap = 5}) async {
    final c = color ?? PdfColors.text;
    final d = MdMath.parse(md);
    var first = true;
    for (final b in d.blocks) {
      final p = first ? prefix : '';
      final pIndent = first || prefix.isEmpty ? indent : indent + measure(prefix, size) + 4;
      first = false;
      switch (b.type) {
        case MdBlockType.math:
          final seg = d.math[int.parse(b.text)];
          final img = await _tex(seg.text, true, size);
          if (img == null) {
            runs([PdfRun.text(seg.text, size: size, color: c, mono: true)], size: size, indent: pIndent, prefix: p, lineGap: lineGap);
          } else {
            var m = img;
            final maxW = contentW - pIndent;
            if (m.width > maxW) {
              final k = maxW / m.width;
              m = RasterMath(m.png, m.width * k, m.height * k, m.baseline * k);
            }
            ensure(m.height + 6);
            if (p.isNotEmpty) text(p, size: size, color: PdfColors.sub, indent: pIndent);
            page.graphics.drawImage(PdfBitmap(m.png), Rect.fromLTWH(margin + pIndent + (maxW - m.width) / 2, y + 3, m.width, m.height));
            y += m.height + 6 + lineGap;
          }
        case MdBlockType.heading:
          gap(3);
          runs(await _inline(b.text, d.math, size: size + (b.level <= 2 ? 3 : 1), color: c, bold: true),
              size: size + (b.level <= 2 ? 3 : 1), indent: pIndent, prefix: p, lineGap: lineGap);
        case MdBlockType.bullet:
          runs(await _inline(b.text, d.math, size: size, color: c, bold: bold), size: size, indent: pIndent + 12 + b.level * 12, prefix: '•', lineGap: lineGap);
        case MdBlockType.ordered:
          runs(await _inline(b.text, d.math, size: size, color: c, bold: bold),
              size: size, indent: pIndent + 12 + b.level * 12, prefix: b.marker, lineGap: lineGap);
        case MdBlockType.quote:
          runs(await _inline(b.text, d.math, size: size, color: PdfColors.sub), size: size, indent: pIndent + 12, lineGap: lineGap, bar: PdfColors.sage);
        case MdBlockType.rule:
          divider(before: 2, after: 6);
        case MdBlockType.table:
          final t = d.tables[int.parse(b.text)];
          for (final row in t.rows) {
            final cells = row.map((x) => x.text).join('  |  ');
            runs(await _inline(cells, d.math, size: size - 1, color: c, bold: row.isNotEmpty && row.first.header),
                size: size - 1, indent: pIndent, prefix: p, lineGap: 3);
          }
        case MdBlockType.code:
          final code = d.codeBlocks[int.parse(b.text)];
          runs([PdfRun.text(code, size: size - 1, color: PdfColors.sub, mono: true)], size: size - 1, indent: pIndent + 8, lineGap: 3);
        case MdBlockType.paragraph:
          runs(await _inline(b.text, d.math, size: size, color: c, bold: bold), size: size, indent: pIndent, prefix: p, lineGap: lineGap);
      }
    }
    if (d.blocks.isEmpty && prefix.isNotEmpty) text(prefix, size: size, color: PdfColors.sub, indent: indent);
  }

  /// 图片（照片），按宽度缩放，太高时限制高度。
  void image(Uint8List bytes, {double? maxWidth, double maxHeight = 360, double indent = 0}) {
    final bmp = PdfBitmap(bytes);
    final mw = maxWidth ?? contentW - indent;
    var w = bmp.width.toDouble(), h = bmp.height.toDouble();
    final k = [mw / w, maxHeight / h, 1.0].reduce((a, b) => a < b ? a : b);
    w *= k;
    h *= k;
    ensure(h + 6);
    page.graphics.drawImage(bmp, Rect.fromLTWH(margin + indent, y + 2, w, h));
    y += h + 8;
  }

  /// 一行小标签（如「单选 · 第一章 · 第 12 页」）。
  void meta(String s) => text(s, size: 9, color: PdfColors.sub, lineGap: 3);

  /// 文档大标题 + 副标题。
  void title(String t, String sub) {
    text(t, size: 20, color: PdfColors.text, bold: true, lineGap: 6);
    text(sub, size: 10, color: PdfColors.sub, lineGap: 4);
    divider(before: 4, after: 14);
  }

  void section(String t) {
    ensure(40);
    gap(6);
    text(t, size: 14, color: PdfColors.sageDark, bold: true, lineGap: 4);
    page.graphics.drawLine(PdfPen(PdfColors.sage, width: 1), Offset(margin, y), Offset(margin + 28, y));
    gap(10);
  }

  /// 页脚：标题 + 页码，然后输出 PDF。
  Future<Uint8List> finish() async {
    final n = doc.pages.count;
    final f = font(8);
    for (var i = 0; i < n; i++) {
      final g = doc.pages[i].graphics;
      final yy = pageH - margin + 4;
      if (footerTitle.isNotEmpty) g.drawString(footerTitle, f, brush: PdfSolidBrush(PdfColors.sub), bounds: Rect.fromLTWH(margin, yy, 0, 0));
      final label = '第 ${i + 1} / $n 页';
      g.drawString(label, f, brush: PdfSolidBrush(PdfColors.sub), bounds: Rect.fromLTWH(pageW - margin - measure(label, 8), yy, 0, 0));
    }
    final bytes = Uint8List.fromList(await doc.save());
    doc.dispose();
    return bytes;
  }
}

/// 错题导出里的一项：题目或闪卡（闪卡也可能进错题本）。
class ExportItem {
  final Question? question;
  final Flashcard? card;
  final String mark; // 答错 / 不确定 / AI出错了
  final String lastAnswer;
  const ExportItem({this.question, this.card, this.mark = '', this.lastAnswer = ''});
}

class PdfExportOptions {
  final AnswerLayout layout;
  final bool explanation;
  final bool lastAnswer;
  const PdfExportOptions({this.layout = AnswerLayout.inline, this.explanation = true, this.lastAnswer = true});
}

class PdfExportService {
  final Uint8List fontBytes;
  final MathRasterizer? math;
  PdfExportService(this.fontBytes, {this.math});

  static String dateLabel(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _answerText(Question q) {
    if (q.type == '填空') return q.answer.split('|').join(' / ');
    return q.answer;
  }

  /// 错题集 PDF。
  Future<Uint8List> wrongQuestions(String title, List<ExportItem> items, PdfExportOptions o, {DateTime? now}) async {
    final f = PdfFlow(fontBytes, math: math, footerTitle: '$title · 错题集');
    f.title('$title · 错题集', '共 ${items.length} 题 · ${o.layout == AnswerLayout.inline ? '答案紧跟每题' : '答案在最后'} · 导出于 ${dateLabel(now ?? DateTime.now())}');
    var lastChapter = '';
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final chapter = it.question?.chapter ?? it.card?.chapter ?? '';
      if (chapter.isNotEmpty && chapter != lastChapter) {
        f.section(chapter);
        lastChapter = chapter;
      }
      f.ensure(60);
      await _question(f, i + 1, it, o);
      if (o.layout == AnswerLayout.inline) await _answer(f, it, o, indent: 18);
      f.gap(10);
    }
    if (o.layout == AnswerLayout.end && items.isNotEmpty) {
      f.pageBreak();
      f.section('答案与解析');
      for (var i = 0; i < items.length; i++) {
        f.ensure(30);
        await _answer(f, items[i], o, number: i + 1);
        f.gap(8);
      }
    }
    return f.finish();
  }

  Future<void> _question(PdfFlow f, int n, ExportItem it, PdfExportOptions o) async {
    final q = it.question, c = it.card;
    final page = q?.page ?? c?.page ?? 0;
    f.meta([
      q != null ? '${q.type}题' : '闪卡',
      if (it.mark.isNotEmpty) it.mark,
      if (page > 0) '第 $page 页',
    ].join(' · '));
    await f.rich(q?.stem ?? c!.front, size: 11.5, prefix: '$n.', bold: false);
    if (q != null) {
      for (var i = 0; i < q.options.length; i++) {
        await f.rich(q.options[i], size: 11, indent: 18, prefix: '${String.fromCharCode(65 + i)}.');
      }
    }
    if (o.lastAnswer && it.lastAnswer.isNotEmpty) {
      await f.rich('上次作答：${it.lastAnswer}', size: 10, color: PdfColors.rose, indent: 18);
    }
  }

  Future<void> _answer(PdfFlow f, ExportItem it, PdfExportOptions o, {double indent = 0, int? number}) async {
    final q = it.question, c = it.card;
    final ans = q != null ? _answerText(q) : c!.back;
    await f.rich('**答案：**${q != null ? ans : ''}', size: 11, color: PdfColors.sageDark, indent: indent, prefix: number == null ? '' : '$number.');
    if (q == null) await f.rich(ans, size: 11, indent: indent + (number == null ? 0 : 18));
    final exp = q?.explanation ?? c?.explanation ?? '';
    if (o.explanation && exp.trim().isNotEmpty) {
      await f.rich(exp, size: 10.5, color: PdfColors.sub, indent: indent + (number == null ? 0 : 18));
    }
  }
}

/// 笔记导出里的一条：笔记本身 + 解析好的知识点、题目、照片。
class NoteExport {
  final StudyNote note;
  final KnowledgePoint? kp;
  final List<Question> questions;
  final List<Uint8List> photos;
  final Map<String, String> docNames; // docId → 资料名（引用出处）
  const NoteExport(this.note, {this.kp, this.questions = const [], this.photos = const [], this.docNames = const {}});
}

extension NotesPdf on PdfExportService {
  /// 笔记 PDF：按章节分组，每条笔记依次是知识点、我的理解、AI 讲解、照片、相关题目、引用原文。
  Future<Uint8List> notes(String title, List<NoteExport> items, {DateTime? now}) async {
    final f = PdfFlow(fontBytes, math: math, footerTitle: '$title · 笔记');
    f.title('$title · 笔记', '共 ${items.length} 条 · 导出于 ${PdfExportService.dateLabel(now ?? DateTime.now())}');
    var lastChapter = '';
    for (final it in items) {
      final n = it.note;
      if (n.chapter.isNotEmpty && n.chapter != lastChapter) {
        f.section(n.chapter);
        lastChapter = n.chapter;
      }
      f.ensure(60);
      await f.rich(n.title.isEmpty ? '（无标题）' : n.title, size: 14, bold: true);
      if (it.kp != null && it.kp!.content.isNotEmpty) {
        f.meta('知识点${it.kp!.page > 0 ? ' · 第 ${it.kp!.page} 页' : ''}');
        await f.rich(it.kp!.content, size: 10.5, color: PdfColors.sub);
      }
      Future<void> part(String label, String body) async {
        if (body.trim().isEmpty) return;
        f.gap(4);
        f.text(label, size: 11, color: PdfColors.sageDark, bold: true, lineGap: 3);
        await f.rich(body, size: 11);
      }

      await part('我的理解', n.own);
      await part('AI 讲解', n.ai);
      if (it.photos.isNotEmpty) {
        f.gap(4);
        f.text('照片', size: 11, color: PdfColors.sageDark, bold: true, lineGap: 3);
        for (final p in it.photos) {
          try {
            f.image(p, maxHeight: 320);
          } catch (_) {
            f.meta('（图片无法读取）');
          }
        }
      }
      if (it.questions.isNotEmpty) {
        f.gap(4);
        f.text('相关题目', size: 11, color: PdfColors.sageDark, bold: true, lineGap: 3);
        for (var i = 0; i < it.questions.length; i++) {
          final q = it.questions[i];
          await f.rich(q.stem, size: 10.5, prefix: '${i + 1}.');
          for (var j = 0; j < q.options.length; j++) {
            await f.rich(q.options[j], size: 10.5, indent: 18, prefix: '${String.fromCharCode(65 + j)}.');
          }
          await f.rich('**答案：**${q.type == '填空' ? q.answer.split('|').join(' / ') : q.answer}', size: 10.5, color: PdfColors.sageDark, indent: 18);
        }
      }
      if (n.quotes.isNotEmpty) {
        f.gap(4);
        f.text('引用原文', size: 11, color: PdfColors.sageDark, bold: true, lineGap: 3);
        for (final q in n.quotes) {
          await f.rich(q.text, size: 10.5, color: PdfColors.sub, indent: 12);
          f.text('——《${it.docNames[q.docId] ?? '资料'}》第 ${q.page} 页', size: 9, color: PdfColors.sub, indent: 12, lineGap: 4);
        }
      }
      f.divider(before: 6, after: 12);
    }
    return f.finish();
  }
}
