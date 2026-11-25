import 'package:flutter_math_fork/flutter_math.dart';
import 'package:material_ui/material_ui.dart';

import '../services/latex.dart';
import 'glass.dart' show M;
import 'html_clean.dart';
import 'latex_text.dart';

// 颜色与 glass.dart 中的莫兰迪配色一致（避免循环依赖，这里单独定义）
Color get _text => M.text;
Color get _sub => M.sub;
Color get _sage => M.sage;
Color get _sageDark => M.sageDark;

/// Markdown 块类型
enum MdBlockType { paragraph, heading, bullet, ordered, quote, rule, math, table, code }

class MdBlock {
  final MdBlockType type;
  final String text; // 行内内容（公式已替换成占位符）
  final int level; // 标题级别 1-6 / 列表缩进层级
  final String marker; // 有序列表的序号
  const MdBlock(this.type, this.text, {this.level = 0, this.marker = ''});
  @override
  String toString() => '${type.name}($level$marker):$text';
}

/// 解析结果：块列表 + 公式表（占位符 \u0000n\u0000 → 公式）。
class MdDoc {
  final List<MdBlock> blocks;
  final List<TexSegment> math;
  /// 表格（HTML 表格与 Markdown 管道表格）；table 块的 text 是这里的下标。
  final List<HtmlTable> tables;
  /// 成对 ``` 包起来的代码块原文；code 块的 text 是这里的下标。
  final List<String> codeBlocks;
  const MdDoc(this.blocks, this.math, [this.tables = const [], this.codeBlocks = const []]);
}

/// Markdown + LaTeX 混排解析器。
/// 先把公式整体「保护」成占位符，再做 Markdown 解析，所以公式里的 * _ \ 不会被误当成格式符号。
/// 未闭合的 $ 按普通文字显示（流式输出时也不会崩溃）。
class MdMath {
  static const ph = '\u0000';
  static final _ordered = RegExp(r'^(\s*)(\d+)[\.\)、]\s+(.*)$');
  static final _bullet = RegExp(r'^(\s*)[-*+•]\s+(.*)$');
  static final _heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$');
  static final _quote = RegExp(r'^\s{0,3}>\s?(.*)$');
  static final _rule = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
  static final _mathOnly = RegExp('^\\s*$ph(\\d+)$ph\\s*\$');
  static const tph = '\u0001';
  static final _tableOnly = RegExp('^\\s*$tph(\\d+)$tph\\s*\$');
  static final _codeOnly = RegExp('^\\s*$codeBlockTok(\\d+)$codeBlockTok\\s*\$');
  // OCR 常见：# 后面直接跟中文（没有空格）也当标题
  static final _headingCjk = RegExp(r'^\s{0,3}(#{1,6})(?=[\u4e00-\u9fff])(.*?)\s*$');
  // 只有 Markdown 符号、没有内容的行（OCR 残留）
  static final _bareMarks = RegExp(r'^\s*(\*{1,2}|#{1,6})\s*$');

