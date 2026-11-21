/// 仅用于「显示」的 LaTeX 文本模式整理：公式之外的 \texttt{} \textbf{}、itemize / enumerate / tabular 环境、
/// 转义字符、字面量 \n、代码块等。
///
/// 只在渲染器里使用：保存的内容和发给模型的内容都不经过这里。
/// 公式片段在调用前已被替换成占位符（\u0000n\u0000），这里从不读取或修改公式本身；
/// 只有原本整段裸露、不会被当成公式的数学环境（如公式外的 \begin{align}）才会新增为独立公式。
library;

import '../services/latex.dart';

/// 行内样式标记（私用区字符，不会出现在正常文本里）。
class Mk {
  static const ulOpen = '\uE001', ulClose = '\uE002';
  static const codeOpen = '\uE003', codeClose = '\uE004';
  static const boldOpen = '\uE005', boldClose = '\uE006';
  static const itOpen = '\uE007', itClose = '\uE008';
  // 转义得到的字面字符：避免被当成 Markdown / HTML 语法，显示前还原
  static const underscore = '\uE010', hash = '\uE011', amp = '\uE012', star = '\uE013', lt = '\uE014', backtick = '\uE015';
  static final _all = RegExp('[\uE001-\uE008]');

  /// 还原字面字符，去掉没有配对的样式标记。
  static String restore(String s) {
    if (!s.contains(RegExp('[\uE001-\uE015]'))) return s;
    return s
        .replaceAll(_all, '')
        .replaceAll(underscore, '_')
        .replaceAll(hash, '#')
        .replaceAll(amp, '&')
        .replaceAll(star, '*')
        .replaceAll(lt, '<')
        .replaceAll(backtick, '`');
  }
}

const _ph = '\u0000';
const _codeTok = '\u0004';
/// 代码块占位符（独占一行）：\u0005n\u0005。
const codeBlockTok = '\u0005';

// ---------------------------------------------------------------- 括号匹配

