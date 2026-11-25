/// 仅用于「显示」的 OCR / HTML 清理：把 DeepSeek OCR 等输出里的 HTML 表格和零散标签整理成可读形式。
///
/// 只影响界面显示、搜索和复制；保存的解析文本以及发给模型的内容都不经过这里。
/// 解析尽量宽容：标签不闭合、嵌套表格、未知标签都不会抛异常，未知标签按原样当文字显示。
library;

/// 表格单元格。
class HtmlCell {
  final String text;
  final int colspan;
  final int rowspan;
  final bool header;
  const HtmlCell(this.text, {this.colspan = 1, this.rowspan = 1, this.header = false});
  @override
  String toString() => '${header ? 'th' : 'td'}($text${colspan > 1 ? ',c$colspan' : ''}${rowspan > 1 ? ',r$rowspan' : ''})';
}

/// 表格：按行存放的单元格（尚未展开合并单元格）。
class HtmlTable {
  final List<List<HtmlCell>> rows;
  /// 表头行数（<thead> 或全部是 <th> 的行；都没有时为 0）。
  final int headerRows;
  final String caption;
  const HtmlTable(this.rows, {this.headerRows = 0, this.caption = ''});

  /// 展开 colspan / rowspan 后的网格：被合并占据的位置为 null，内容只放在左上角的格子里。
  List<List<HtmlCell?>> grid() {
    final out = <List<HtmlCell?>>[];
    final pending = <int, int>{}; // 列 → 还要被上方 rowspan 占据的行数
    for (final row in rows) {
      final line = <HtmlCell?>[];
      var col = 0;
      void skipTaken() {
        while ((pending[col] ?? 0) > 0) {
          pending[col] = pending[col]! - 1;
          line.add(null);
          col++;
        }
      }

      for (final c in row) {
        skipTaken();
        final cs = c.colspan.clamp(1, 50), rs = c.rowspan.clamp(1, 200);
        for (var k = 0; k < cs; k++) {
          line.add(k == 0 ? c : null);
          if (rs > 1) pending[col] = rs - 1;
          col++;
        }
      }
      // 行尾仍被上方合并单元格占据的列
      final maxCol = pending.keys.fold<int>(-1, (a, b) => b > a ? b : a);
      while (col <= maxCol) {
        if ((pending[col] ?? 0) > 0) {
          pending[col] = pending[col]! - 1;
          line.add(null);
        } else {
          line.add(const HtmlCell(''));
        }
        col++;
      }
      out.add(line);
    }
    final width = out.fold<int>(0, (a, r) => r.length > a ? r.length : a);
    for (final r in out) {
      while (r.length < width) {
        r.add(const HtmlCell(''));
      }
    }
    return out;
  }

  int get columnCount => grid().fold<int>(0, (a, r) => r.length > a ? r.length : a);

  /// 复制 / 搜索用的纯文本：单元格之间用 Tab，行之间换行。
  String toPlainText() {
    final lines = <String>[if (caption.isNotEmpty) caption];
    for (final r in grid()) {
      lines.add(r.map((c) => (c == null ? '' : htmlInlineToText(c.text)).replaceAll(RegExp(r'\s*\n\s*'), ' ').trim()).join('\t'));
    }
    return lines.join('\n');
  }
}

// ---------------------------------------------------------------- 实体与零散标签

const _named = {
  'nbsp': ' ', 'ensp': ' ', 'emsp': ' ', 'thinsp': ' ', 'lt': '<', 'gt': '>', 'amp': '&', 'quot': '"', 'apos': "'",
  'times': '×', 'divide': '÷', 'plusmn': '±', 'deg': '°', 'middot': '·', 'hellip': '…', 'mdash': '—', 'ndash': '–',
  'le': '≤', 'ge': '≥', 'ne': '≠', 'asymp': '≈', 'infin': '∞', 'minus': '−', 'rarr': '→', 'larr': '←',
  'lsquo': '‘', 'rsquo': '’', 'ldquo': '“', 'rdquo': '”', 'copy': '©', 'reg': '®', 'sup2': '²', 'sup3': '³',
  'frac12': '½', 'alpha': 'α', 'beta': 'β', 'gamma': 'γ', 'delta': 'δ', 'pi': 'π', 'sigma': 'σ', 'mu': 'μ',
  'lambda': 'λ', 'theta': 'θ', 'omega': 'ω', 'micro': 'µ', 'yen': '¥',
};
final _entity = RegExp(r'&(#[xX][0-9a-fA-F]{1,6}|#\d{1,7}|[a-zA-Z][a-zA-Z0-9]{1,9});');

