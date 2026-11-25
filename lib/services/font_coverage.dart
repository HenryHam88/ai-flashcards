import 'dart:typed_data';

/// 读 TrueType 字体的 cmap 表，判断哪些字字体里没有（导出 PDF 前提醒，避免出现空白或方框）。
class FontCoverage {
  final Set<int> _codes;
  FontCoverage._(this._codes);

  bool has(int code) => _codes.contains(code);
  int get length => _codes.length;

  /// 解析失败时返回 null（调用方当作「不检查」）。
  static FontCoverage? parse(Uint8List bytes) {
    try {
      final d = ByteData.sublistView(bytes);
      final n = d.getUint16(4);
      int? cmap;
      for (var i = 0; i < n; i++) {
        final r = 12 + i * 16;
        if (String.fromCharCodes(bytes.sublist(r, r + 4)) == 'cmap') cmap = d.getUint32(r + 8);
      }
      if (cmap == null) return null;
      final codes = <int>{};
      final tables = d.getUint16(cmap + 2);
      for (var i = 0; i < tables; i++) {
        final off = cmap + d.getUint32(cmap + 4 + i * 8 + 4);
        final format = d.getUint16(off);
        if (format == 4) {
          final segX2 = d.getUint16(off + 6);
          final ends = off + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2;
          for (var s = 0; s < segX2 ~/ 2; s++) {
            final end = d.getUint16(ends + s * 2), start = d.getUint16(starts + s * 2);
            final delta = d.getInt16(deltas + s * 2), ro = d.getUint16(ranges + s * 2);
            for (var c = start; c <= end && c != 0xFFFF; c++) {
              int g;
              if (ro == 0) {
                g = (c + delta) & 0xFFFF;
              } else {
                final p = ranges + s * 2 + ro + (c - start) * 2;
                g = d.getUint16(p);
                if (g != 0) g = (g + delta) & 0xFFFF;
              }
              if (g != 0) codes.add(c);
            }
          }
        } else if (format == 12) {
          final groups = d.getUint32(off + 12);
          for (var k = 0; k < groups; k++) {
            final g = off + 16 + k * 12;
            final start = d.getUint32(g), end = d.getUint32(g + 4), gid = d.getUint32(g + 8);
            for (var c = start; c <= end; c++) {
              if (gid + (c - start) != 0) codes.add(c);
            }
          }
        }
      }
      return codes.isEmpty ? null : FontCoverage._(codes);
    } catch (_) {
      return null;
    }
  }

  /// 公式（$...$、$$...$$、\(...\)、\[...\]）会转成图片，不用字体；去掉后再检查。
  static String withoutMath(String s) => s
      .replaceAll(RegExp(r'\$\$[\s\S]*?\$\$'), ' ')
      .replaceAll(RegExp(r'(?<!\\)\$[^$\n]+?\$'), ' ')
      .replaceAll(RegExp(r'\\\([\s\S]*?\\\)'), ' ')
      .replaceAll(RegExp(r'\\\[[\s\S]*?\\\]'), ' ');

  /// 字体里没有的字（去重、按出现顺序），空白和控制字符不算。
  List<String> missing(Iterable<String> texts, {int max = 30}) {
    final out = <int>{};
    for (final t in texts) {
      for (final r in withoutMath(t).runes) {
        if (r < 0x20 || r == 0x7F || (r >= 0xFE00 && r <= 0xFE0F) || r == 0x200B || r == 0x200D || r == 0xFEFF) continue;
        if (String.fromCharCode(r).trim().isEmpty) continue;
        if (!_codes.contains(r)) out.add(r);
        if (out.length >= max) break;
      }
    }
    return [for (final r in out) String.fromCharCode(r)];
  }
}