/// 从 [open]（必须是 '{'）开始找配对的 '}'，跳过 \{ \}。找不到返回 -1。
int matchBrace(String s, int open) {
  if (open >= s.length || s[open] != '{') return -1;
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == '\\') {
      i++;
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 读取紧跟的 {参数}（允许前面有空格），返回 (内容, 结束位置)；没有或不配对返回 null。
(String, int)? _arg(String s, int i) {
  var j = i;
  while (j < s.length && (s[j] == ' ' || s[j] == '\t')) {
    j++;
  }
  if (j >= s.length || s[j] != '{') return null;
  final e = matchBrace(s, j);
  if (e < 0) return null;
  return (s.substring(j + 1, e), e + 1);
}

/// 跳过可选参数 [..]。
int _skipOpt(String s, int i) {
  var j = i;
  while (j < s.length && s[j] == ' ') {
    j++;
  }
  if (j < s.length && s[j] == '[') {
    final e = s.indexOf(']', j);
    if (e > 0 && !s.substring(j, e).contains('\n')) return e + 1;
  }
  return i;
}

// ---------------------------------------------------------------- 公式修复（只用于原本不能显示的公式）

final _cjkRun = RegExp(r'[\u3000-\u303F\u3400-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF]+');

/// 尝试把排版引擎不支持的写法改成支持的：equation / align / gather 等环境、\emph、\label、公式里的中文。
/// 只在公式原本无法显示（排版失败）或是公式外裸露的数学环境时使用；能正常显示的公式不会经过这里。
String repairTex(String tex) {
  var t = tex.trim();
  t = t.replaceAllMapped(RegExp(r'\\begin\{(equation|displaymath|math)\*?\}([\s\S]*?)\\end\{\1\*?\}'), (m) => m[2]!);
  t = t.replaceAllMapped(RegExp(r'\\begin\{(align|alignat|flalign|eqnarray)\*?\}(\{\d+\})?([\s\S]*?)\\end\{\1\*?\}'),
      (m) => '\\begin{aligned}${m[3]!.replaceAll('&=&', '&=')}\\end{aligned}');
  t = t.replaceAllMapped(RegExp(r'\\begin\{(gather|multline)\*?\}([\s\S]*?)\\end\{\1\*?\}'),
      (m) => '\\begin{gathered}${m[2]}\\end{gathered}');
  t = t.replaceAllMapped(RegExp(r'\\begin\{split\}([\s\S]*?)\\end\{split\}'), (m) => '\\begin{aligned}${m[1]}\\end{aligned}');
  t = t.replaceAll(RegExp(r'\\(label|tag)\{[^{}]*\}'), '').replaceAll(RegExp(r'\\(nonumber|notag)\b'), '');
  t = t.replaceAll(r'\emph{', r'\textit{');
  // 中文不在 \text{} 里时包上（已在 \text… 参数里的不动）
  final b = StringBuffer();
  var i = 0;
  while (i < t.length) {
    final m = RegExp(r'\\(text|textrm|textbf|textit|texttt|mathrm|mbox|operatorname)\s*\{').matchAsPrefix(t, i);
    if (m != null) {
      final e = matchBrace(t, m.end - 1);
      if (e > 0) {
        b.write(t.substring(i, e + 1));
        i = e + 1;
        continue;
      }
    }
    final c = _cjkRun.matchAsPrefix(t, i);
    if (c != null) {
      b.write('\\text{${c[0]}}');
      i = c.end;
      continue;
    }
    b.write(t[i]);
    i++;
  }
  return b.toString().trim();
}

// ---------------------------------------------------------------- 环境

const _mathEnvs = {
  'equation', 'equation*', 'align', 'align*', 'alignat', 'alignat*', 'flalign', 'flalign*', 'gather', 'gather*',
  'multline', 'multline*', 'eqnarray', 'eqnarray*', 'displaymath', 'aligned', 'gathered', 'split', 'cases', 'matrix',
  'pmatrix', 'bmatrix', 'Bmatrix', 'vmatrix', 'Vmatrix', 'smallmatrix', 'array', 'dcases', 'rcases',
};
const _stripEnvs = {
  'center', 'flushleft', 'flushright', 'minipage', 'figure', 'figure*', 'table', 'table*', 'abstract', 'document',
  'small', 'footnotesize', 'large', 'raggedright', 'adjustbox', 'samepage',
};
const _quoteEnvs = {'quote', 'quotation', 'verse'};
const _listEnvs = {'itemize', 'enumerate', 'description', 'compactitem', 'compactenum', 'inparaenum'};
const _tableEnvs = {'tabular', 'tabular*', 'tabularx', 'longtable', 'tabulary'};

final _beginRe = RegExp(r'\\begin\s*\{([A-Za-z]+\*?)\}');

/// 找到与 [start] 处 \begin{name} 配对的 \end{name}，返回 (内容开始, 内容结束, 整体结束)。
(int, int, int)? _envSpan(String s, int start, String name) {
  final open = RegExp('\\\\begin\\s*\\{${RegExp.escape(name)}\\}');
  final close = RegExp('\\\\end\\s*\\{${RegExp.escape(name)}\\}');
  final first = open.matchAsPrefix(s, start);
  if (first == null) return null;
  var depth = 1, i = first.end;
  while (i < s.length) {
    final o = open.firstMatch(s.substring(i));
    final c = close.firstMatch(s.substring(i));
    if (c == null) return null;
    if (o != null && o.start < c.start) {
      depth++;
      i += o.end;
      continue;
    }
    depth--;
    if (depth == 0) return (first.end, i + c.start, i + c.end);
    i += c.end;
  }
  return null;
}

/// 在顶层（不在 {} 里）按 [sep] 切分。
List<String> _splitTop(String s, String sep) {
  final out = <String>[];
  var depth = 0, last = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '\\' && !s.startsWith(sep, i)) {
      i++;
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') depth--;
    if (depth == 0 && s.startsWith(sep, i)) {
      out.add(s.substring(last, i));
      i += sep.length - 1;
      last = i + 1;
    }
  }
  out.add(s.substring(last));
  return out;
}