/// 解码 HTML 实体（&nbsp; &lt; &#39; &#x4e2d; …）；不认识的保持原样。
String decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entity, (m) {
    final e = m[1]!;
    if (e.startsWith('#')) {
      final hex = e.length > 1 && (e[1] == 'x' || e[1] == 'X');
      final v = int.tryParse(hex ? e.substring(2) : e.substring(1), radix: hex ? 16 : 10);
      // 控制字符（含渲染器内部占位符用到的 \u0000 / \u0001）不解码
      if (v == null || v < 32 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) return m[0]!;
      return String.fromCharCode(v);
    }
    return _named[e] ?? _named[e.toLowerCase()] ?? m[0]!;
  });
}

/// 公式源码里的 HTML 实体（OCR 有时把 < 写成 &lt;）：只解码这几种，不碰 LaTeX 的 & 对齐符。
String decodeMathEntities(String s) => !s.contains('&')
    ? s
    : s.replaceAllMapped(RegExp(r'&(lt|gt|amp|nbsp|quot);'),
        (m) => const {'lt': '<', 'gt': '>', 'amp': '&', 'nbsp': ' ', 'quot': '"'}[m[1]]!);

const _supMap = {
  '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴', '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
  '+': '⁺', '-': '⁻', '−': '⁻', '=': '⁼', '(': '⁽', ')': '⁾', 'n': 'ⁿ', 'i': 'ⁱ', 'T': 'ᵀ',
};
const _subMap = {
  '0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄', '5': '₅', '6': '₆', '7': '₇', '8': '₈', '9': '₉',
  '+': '₊', '-': '₋', '−': '₋', '=': '₌', '(': '₍', ')': '₎',
};
String _script(String inner, Map<String, String> map, String mark) {
  final t = inner.trim();
  if (t.isEmpty) return '';
  if (t.split('').every(map.containsKey)) return t.split('').map((c) => map[c]).join();
  return t.length == 1 ? '$mark$t' : '$mark($t)';
}

// 会被直接去掉（保留里面文字）的排版标签
const _dropTags = {
  'span', 'font', 'u', 'ins', 'center', 'small', 'big', 'html', 'body', 'head', 'section', 'article', 'header',
  'footer', 'main', 'figure', 'figcaption', 'label', 'mark', 'abbr', 'cite', 'tt', 'nobr', 'colgroup', 'col',
  'ul', 'ol', 'a', 'blockquote', 'pre', 'code', 'strike', 's', 'del', 'math', 'thead', 'tbody', 'tfoot', 'caption',
};
const _tableTags = {'table', 'tr', 'td', 'th', 'thead', 'tbody', 'tfoot', 'caption', 'colgroup', 'col'};

final _tag = RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)(\s[^<>]*)?\s*/?>');
final _comment = RegExp(r'<!--[\s\S]*?(-->|$)');
final _code = RegExp(r'`[^`\n]+`');

