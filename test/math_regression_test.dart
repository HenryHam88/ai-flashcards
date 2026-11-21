import 'dart:convert';
import 'dart:io';

import 'package:ai_flashcards/theme/rich_text.dart';
import 'package:flutter_test/flutter_test.dart';

import 'math_corpus.dart';

/// 公式不回归：所有现有示例经过渲染器解析出的公式片段，必须与修改前（v1.3.3）逐字节一致。
/// 基准文件由 v1.3.3 的代码生成：UPDATE_MATH_FIXTURE=1 flutter test test/math_regression_test.dart
void main() {
  test('现有示例的公式片段与 v1.3.3 完全一致', () async {
    final corpus = await mathCorpus();
    final now = {
      for (final e in corpus.entries) e.key: [for (final m in MdMath.parse(e.value).math) '${m.display ? 'D' : 'I'}:${m.text}']
    };
    final f = File('test/fixtures/math_segments.json');
    if (Platform.environment['UPDATE_MATH_FIXTURE'] == '1') {
      f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(now));
    }
    final before = (jsonDecode(f.readAsStringSync()) as Map).map((k, v) => MapEntry(k as String, (v as List).cast<String>()));
    expect(now.keys.toSet(), before.keys.toSet(), reason: '语料变化，请检查');
    var formulas = 0;
    for (final k in corpus.keys) {
      expect(now[k], before[k], reason: k);
      formulas += before[k]!.length;
    }
    expect(formulas, greaterThan(80));
  });
}