  static MdDoc parse(String input) {
    final math = <TexSegment>[];
    final b = StringBuffer();
    for (final seg in LatexUtil.split(input.replaceAll('\r\n', '\n'))) {
      if (!seg.isMath) {
        b.write(seg.text.replaceAll(ph, ''));
        continue;
      }
      math.add(seg.text.contains('&') ? TexSegment(decodeMathEntities(seg.text), isMath: true, display: seg.display) : seg);
      final tok = '$ph${math.length - 1}$ph';
      b.write(seg.display ? '\n$tok\n' : tok);
    }
    // 显示层清理：HTML 表格 → 表格块，零散 HTML 标签 / 实体 / OCR 定位标记 → Markdown 文字（公式已保护，不受影响）
    // 显示层整理 LaTeX 文本命令、环境和代码块（公式占位符不动，只可能追加原本裸露的数学环境）
    final codeBlocks = <String>[];
    final prepared = prepareLatexText(b.toString().replaceAll(tph, ''), math, codeBlocks);
    final tables = <HtmlTable>[];
    final body = cleanForDisplay(prepared, table: (t) {
      tables.add(t);
      return '$tph${tables.length - 1}$tph';
    });
    final blocks = <MdBlock>[];
    final para = <String>[];
    void flushPara() {
      if (para.isNotEmpty) {
        blocks.add(MdBlock(MdBlockType.paragraph, para.join('\n')));
        para.clear();
      }
    }

    final lines = body.split('\n');
    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
      if (line.trim().isEmpty) {
        flushPara();
        continue;
      }
      RegExpMatch? m;
      if ((m = _codeOnly.firstMatch(line)) != null) {
        flushPara();
        blocks.add(MdBlock(MdBlockType.code, m![1]!));
        continue;
      }
      if (_bareMarks.hasMatch(line)) continue;
      if ((m = _headingCjk.firstMatch(line)) != null && !_heading.hasMatch(line)) {
        flushPara();
        blocks.add(MdBlock(MdBlockType.heading, m![2]!, level: m[1]!.length));
        continue;
      }
      if ((m = _tableOnly.firstMatch(line)) != null) {
        flushPara();
        blocks.add(MdBlock(MdBlockType.table, m![1]!));
        continue;
      }
      // Markdown 管道表格：表头行 + 分隔行（|---|---|）+ 若干数据行
      if (isPipeRow(line) && li + 1 < lines.length && isPipeSeparator(lines[li + 1]) && !isPipeSeparator(line)) {
        flushPara();
        final rows = <List<HtmlCell>>[
          [for (final c in splitPipeRow(line)) HtmlCell(c, header: true)]
        ];
        li += 2;
        while (li < lines.length && lines[li].trim().isNotEmpty && lines[li].contains('|') && !_tableOnly.hasMatch(lines[li])) {
          rows.add([for (final c in splitPipeRow(lines[li])) HtmlCell(c)]);
          li++;
        }
        li--;
        tables.add(HtmlTable(rows, headerRows: 1));
        blocks.add(MdBlock(MdBlockType.table, '${tables.length - 1}'));
        continue;
      }
      if ((m = _mathOnly.firstMatch(line)) != null && math[int.parse(m![1]!)].display) {
        flushPara();
        blocks.add(MdBlock(MdBlockType.math, m[1]!));
      } else if ((m = _heading.firstMatch(line)) != null) {
        flushPara();
        blocks.add(MdBlock(MdBlockType.heading, m![2]!, level: m[1]!.length));
      } else if (_rule.hasMatch(line)) {
        flushPara();
        blocks.add(const MdBlock(MdBlockType.rule, ''));
      } else if ((m = _ordered.firstMatch(line)) != null) {
        flushPara();
        blocks.add(MdBlock(MdBlockType.ordered, m![3]!, level: m[1]!.length ~/ 2, marker: '${m[2]}.'));
      } else if ((m = _bullet.firstMatch(line)) != null) {
        flushPara();
        blocks.add(MdBlock(MdBlockType.bullet, m![2]!, level: m[1]!.length ~/ 2));
      } else if ((m = _quote.firstMatch(line)) != null) {
        flushPara();
        if (blocks.isNotEmpty && blocks.last.type == MdBlockType.quote) {
          final prev = blocks.removeLast();
          blocks.add(MdBlock(MdBlockType.quote, '${prev.text}\n${m![1]}'));
        } else {
          blocks.add(MdBlock(MdBlockType.quote, m![1]!));
        }
      } else {
        para.add(line.trim());
      }
    }
    flushPara();
    return MdDoc(blocks, math, tables, codeBlocks);
  }

  /// 行内标记：**粗体**、*斜体*、`代码`、公式占位符。
  static final inlineRe = RegExp('\\*\\*(.+?)\\*\\*|__(.+?)__|(?<![\\w*])\\*(?![\\s*])(.+?)(?<!\\s)\\*(?![\\w*])|`([^`\\n]+)`|$ph(\\d+)$ph'
      '|${Mk.boldOpen}([\\s\\S]+?)${Mk.boldClose}|${Mk.itOpen}([\\s\\S]+?)${Mk.itClose}|${Mk.ulOpen}([\\s\\S]+?)${Mk.ulClose}'
      '|${Mk.codeOpen}([\\s\\S]*?)${Mk.codeClose}');
}

/// 去掉模型开头的「元话语」，如「下面完整重写，公式均使用 LaTeX。」「好的，以下是……」。
String stripMetaPreamble(String s) {
  var t = s.trimLeft();
  final re = RegExp(
      r'^(好的|好|当然|没问题|下面|以下|我将|我会|已|这里|现在)?[，,、\s]*[^\n。！!]{0,40}(重写|改写|修正|重新(输出|生成|给出)|LaTeX|公式均|格式)[^\n。！!]{0,30}[。！!：:]?\s*\n?');
  for (var i = 0; i < 2; i++) {
    final m = re.firstMatch(t);
    if (m == null || m.end > 80) break;
    t = t.substring(m.end).trimLeft();
  }
  return t.isEmpty ? s : t;
}