String _list(String name, String body, int level) {
  final items = body.split(RegExp(r'\\item\b'));
  final lines = <String>[];
  var n = 0;
  final indent = '  ' * level;
  for (final raw in items.skip(1)) {
    var it = raw;
    var label = '';
    final opt = RegExp(r'^\s*\[([^\]\n]*)\]').firstMatch(it);
    if (opt != null) {
      label = opt[1]!.trim();
      it = it.substring(opt.end);
    }
    // 子列表已经转成缩进行；其余的换行并成一行
    final own = <String>[], nested = <String>[];
    for (final l in it.split('\n')) {
      if (RegExp(r'^\s+([-•]|\d+\.)\s').hasMatch(l) && l.startsWith('$indent  ')) {
        nested.add(l);
      } else if (l.trim().isNotEmpty) {
        (nested.isEmpty ? own : nested).add(nested.isEmpty ? l.trim() : l);
      }
    }
    n++;
    final text = own.join(' ');
    final marker = name == 'enumerate' || name == 'compactenum' || name == 'inparaenum' ? '$n.' : '-';
    final head = label.isNotEmpty && marker == '-' ? '${Mk.boldOpen}$label${Mk.boldClose} $text' : text;
    lines.add('$indent$marker ${head.isEmpty ? ' ' : head}'.trimRight());
    lines.addAll(nested);
  }
  final pre = items.first.trim();
  return '\n${pre.isEmpty ? '' : '$pre\n'}${lines.join('\n')}\n';
}

String _htmlEsc(String s) => s.replaceAll('<', Mk.lt);

String _tabular(String body) {
  var t = body.replaceAll(RegExp(r'\\(hline|toprule|midrule|bottomrule|endhead|endfirsthead|endfoot|endlastfoot)\b'), '');
  t = t.replaceAll(RegExp(r'\\(cline|cmidrule)(\([^)]*\))?\{[^{}]*\}'), '');
  final rows = _splitTop(t, r'\\').map((r) => r.replaceFirst(RegExp(r'^\s*\[[^\]]*\]'), '')).where((r) => r.trim().isNotEmpty);
  final b = StringBuffer('<table>');
  for (final r in rows) {
    b.write('<tr>');
    for (final cell in _splitTop(r, '&')) {
      var c = cell.trim();
      var span = 1;
      final mc = RegExp(r'^\\multicolumn\s*\{(\d+)\}').firstMatch(c);
      if (mc != null) {
        final spec = _arg(c, mc.end);
        final txt = spec == null ? null : _arg(c, spec.$2);
        if (txt != null) {
          span = int.tryParse(mc[1]!) ?? 1;
          c = txt.$1.trim();
        }
      }
      final mr = RegExp(r'^\\multirow\s*\{(\d+)\}\s*\{[^{}]*\}').firstMatch(c);
      var rs = 1;
      if (mr != null) {
        final txt = _arg(c, mr.end);
        if (txt != null) {
          rs = int.tryParse(mr[1]!) ?? 1;
          c = txt.$1.trim();
        }
      }
      b.write('<td${span > 1 ? ' colspan="$span"' : ''}${rs > 1 ? ' rowspan="$rs"' : ''}>${_htmlEsc(c).replaceAll('\n', ' ')}</td>');
    }
    b.write('</tr>');
  }
  b.write('</table>');
  return '\n\n$b\n\n';
}

