import 'dart:convert';

/// 从模型输出中稳健地解析 JSON：去掉 ```json 代码块、前后杂质，截取第一个完整对象。
Map<String, dynamic> parseModelJson(String raw) {
  var s = fixLatexEscapes(raw.trim());
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(s);
  if (fence != null) s = fence.group(1)!.trim();
  try {
    final v = jsonDecode(s);
    if (v is Map<String, dynamic>) return v;
    if (v is List) return {'items': v};
  } catch (_) {}
  final start = s.indexOf('{');
  if (start < 0) throw const FormatException('没有找到 JSON 对象');
  var depth = 0;
  var inStr = false;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (inStr) {
      if (c == '\\') {
        i++;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') inStr = true;
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) {
        return jsonDecode(s.substring(start, i + 1)) as Map<String, dynamic>;
      }
    }
  }
  throw const FormatException('JSON 不完整');
}

List<Map<String, dynamic>> listOfMaps(dynamic v) =>
    v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const [];

int asInt(dynamic v, [int def = 0]) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? def);

/// 模型常把 LaTeX 的反斜杠写成单个（如 "\frac"），在 JSON 里会被当成 \f 转义。
/// 这里把「反斜杠 + 两个以上字母」（\uXXXX 除外）以及非法转义统一加倍。
String fixLatexEscapes(String s) {
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
    if (n == '\\') {
      b.write('\\\\');
      i += 2;
      continue;
    }
    final rest = s.substring(i + 1);
    final isUnicode = RegExp(r'^u[0-9a-fA-F]{4}').hasMatch(rest);
    final word = RegExp(r'^[a-zA-Z]{2,}').hasMatch(rest);
    final validEscape = '"/bfnrtu'.contains(n);
    if (!isUnicode && (word || !validEscape)) {
      b.write('\\\\');
    } else {
      b.write('\\');
    }
    i++;
  }
  return b.toString();
}