/// 把行内 HTML 转成 Markdown（[markdown] 为 false 时转成纯文字）。
/// 只处理常见标签；不认识的标签原样保留成文字。反引号里的代码不动。
String htmlInline(String s, {bool markdown = true, bool paragraphs = true}) {
  if (!s.contains('<') && !s.contains('&')) return s;
  // 保护行内代码
  final codes = <String>[];
  var t = s.replaceAllMapped(_code, (m) {
    codes.add(m[0]!);
    return '\u0002${codes.length - 1}\u0002';
  });
  t = t.replaceAll(_comment, '');
  final b = markdown ? '**' : '', i = markdown ? '*' : '';
  // 成对的强调 / 上下标
  for (final (names, open, close) in [
    ('b|strong', b, b),
    ('i|em|var', i, i),
  ]) {
    t = t.replaceAllMapped(RegExp('<($names)(\\s[^<>]*)?>([\\s\\S]*?)</\\1\\s*>', caseSensitive: false), (m) {
      final inner = m[3]!;
      if (inner.trim().isEmpty) return inner;
      // Markdown 强调符号不能紧贴空白，把首尾空白移到外面
      final lead = RegExp(r'^\s*').stringMatch(inner)!, trail = RegExp(r'\s*$').stringMatch(inner)!;
      return '$lead$open${inner.trim()}$close$trail';
    });
  }
  t = t.replaceAllMapped(RegExp(r'<sup(\s[^<>]*)?>([\s\S]*?)</sup\s*>', caseSensitive: false),
      (m) => _script(m[2]!, _supMap, '^'));
  t = t.replaceAllMapped(RegExp(r'<sub(\s[^<>]*)?>([\s\S]*?)</sub\s*>', caseSensitive: false),
      (m) => _script(m[2]!, _subMap, '_'));
  t = t.replaceAllMapped(_tag, (m) {
    final close = m[1] == '/';
    final name = m[2]!.toLowerCase();
    switch (name) {
      case 'br':
        return '\n';
      case 'p':
      case 'div':
        return paragraphs ? '\n\n' : '\n';
      case 'li':
        return close ? '' : (markdown ? '\n- ' : '\n• ');
      case 'hr':
        return markdown ? '\n\n---\n\n' : '\n';
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        if (close || !markdown) return '\n';
        return '\n${'#' * int.parse(name.substring(1))} ';
      case 'img':
        return '[插图]';
      case 'b':
      case 'strong':
      case 'i':
      case 'em':
      case 'var':
      case 'sup':
      case 'sub':
        return m[0]!; // 不成对的强调 / 上下标：当文字显示，避免误删内容
    }
    if (_dropTags.contains(name) || _tableTags.contains(name)) return '';
    return m[0]!; // 未知标签：原样显示
  });
  t = decodeEntities(t);
  t = t.replaceAllMapped(RegExp('\u0002(\\d+)\u0002'), (m) => codes[int.parse(m[1]!)]);
  return t;
}

/// 单元格 / 行内内容转纯文字（复制、搜索用）。
String htmlInlineToText(String s) => htmlInline(s, markdown: false, paragraphs: false).trim();

// ---------------------------------------------------------------- 表格解析

final _tableOpen = RegExp(r'<table\b[^<>]*>', caseSensitive: false);
final _tableAny = RegExp(r'<(/?)table\b[^<>]*>', caseSensitive: false);
final _attr = RegExp(r'''(colspan|rowspan)\s*=\s*["']?\s*(\d+)''', caseSensitive: false);

final _cellClose = RegExp(r'</(tr|td|th)\s*>', caseSensitive: false);

/// 找到与 [start] 处 <table> 配对的 </table> 结束位置。
/// 不闭合时（OCR 截断、流式输出）不会吞掉后面的全部内容：到最后一个 </tr> / </td> 之后的空行为止，
/// 没有空行才到文末。
int _tableEnd(String s, int start) {
  var depth = 0;
  for (final m in _tableAny.allMatches(s, start)) {
    depth += m[1] == '/' ? -1 : 1;
    if (depth == 0) return m.end;
  }
  final lastCell = _cellClose.allMatches(s, start).lastOrNull?.end ?? start;
  final blank = s.indexOf('\n\n', lastCell);
  return blank < 0 ? s.length : blank;
}

/// 行内代码（`...`）换成等长的空白，用来找表格位置：代码里写的 <table> 只是文字。
String _maskCode(String s) => !s.contains('`') ? s : s.replaceAllMapped(_code, (m) => ' ' * m[0]!.length);

