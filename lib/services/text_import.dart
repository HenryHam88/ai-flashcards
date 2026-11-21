/// TXT 资料：在手机上直接读取（不联网、不花钱）。识别编码、清理控制字符、按段落切成「小节」。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show GbkCodec;

/// 超过这个大小的 TXT 上传时提醒（解析和出题会比较慢）。
const txtWarnBytes = 10 * 1024 * 1024;

/// 解码结果：文字和识别出的编码名称（UTF-8 / UTF-8 BOM / UTF-16LE / UTF-16BE / GBK）。
class DecodedText {
  final String text;
  final String encoding;
  const DecodedText(this.text, this.encoding);
}

String _utf16(Uint8List b, int start, bool little) {
  final units = <int>[];
  for (var i = start; i + 1 < b.length; i += 2) {
    units.add(little ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }
  // 不成对的代理项替换掉，避免生成非法字符串
  final out = StringBuffer();
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF && i + 1 < units.length && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF) {
      out.writeCharCode(0x10000 + ((u - 0xD800) << 10) + (units[i + 1] - 0xDC00));
      i++;
    } else if (u >= 0xD800 && u <= 0xDFFF) {
      out.writeCharCode(0xFFFD);
    } else {
      out.writeCharCode(u);
    }
  }
  return out.toString();
}

/// 没有 BOM 的 UTF-16：英文 / 数字多时，奇数或偶数位置有大量 0 字节。
String? _guessUtf16(Uint8List b) {
  if (b.length < 4) return null;
  final n = b.length > 4096 ? 4096 : b.length - b.length % 2;
  var evenZero = 0, oddZero = 0;
  for (var i = 0; i + 1 < n; i += 2) {
    if (b[i] == 0) evenZero++;
    if (b[i + 1] == 0) oddZero++;
  }
  final pairs = n ~/ 2;
  if (oddZero > pairs * 0.3 && evenZero < pairs * 0.05) return 'UTF-16LE';
  if (evenZero > pairs * 0.3 && oddZero < pairs * 0.05) return 'UTF-16BE';
  return null;
}

/// 识别编码并解码：BOM（UTF-8 / UTF-16LE / UTF-16BE）→ 合法 UTF-8 → 无 BOM 的 UTF-16 → GBK（兼容 GB2312）。
DecodedText decodeTextBytes(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
    return DecodedText(utf8.decode(b.sublist(3), allowMalformed: true), 'UTF-8 BOM');
  }
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) return DecodedText(_utf16(b, 2, true), 'UTF-16LE');
  if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) return DecodedText(_utf16(b, 2, false), 'UTF-16BE');
  final u16 = _guessUtf16(b);
  if (u16 != null) return DecodedText(_utf16(b, 0, u16 == 'UTF-16LE'), u16);
  try {
    return DecodedText(utf8.decode(b), 'UTF-8');
  } on FormatException {
    // 不是合法 UTF-8：中文 Windows 记事本的默认编码 GBK
  }
  try {
    return DecodedText(const GbkCodec(allowMalformed: true).decode(b), 'GBK');
  } catch (_) {
    return DecodedText(utf8.decode(b, allowMalformed: true), 'UTF-8');
  }
}

/// 统一换行，去掉 NUL、BOM 和其它控制字符（保留换行和 Tab），去掉行尾空白。
String cleanImportedText(String s) {
  var t = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  t = t.replaceAll(RegExp('[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\uFEFF\uE7B3]'), '');
  t = t.replaceAll(RegExp(r'[ \t\u3000]+\n'), '\n').replaceAll(RegExp(r'\n{4,}'), '\n\n\n');
  return t.trim();
}

final _chapterHead = RegExp(
    r'^\s{0,3}(#{1,2}\s+\S|第\s*[一二三四五六七八九十百零〇两\d]+\s*[章篇讲部编]|(chapter|lecture|unit|part)\s+[\dIVXLC]+\b)',
    caseSensitive: false);

/// 是否是章级标题行（新的一章从新的一节开始，分章更准）。
bool isTxtChapterHeading(String line) => line.trim().length < 60 && _chapterHead.hasMatch(line);

/// 在 [max] 之内找一个合适的断开位置：优先句末标点，其次逗号 / 空格，都没有就直接断（不拆开代理对）。
int _cut(String s, int target, int max) {
  if (s.length <= max) return s.length;
  for (final re in [RegExp(r'[。！？!?；;…]'), RegExp(r'[，,、：:\s]')]) {
    for (var i = max - 1; i >= target ~/ 2; i--) {
      if (re.hasMatch(s[i])) return i + 1;
    }
  }
  var i = max;
  final c = s.codeUnitAt(i - 1);
  if (c >= 0xD800 && c <= 0xDBFF) i--;
  return i;
}

/// 把整份文字切成「小节」（虚拟页）：约 [target] 字一节，在段落之间断开；
/// 章标题（第X章、# 标题）总是开始新的一节；没有换行的超长段落按句子断开，每节不超过 [max] 字。
List<String> splitTextPages(String text, {int target = 1800, int max = 2400}) {
  final out = <String>[];
  final buf = StringBuffer();
  void flush() {
    final t = buf.toString().trim();
    if (t.isNotEmpty) out.add(t);
    buf.clear();
  }

  for (var line in text.split('\n')) {
    if (isTxtChapterHeading(line) && buf.toString().trim().isNotEmpty) flush();
    // 超长行：先把能放下的部分放进当前节，其余按句子切开
    while (buf.length + line.length > max) {
      final room = max - buf.length;
      if (room < target ~/ 3 && buf.isNotEmpty) {
        flush();
        continue;
      }
      final k = _cut(line, (target - buf.length).clamp(1, room), room);
      buf.write(line.substring(0, k));
      flush();
      line = line.substring(k).trimLeft();
    }
    buf.writeln(line);
    // 到了目标长度：优先在段落之间（空行）断开；段落很长时在行尾断开
    if ((buf.length >= target && line.trim().isEmpty) || buf.length >= (target + max) ~/ 2) flush();
  }
  flush();
  return out;
}
