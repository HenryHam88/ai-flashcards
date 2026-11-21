import 'package:flutter_math_fork/tex.dart';

/// 文本片段：普通文字或公式（行内 / 独立成行）。
class TexSegment {
  final String text;
  final bool isMath;
  final bool display;
  const TexSegment(this.text, {this.isMath = false, this.display = false});
  @override
  String toString() => isMath ? (display ? '\$\$$text\$\$' : '\$$text\$') : text;
  @override
  bool operator ==(Object other) =>
      other is TexSegment && other.text == text && other.isMath == isMath && other.display == display;
  @override
  int get hashCode => Object.hash(text, isMath, display);
}

class LatexUtil {
  /// 统一分隔符：\[..\] → $$..$$，\(..\) → $..$。
  static String normalize(String s) {
    var r = s.replaceAllMapped(RegExp(r'\\\[([\s\S]+?)\\\]'), (m) => '\$\$${m[1]}\$\$');
    r = r.replaceAllMapped(RegExp(r'\\\(([\s\S]+?)\\\)'), (m) => '\$${m[1]}\$');
    return r;
  }

  /// 把混排文本拆成文字与公式片段。支持 \$ 转义。
  static List<TexSegment> split(String input) {
    final s = normalize(input);
    final out = <TexSegment>[];
    final buf = StringBuffer();
    var i = 0;
    void flushText() {
      if (buf.isNotEmpty) {
        out.add(TexSegment(buf.toString()));
        buf.clear();
      }
    }

    while (i < s.length) {
      final c = s[i];
      if (c == '\\' && i + 1 < s.length && s[i + 1] == '\$') {
        buf.write('\$');
        i += 2;
        continue;
      }
      if (c == '\$') {
        final display = i + 1 < s.length && s[i + 1] == '\$';
        final open = display ? 2 : 1;
        final closeTok = display ? '\$\$' : '\$';
        var j = i + open;
        var end = -1;
        while (j < s.length) {
          if (s[j] == '\\') {
            j += 2;
            continue;
          }
          if (s.startsWith(closeTok, j)) {
            end = j;
            break;
          }
          j++;
        }
        if (end < 0) {
          // 未闭合：当作普通文字
          buf.write(s.substring(i));
          break;
        }
        flushText();
        final body = s.substring(i + open, end).trim();
        if (body.isNotEmpty) out.add(TexSegment(body, isMath: true, display: display));
        i = end + open;
        continue;
      }
      buf.write(c);
      i++;
    }
    flushText();
    return out;
  }

  /// 单个公式能否被排版引擎解析。
  static String? parseError(String tex) {
    try {
      TexParser(tex, const TexParserSettings()).parse();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 检查整段文本：分隔符成对、每个公式可解析、公式外没有裸露的 LaTeX/上标写法。
  /// 返回问题列表，空列表表示合格。
  static List<String> validate(String input) {
    final problems = <String>[];
    final s = normalize(input);
    // 去掉转义的 \$ 后统计 $ 数量
    final dollars = s.replaceAll(r'\$', '').split('').where((c) => c == '\$').length;
    if (dollars.isOdd) problems.add('公式分隔符 \$ 不成对');
    for (final seg in split(s)) {
      if (seg.isMath) {
        final err = parseError(seg.text);
        if (err != null) problems.add('无法解析公式: ${seg.text}');
      } else if (looksLikeRawMath(seg.text)) {
        problems.add('公式未用 \$ 包裹: ${seg.text.trim()}');
      }
    }
    return problems;
  }

  static final _rawMath = RegExp(
      r'\\(frac|int|sum|sqrt|lim|alpha|beta|lambda|sigma|mu|theta|infty|cdot|times|leq|geq|neq|partial|mathbb|mathrm|left|right|begin)\b|[A-Za-z0-9\)]\^[\{A-Za-z0-9]|[A-Za-z]_\{');

  static bool looksLikeRawMath(String text) => _rawMath.hasMatch(text);

  /// 尽量修复轻微问题：把裸露的 LaTeX 命令包上 $。不能修复时原样返回。
  static String autoFix(String input) {
    if (validate(input).isEmpty) return input;
    final segs = split(input);
    final b = StringBuffer();
    for (final seg in segs) {
      if (!seg.isMath && looksLikeRawMath(seg.text)) {
        // 以中文/全角标点为界，把含公式的 ASCII 段落包起来
        b.write(seg.text.replaceAllMapped(RegExp(r'[\x21-\x7E][\x20-\x7E]*[\x21-\x7E]|[\x21-\x7E]'), (m) {
          final t = m[0]!;
          return looksLikeRawMath(t) && parseError(t) == null ? '\$$t\$' : t;
        }));
      } else {
        b.write(seg.toString());
      }
    }
    return b.toString();
  }
}