/// 解析一段 HTML 表格源码（可以不完整）。
HtmlTable parseHtmlTable(String src) {
  final rows = <List<HtmlCell>>[];
  final headerFlags = <bool>[];
  final caption = StringBuffer();
  List<HtmlCell>? row;
  StringBuffer? cell;
  var cellHeader = false, cs = 1, rs = 1, inHead = false, inCaption = false;
  var started = false; // 已跳过最外层 <table>

  void closeCell() {
    if (cell == null) return;
    row ??= [];
    row!.add(HtmlCell(cell.toString().trim(), colspan: cs, rowspan: rs, header: cellHeader || inHead));
    cell = null;
  }

  void closeRow() {
    closeCell();
    if (row != null && row!.isNotEmpty) {
      headerFlags.add(row!.every((c) => c.header));
      rows.add(row!);
    }
    row = null;
  }

  var pos = 0;
  final tagRe = RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)\b([^<>]*)>');
  while (pos < src.length) {
    final m = tagRe.firstMatch(src.substring(pos));
    final textEnd = m == null ? src.length : pos + m.start;
    final text = src.substring(pos, textEnd);
    if (text.trim().isNotEmpty) {
      if (inCaption) {
        caption.write(text);
      } else {
        if (cell == null) {
          // 单元格外的文字（标签缺失）：当作一个新单元格
          cell = StringBuffer();
          cellHeader = false;
          cs = rs = 1;
        }
        cell!.write(text);
      }
    } else if (cell != null) {
      cell!.write(text);
    }
    if (m == null) break;
    final close = m[1] == '/';
    final name = m[2]!.toLowerCase();
    final whole = m[0]!;
    pos += m.end;
    if (name == 'table' && !close) {
      if (!started) {
        started = true;
        continue;
      }
      // 嵌套表格：整体转成文字放进当前单元格
      final abs = pos - whole.length;
      final end = _tableEnd(src, abs);
      final inner = parseHtmlTable(src.substring(abs, end));
      cell ??= StringBuffer();
      if (cell!.toString().trim().isNotEmpty) cell!.write('<br>');
      cell!.write(inner.toPlainText().replaceAll('\t', ' / ').replaceAll('\n', '<br>'));
      pos = end;
      continue;
    }
    switch (name) {
      case 'table':
        closeRow();
        pos = src.length; // 最外层结束
      case 'tr':
        closeRow();
        if (!close) row = [];
      case 'td':
      case 'th':
        closeCell();
        if (!close) {
          cell = StringBuffer();
          cellHeader = name == 'th';
          cs = rs = 1;
          for (final a in _attr.allMatches(m[3] ?? '')) {
            final v = int.tryParse(a[2]!) ?? 1;
            if (a[1]!.toLowerCase() == 'colspan') cs = v < 1 ? 1 : v;
            if (a[1]!.toLowerCase() == 'rowspan') rs = v < 1 ? 1 : v;
          }
        }
      case 'thead':
        closeRow();
        inHead = !close;
      case 'tbody':
      case 'tfoot':
        closeRow();
        inHead = false;
      case 'caption':
        inCaption = !close;
      default:
        // 单元格里的其它标签（<br> <b> …）原样保留，渲染时再转换
        if (inCaption) {
          caption.write(whole);
        } else {
          cell ??= StringBuffer();
          cell!.write(whole);
        }
    }
  }
  closeRow();
  var head = 0;
  while (head < headerFlags.length && headerFlags[head]) {
    head++;
  }
  return HtmlTable(rows, headerRows: head, caption: htmlInlineToText(caption.toString()));
}

// ---------------------------------------------------------------- Markdown 管道表格

final _pipeSep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');

bool isPipeRow(String line) => line.contains('|') && line.trim().length > 1;
bool isPipeSeparator(String line) => _pipeSep.hasMatch(line) && line.contains('-');

List<String> splitPipeRow(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  final cells = <String>[];
  final b = StringBuffer();
  for (var i = 0; i < t.length; i++) {
    if (t[i] == '\\' && i + 1 < t.length && t[i + 1] == '|') {
      b.write('|');
      i++;
    } else if (t[i] == '|') {
      cells.add(b.toString().trim());
      b.clear();
    } else {
      b.write(t[i]);
    }
  }
  cells.add(b.toString().trim());
  return cells;
}

// ---------------------------------------------------------------- 整段清理