/// 处理公式外的环境。[math] 用来追加新识别出的裸露数学环境。
String _envs(String s, List<TexSegment> math, int level) {
  if (!s.contains(r'\begin')) return s;
  final out = StringBuffer();
  var pos = 0;
  while (true) {
    final m = _beginRe.firstMatch(s.substring(pos));
    if (m == null) break;
    final start = pos + m.start;
    final name = m[1]!;
    final span = _envSpan(s, start, name);
    if (span == null) {
      // 不配对：原样保留这个 \begin，继续往后找
      out.write(s.substring(pos, pos + m.end));
      pos += m.end;
      continue;
    }
    out.write(s.substring(pos, start));
    final whole = s.substring(start, span.$3);
    var body = s.substring(span.$1, span.$2);
    String rep;
    if (_mathEnvs.contains(name)) {
      if (whole.contains(_ph) || whole.contains(_codeTok)) {
        rep = whole; // 里面混有公式或代码：不确定，原样保留
      } else {
        math.add(TexSegment(repairTex(whole), isMath: true, display: true));
        rep = '\n$_ph${math.length - 1}$_ph\n';
      }
    } else if (_listEnvs.contains(name)) {
      body = body.replaceFirst(RegExp(r'^\s*\[[^\]\n]*\]'), '');
      rep = _list(name, _envs(body, math, level + 1), level);
    } else if (_tableEnvs.contains(name)) {
      var i = 0;
      if (name == 'tabular*' || name == 'tabularx' || name == 'tabulary') i = _arg(body, 0)?.$2 ?? 0;
      i = _skipOpt(body, i);
      final spec = _arg(body, i);
      rep = _tabular(_envs(spec == null ? body : body.substring(spec.$2), math, level));
    } else if (_stripEnvs.contains(name)) {
      var i = _skipOpt(body, 0);
      if (name == 'minipage') i = _arg(body, i)?.$2 ?? i;
      rep = '\n${_envs(body.substring(i), math, level)}\n';
    } else if (_quoteEnvs.contains(name)) {
      rep = '\n${_envs(body, math, level).trim().split('\n').map((l) => '> ${l.trim()}').join('\n')}\n';
    } else {
      rep = whole; // 不认识的环境原样显示
    }
    out.write(rep);
    pos = span.$3;
  }
  out.write(s.substring(pos));
  return out.toString();
}

// ---------------------------------------------------------------- 文本命令

const _knownN = {'nabla', 'neq', 'ne', 'newline', 'noindent', 'nu', 'not', 'ni', 'neg', 'newpage', 'nolinebreak',
  'nonumber', 'normalsize', 'notag', 'nexists', 'nleq', 'ngeq', 'nmid', 'nparallel', 'nsubseteq', 'newcommand'};
const _escapes = {'_': Mk.underscore, '%': '%', '&': Mk.amp, '#': Mk.hash, '{': '{', '}': '}', '\$': '\$', ' ': ' '};

/// 转换文本命令。[styles] 是外层已有的样式，同类嵌套只保留一层。
String _commands(String s, {Set<String> styles = const {}}) {
  if (!s.contains('\\') && !s.contains('``')) return s;
  final b = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c != '\\' || i + 1 >= s.length) {
      b.write(c);
      i++;
      continue;
    }
    final n = s[i + 1];
    // \\ 换行（可带 [2pt] 间距）
    if (n == '\\') {
      b.write('\n');
      i = _skipOpt(s, i + 2);
      continue;
    }
    if (_escapes.containsKey(n)) {
      b.write(_escapes[n]);
      i += 2;
      continue;
    }
    final name = RegExp(r'[A-Za-z]+').matchAsPrefix(s, i + 1)?[0];
    if (name == null) {
      b.write(c);
      i++;
      continue;
    }
    final after = i + 1 + name.length;
    // 字面量 \n（OCR / 模型输出里常见），但不误伤 \nabla \neq 等命令
    if (name.startsWith('n') && !_knownN.contains(name)) {
      b.write('\n');
      i += 2;
      continue;
    }
    if (name == 'newline') {
      b.write('\n');
      i = after;
      continue;
    }
    if (const {'noindent', 'centering', 'par', 'medskip', 'bigskip', 'smallskip', 'newpage', 'clearpage', 'raggedright', 'quad', 'qquad'}
        .contains(name)) {
      b.write(name == 'par' ? '\n\n' : name.endsWith('quad') ? ' ' : '');
      i = after;
      while (name != 'par' && name != 'quad' && name != 'qquad' && i < s.length && s[i] == ' ') {
        i++;
      }
      continue;
    }
    if (name == 'verb' && after < s.length && !RegExp(r'[A-Za-z\s*]').hasMatch(s[after])) {
      final d = s[after];
      final e = s.indexOf(d, after + 1);
      if (e > after && !s.substring(after + 1, e).contains('\n')) {
        b.write('${Mk.codeOpen}${_lit(s.substring(after + 1, e))}${Mk.codeClose}');
        i = e + 1;
        continue;
      }
    }
    if (const {'label', 'index', 'vspace', 'hspace', 'vspace*', 'hspace*', 'footnotemark'}.contains(name)) {
      final a = _arg(s, after);
      if (a != null) {
        i = a.$2;
        continue;
      }
    }
    final style = switch (name) {
      'texttt' => 'code',
      'textbf' => 'bold',
      'textit' || 'emph' || 'textsl' => 'it',
      'underline' || 'uline' => 'ul',
      'text' || 'textrm' || 'textsf' || 'mathrm' || 'textnormal' || 'mbox' || 'textup' || 'caption' || 'footnote' ||
      'section' || 'subsection' || 'subsubsection' || 'paragraph' || 'title' => 'plain',
      _ => null,
    };
    if (style != null) {
      final a = _arg(s, after);
      if (a == null) {
        // 参数缺失或括号不配对：原样显示
        b.write(s.substring(i, after));
        i = after;
        continue;
      }
      final heading = const {'section': '## ', 'subsection': '### ', 'subsubsection': '#### '}[name];
      if (heading != null) {
        b.write('\n$heading${_commands(a.$1, styles: styles)}\n');
      } else if (name == 'footnote') {
        b.write('（${_commands(a.$1, styles: styles)}）');
      } else if (style == 'code') {
        b.write('${Mk.codeOpen}${_lit(_plainArg(a.$1))}${Mk.codeClose}');
      } else if (style == 'plain' || styles.contains(style)) {
        b.write(_commands(a.$1, styles: styles));
      } else {
        final (o, cl) = switch (style) {
          'bold' => (Mk.boldOpen, Mk.boldClose),
          'it' => (Mk.itOpen, Mk.itClose),
          _ => (Mk.ulOpen, Mk.ulClose),
        };
        final inner = _commands(a.$1, styles: {...styles, style});
        b.write(inner.trim().isEmpty ? inner : '$o$inner$cl');
      }
      i = a.$2;
      continue;
    }
    // 不认识的命令：原样显示
    b.write(s.substring(i, after));
    i = after;
  }
  return b.toString();
}