/// Markdown + 公式混排文本：标题、粗体/斜体、代码、列表、引用、分隔线、行内与独立公式。
/// 公式统一用 flutter_math_fork 排版；含公式时整体缓存成独立图层，滚动不重绘。
class MathText extends StatelessWidget {
  /// 公式字号倍率（外观设置 → 公式字号）。
  static double mathScale = 1.0;
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  /// 搜索高亮：普通文字中的匹配加底色；公式源码包含关键词时整个公式加底色。
  final String? highlight;
  /// 长按可选中文字。公式在选区里按原始 LaTeX（`$...$` / `$$...$$`）复制。
  final bool selectable;
  const MathText(this.text, {super.key, this.style, this.textAlign = TextAlign.start, this.highlight, this.selectable = false});

  /// 高亮颜色（搜索结果）。
  static Color get highlightColor => M.oat.withValues(alpha: 0.9);

  @override
  Widget build(BuildContext context) {
    final st = DefaultTextStyle.of(context).style.merge(style);
    // 等宽字体没有中文字形时退回正文字体（设备上正文字体为系统默认时不起作用，与原来一致）
    final monoFallback = [if (st.fontFamily != null && st.fontFamily != 'monospace') st.fontFamily!];
    final doc = MdMath.parse(text);
    final center = textAlign == TextAlign.center;

    // 公式无法排版时：显示原始写法（低调的等宽小字），不再用醒目的红字
    Widget fallback(String tex, TextStyle s) => Text(tex,
        style: s.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: monoFallback,
            fontSize: (s.fontSize ?? 15) * 0.9,
            color: _sub,
            backgroundColor: M.glass.withValues(alpha: 0.5)));

    Widget mathWidget(TexSegment seg, TextStyle s, {bool display = false}) {
      Widget tex(String src, Widget Function(FlutterMathException) onError) => Math.tex(
            src,
            mathStyle: display ? MathStyle.display : MathStyle.text,
            textStyle: TextStyle(fontSize: (s.fontSize ?? 15) * (display ? 1.1 : 1.05) * mathScale, color: s.color),
            onErrorFallback: onError,
          );
      // 只有原本排版失败时才尝试修复（环境改写、中文包进 \text{}）；能显示的公式走的还是原来的路径
      return tex(seg.text, (e) {
        final fixed = repairTex(seg.text);
        if (fixed == seg.text.trim()) return fallback(seg.text, s);
        return tex(fixed, (_) => fallback(seg.text, s));
      });
    }

    final hl = highlight?.trim().toLowerCase() ?? '';
    InlineSpan plain(String raw) {
      // 还原转义字符；没有配对的 ** 去掉（2**3 这类夹在字母数字中间的保留）
      var t = Mk.restore(raw);
      if (t.contains('**')) t = t.replaceAll(RegExp(r'(?<![A-Za-z0-9_])\*\*|\*\*(?![A-Za-z0-9_])'), '');
      if (hl.isEmpty) return TextSpan(text: t);
      final lower = t.toLowerCase();
      final parts = <InlineSpan>[];
      var i = 0;
      while (true) {
        final j = lower.indexOf(hl, i);
        if (j < 0) break;
        if (j > i) parts.add(TextSpan(text: t.substring(i, j)));
        parts.add(TextSpan(text: t.substring(j, j + hl.length), style: TextStyle(backgroundColor: highlightColor)));
        i = j + hl.length;
      }
      if (parts.isEmpty) return TextSpan(text: t);
      if (i < t.length) parts.add(TextSpan(text: t.substring(i)));
      return TextSpan(children: parts);
    }

    Widget marked(TexSegment seg, Widget w) => hl.isNotEmpty && seg.text.toLowerCase().contains(hl)
        ? Container(
            decoration: BoxDecoration(color: highlightColor, borderRadius: BorderRadius.circular(4)),
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: w)
        : w;