final _bar = r'[｜|]';
final _refBox = RegExp('<${_bar}ref$_bar>([\\s\\S]*?)<$_bar/ref$_bar>\\s*(<$_bar(?:box|det)$_bar>[\\s\\S]*?<$_bar/(?:box|det)$_bar>)?');
final _strayGround = RegExp('<$_bar/?(?:ref|box|det|grounding|image|quad)$_bar>');
final _strayCoords = RegExp(r'\[\[\s*\d+(?:\s*,\s*\d+){3}\s*\]\](?:\s*,\s*\[\[\s*\d+(?:\s*,\s*\d+){3}\s*\]\])*');
final _mdImage = RegExp(r'!\[[^\]\n]*\]\([^)\n]*\)');

/// 去掉 DeepSeek OCR 的定位标记（<|ref|>…<|/ref|><|det|>[[..]]<|/det|>）和 Markdown 图片占位。
String stripOcrMarkup(String s) {
  if (!s.contains('<') && !s.contains('[[') && !s.contains('![')) return s;
  var r = s.replaceAllMapped(_refBox, (m) {
    final label = m[1]!.trim().toLowerCase();
    if (label == 'image' || label == 'figure') return '[插图]';
    // 版面类型标签直接去掉；其它（真实文字）保留
    const layout = {'text', 'title', 'sub_title', 'table', 'table_caption', 'table_footnote', 'image_caption',
      'equation', 'formula', 'header', 'footer', 'page_number', 'list', 'caption', 'footnote'};
    return layout.contains(label) ? '' : m[1]!;
  });
  return r.replaceAll(_strayGround, '').replaceAll(_strayCoords, '').replaceAll(_mdImage, '[插图]');
}

/// 文本里是否有需要显示层处理的 HTML / OCR 标记。
bool hasHtmlLike(String s) => s.contains('<') || s.contains('&') || s.contains('[[') || s.contains('![');

/// 显示用清理：把 HTML 表格交给 [table] 处理（返回值独占若干行），其余行内 HTML 转成 Markdown 或纯文字。
String cleanForDisplay(String s, {required String Function(HtmlTable t) table, bool markdown = true}) {
  if (!hasHtmlLike(s)) return s;
  var t = stripOcrMarkup(s);
  final mask = _maskCode(t);
  final out = StringBuffer();
  var pos = 0;
  while (true) {
    final m = _tableOpen.firstMatch(mask.substring(pos));
    if (m == null) break;
    final start = pos + m.start;
    final end = _tableEnd(mask, start);
    out.write(htmlInline(t.substring(pos, start), markdown: markdown));
    final tb = parseHtmlTable(t.substring(start, end));
    if (tb.rows.isNotEmpty) out.write('\n\n${table(tb)}\n\n');
    pos = end;
  }
  var rest = t.substring(pos);
  final restMask = mask.substring(pos);
  // 缺了 <table> 的残缺表格：从第一个 <tr> 到最后一个 </tr>（或 </td>）
  final tr = RegExp(r'<tr\b[^<>]*>', caseSensitive: false).firstMatch(restMask);
  if (tr != null) {
    final lastEnd = _cellClose.allMatches(restMask).lastOrNull?.end;
    final blank = restMask.indexOf('\n\n', tr.start);
    final end = lastEnd != null && lastEnd > tr.start ? lastEnd : (blank < 0 ? rest.length : blank);
    final tb = parseHtmlTable('<table>${rest.substring(tr.start, end)}</table>');
    out.write(htmlInline(rest.substring(0, tr.start), markdown: markdown));
    if (tb.rows.isNotEmpty) out.write('\n\n${table(tb)}\n\n');
    rest = rest.substring(end);
  }
  out.write(htmlInline(rest, markdown: markdown));
  return out.toString().replaceAll(RegExp(r'[ \t]+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

/// 复制 / 搜索用的纯文字：表格变成 Tab 分隔的行，标签和实体都整理掉（Markdown 符号与公式保持原样）。
/// 结果有小缓存，章节查看页每次重建都要用来计数和复制。
String displayPlainText(String s) {
  if (!hasHtmlLike(s)) return s.trim();
  final hit = _plainCache.remove(s);
  final v = hit ?? cleanForDisplay(s, table: (t) => t.toPlainText(), markdown: true).trim();
  _plainCache[s] = v;
  if (_plainCache.length > 300) _plainCache.remove(_plainCache.keys.first);
  return v;
}

final _plainCache = <String, String>{};