/// 代码样式的参数：展开转义和嵌套命令，去掉样式（代码里只显示文字）。
String _plainArg(String s) => _commands(s).replaceAll(Mk._all, '').replaceAll('\n', ' ');

/// 代码文字里的字面字符也用标记，避免被当成 Markdown。
String _lit(String s) => s.replaceAll('`', Mk.backtick).replaceAll('<', Mk.lt);

// ---------------------------------------------------------------- 入口

final _fence = RegExp(r'^[ \t]*(```+|~~~+)[^\n`]*\n([\s\S]*?)\n[ \t]*\1[ \t]*$', multiLine: true);
final _inlineCode = RegExp(r'`[^`\n]+`');

/// 显示前的 LaTeX 文本整理。[s] 中公式已是占位符；[math] 可追加新公式；[codeBlocks] 收集代码块原文。
String prepareLatexText(String s, List<TexSegment> math, List<String> codeBlocks) {
  // 1. 成对的 ``` 代码块：整块取出，里面什么都不转换（公式占位符还原成源码）
  var t = s;
  if (t.contains('```') || t.contains('~~~')) {
    t = t.replaceAllMapped(_fence, (m) {
      final code = m[2]!.replaceAllMapped(RegExp('$_ph(\\d+)$_ph'), (p) {
        final k = int.parse(p[1]!);
        return k < math.length ? math[k].toString() : '';
      });
      codeBlocks.add(code);
      return '\n$codeBlockTok${codeBlocks.length - 1}$codeBlockTok\n';
    });
  }
  final hasLatex = t.contains('\\');
  if (!hasLatex) return t;
  // 2. 行内代码（同一行内成对的反引号）保护起来
  final codes = <String>[];
  t = t.replaceAllMapped(_inlineCode, (m) {
    codes.add(m[0]!);
    return '$_codeTok${codes.length - 1}$_codeTok';
  });
  // 3. 环境 → 列表 / 表格 / 去掉外壳 / 独立公式
  t = _envs(t, math, 0);
  // 4. 文本命令、转义、换行
  t = _commands(t);
  return t.replaceAllMapped(RegExp('$_codeTok(\\d+)$_codeTok'), (m) => codes[int.parse(m[1]!)]);
}