    /// 可选中时，把公式的原始 LaTeX 放进一个几乎看不见的文字，这样复制能拿到源码。
    InlineSpan mathSpan(TexSegment seg, TextStyle s, {bool display = false}) {
      final visual = marked(seg, mathWidget(seg, s, display: display));
      if (!selectable) return WidgetSpan(alignment: PlaceholderAlignment.middle, child: visual);
      final src = latexCopySource(seg, display: display);
      return TextSpan(children: [
        TextSpan(text: src, style: const TextStyle(color: Color(0x00000000), fontSize: 0.01, height: 0.01)),
        WidgetSpan(alignment: PlaceholderAlignment.middle, child: SelectionContainer.disabled(child: visual)),
      ]);
    }

    List<InlineSpan> inline(String src, TextStyle s) {
      final out = <InlineSpan>[];
      var pos = 0;
      for (final m in MdMath.inlineRe.allMatches(src)) {
        if (m.start > pos) out.add(plain(src.substring(pos, m.start)));
        if (m[1] != null || m[2] != null || m[6] != null) {
          final bs = s.copyWith(fontWeight: FontWeight.w700);
          out.add(TextSpan(style: const TextStyle(fontWeight: FontWeight.w700), children: inline(m[1] ?? m[2] ?? m[6]!, bs)));
        } else if (m[3] != null || m[7] != null) {
          out.add(TextSpan(style: const TextStyle(fontStyle: FontStyle.italic), children: inline(m[3] ?? m[7]!, s)));
        } else if (m[8] != null) {
          out.add(TextSpan(style: const TextStyle(decoration: TextDecoration.underline), children: inline(m[8]!, s)));
        } else if (m[4] != null || m[9] != null) {
          out.add(TextSpan(
              text: Mk.restore(m[4] ?? m[9]!),
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: monoFallback,
                  fontSize: (s.fontSize ?? 15) * 0.92,
                  backgroundColor: M.glass.withValues(alpha: 0.6))));
        } else {
          final seg = doc.math[int.parse(m[5]!)];
          out.add(mathSpan(seg, s));
        }
        pos = m.end;
      }
      if (pos < src.length) out.add(plain(src.substring(pos)));
      return out;
    }

    Widget rich(String src, TextStyle s, {TextAlign? align}) =>
        Text.rich(TextSpan(children: inline(src, s)), style: s, textAlign: align ?? textAlign);

    final fs = st.fontSize ?? 15;
    TextStyle headingStyle(int level) => st.copyWith(
          fontSize: fs * const [1.45, 1.3, 1.15, 1.05, 1.0, 1.0][level - 1],
          fontWeight: FontWeight.w700,
          color: level >= 3 ? _sageDark : _text,
          height: 1.35,
        );

    final widgets = <Widget>[];
    for (final blk in doc.blocks) {
      switch (blk.type) {
        case MdBlockType.paragraph:
          widgets.add(rich(blk.text, st));
        case MdBlockType.heading:
          widgets.add(Padding(
            padding: EdgeInsets.only(top: widgets.isEmpty ? 0 : 6),
            child: rich(blk.text, headingStyle(blk.level)),
          ));
        case MdBlockType.bullet:
        case MdBlockType.ordered:
          final isBullet = blk.type == MdBlockType.bullet;
          widgets.add(Padding(
            padding: EdgeInsets.only(left: 4.0 + blk.level * 16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: isBullet ? 16 : 24,
                child: Text(isBullet ? (blk.level == 0 ? '•' : '◦') : blk.marker,
                    style: st.copyWith(color: _sageDark, fontWeight: FontWeight.w700)),
              ),
              Expanded(child: rich(blk.text, st, align: TextAlign.start)),
            ]),
          ));
        case MdBlockType.quote:
          widgets.add(Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: _sage.withValues(alpha: 0.8), width: 3)),
              color: M.glass.withValues(alpha: 0.35),
            ),
            child: rich(blk.text, st.copyWith(color: _sub), align: TextAlign.start),
          ));
        case MdBlockType.rule:
          widgets.add(Container(
              height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: _sub.withValues(alpha: 0.25)));
        case MdBlockType.code:
          widgets.add(Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: M.glass.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _sub.withValues(alpha: 0.2), width: 0.8),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(doc.codeBlocks[int.parse(blk.text)],
                  style: st.copyWith(fontFamily: 'monospace', fontFamilyFallback: monoFallback, fontSize: fs * 0.88, height: 1.5, color: _text)),
            ),
          ));
        case MdBlockType.table:
          widgets.add(_table(doc, doc.tables[int.parse(blk.text)], st, (src, s) => rich(src, s, align: TextAlign.start)));
        case MdBlockType.math:
          final seg = doc.math[int.parse(blk.text)];
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: selectable
                    ? Text.rich(TextSpan(style: st, children: [mathSpan(seg, st, display: true)]))
                    : marked(seg, mathWidget(seg, st, display: true)),
              ),
            ),
          ));
      }
    }
    if (widgets.isEmpty) return const SizedBox();
    Widget result;
    if (widgets.length == 1) {
      result = widgets.first;
    } else {
      final spaced = <Widget>[];
      for (var i = 0; i < widgets.length; i++) {
        if (i > 0) spaced.add(const SizedBox(height: 6));
        spaced.add(widgets[i]);
      }
      result = Column(
        crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: spaced,
      );
    }
    if (selectable) return SelectionArea(child: result);
    // 公式排版较重：单独成层，滚动时不重绘
    return doc.math.isEmpty ? result : RepaintBoundary(child: result);
  }

  /// 估算一段单元格内容的显示宽度（以字号为单位）：汉字约 1 个字宽，其它约半个；公式按源码长度估算。
  static double _ems(String src, MdDoc doc) {
    var w = 0.0;
    for (final line in src.split('\n')) {
      var lw = 0.0;
      final t = line.replaceAllMapped(RegExp('${MdMath.ph}(\\d+)${MdMath.ph}'), (m) {
        final i = int.tryParse(m[1]!) ?? -1;
        lw += i >= 0 && i < doc.math.length ? doc.math[i].text.length * 0.62 + 0.8 : 1;
        return '';
      }).replaceAll('**', '');
      for (final r in t.runes) {
        lw += r >= 0x2E80 ? 1.0 : 0.56;
      }
      if (lw > w) w = lw;
    }
    return w;
  }

  /// 表格：横向可滚动，列宽按内容估算（不依赖固有尺寸计算，公式单元格也安全），表头浅绿底，隔行浅底色。
  Widget _table(MdDoc doc, HtmlTable t, TextStyle st, Widget Function(String src, TextStyle s) rich) {
    final grid = t.grid();
    if (grid.isEmpty) return const SizedBox();
    final cols = grid.fold<int>(0, (a, r) => r.length > a ? r.length : a);
    final fs = (st.fontSize ?? 15) * 0.92;
    final cellStyle = st.copyWith(fontSize: fs, height: 1.45);
    final widths = List<double>.filled(cols, 0);
    String cellSrc(HtmlCell c) => htmlInline(c.text, paragraphs: false).trim();
    for (final r in grid) {
      for (var i = 0; i < r.length; i++) {
        final c = r[i];
        if (c == null || c.colspan > 1) continue;
        final w = (_ems(cellSrc(c), doc) * fs + 20).clamp(48.0, 240.0);
        if (w > widths[i]) widths[i] = w;
      }
    }
    for (var i = 0; i < cols; i++) {
      if (widths[i] == 0) widths[i] = 56;
    }
    final line = M.sub.withValues(alpha: 0.28);
    final rows = <TableRow>[];
    for (var ri = 0; ri < grid.length; ri++) {
      final header = ri < t.headerRows || (t.headerRows == 0 && ri == 0 && grid.length > 1);
      rows.add(TableRow(
        decoration: BoxDecoration(
          color: header
              ? M.sage.withValues(alpha: 0.2)
              : ri.isEven
                  ? M.glass.withValues(alpha: 0.28)
                  : null,
        ),
        children: [
          for (final c in grid[ri])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: c == null || c.text.isEmpty
                  ? const SizedBox()
                  : rich(cellSrc(c),
                      header || c.header ? cellStyle.copyWith(fontWeight: FontWeight.w700, color: M.text) : cellStyle),
            ),
        ],
      ));
    }
    final table = Table(
      columnWidths: {for (var i = 0; i < cols; i++) i: FixedColumnWidth(widths[i])},
      border: TableBorder.symmetric(inside: BorderSide(color: line, width: 0.6)),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: rows,
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (t.caption.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(t.caption, style: cellStyle.copyWith(color: _sub, fontWeight: FontWeight.w600)),
        ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: line, width: 0.8),
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.antiAlias,
          child: table,
        ),
      ),
    ]);
  }
}

/// 复制公式时用的原始写法：行内 `$...$`，独立公式 `$$...$$`。
String latexCopySource(TexSegment seg, {bool display = false}) {
  final src = seg.text;
  if (display || seg.display) return '\$\$$src\$\$';
  return '\$$src\$';
}
