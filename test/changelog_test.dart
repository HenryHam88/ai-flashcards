import 'dart:io';

import 'package:ai_flashcards/theme/html_clean.dart';
import 'package:ai_flashcards/theme/rich_text.dart';
import 'package:ai_flashcards/ui/settings_pages.dart' show changelogForDisplay;
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final raw = File('CHANGELOG.md').readAsStringSync();
  final shown = changelogForDisplay(raw);
  final doc = MdMath.parse(shown);

  group('更新日志（应用内显示）', () {
    test('每个版本都显示成「v版本  ·  日期」标题，没有被吞进表格或代码块', () {
      final versions = RegExp(r'^## \[(\d+\.\d+\.\d+)\] - (\S+)$', multiLine: true).allMatches(raw).toList();
      expect(versions.length, greaterThanOrEqualTo(14));
      final headings = [for (final b in doc.blocks) if (b.type == MdBlockType.heading && b.level == 2) b.text];
      expect(headings, [for (final m in versions) 'v${m[1]}  ·  ${m[2]}']);
      expect(headings.first, startsWith('v1.6.0'));
      expect(shown.contains('[Unreleased]'), isFalse);
      expect(shown.contains('https://github.com/HenryHam88/ai-flashcards/compare'), isFalse);
    });

    test('没有公式、表格、代码框；列表层级和源文件一致', () {
      expect(doc.math, isEmpty);
      expect(doc.tables, isEmpty);
      expect(doc.codeBlocks, isEmpty);
      final src = shown.split('\n');
      final top = src.where((l) => l.startsWith('- ')).length;
      final sub = src.where((l) => l.startsWith('  - ')).length;
      expect(doc.blocks.where((b) => b.type == MdBlockType.bullet && b.level == 0).length, top);
      expect(doc.blocks.where((b) => b.type == MdBlockType.bullet && b.level == 1).length, sub);
      // 除了 1.1.7 的「首个公开版本。」，没有游离在列表外的段落
      final paras = doc.blocks.where((b) => b.type == MdBlockType.paragraph).map((b) => b.text).toList();
      expect(paras, ['首个公开版本。']);
    });

    test('v1.3.3 的子项仍是二级列表；v1.3.4 的说明是完整的一条', () {
      final b = doc.blocks.firstWhere((b) => b.text.startsWith('支持表头'));
      expect(b.type, MdBlockType.bullet);
      expect(b.level, 1);
      final last = doc.blocks.firstWhere((b) => b.text.startsWith('只改显示：保存的内容'));
      expect(last.type, MdBlockType.bullet);
      expect(last.text, endsWith('显示完全不变。'));
    });

    test('1.6.0 的条目完整显示', () {
      final i = doc.blocks.indexWhere((b) => b.type == MdBlockType.heading && b.text.startsWith('v1.6.0'));
      final j = doc.blocks.indexWhere((b) => b.type == MdBlockType.heading && b.text.startsWith('v1.5.0'));
      final part = doc.blocks.sublist(i + 1, j);
      expect(part.where((b) => b.type == MdBlockType.heading).map((b) => b.text), ['新增', '修复']);
      expect(part.any((b) => b.text.contains('分析未分析的章节')), isTrue);
      expect(part.any((b) => b.text.contains('常用提示词')), isTrue);
      expect(part.any((b) => b.text.contains('昵称')), isTrue);
      expect(part.any((b) => b.text.contains('服务商') && b.text.contains('名字')), isTrue);
      expect(part.any((b) => b.text.contains('测试')), isTrue);
      expect(part.every((b) => b.type == MdBlockType.heading || b.type == MdBlockType.bullet), isTrue);
    });

    test('1.5.0 的条目完整显示', () {
      final i = doc.blocks.indexWhere((b) => b.type == MdBlockType.heading && b.text.startsWith('v1.5.0'));
      final j = doc.blocks.indexWhere((b) => b.type == MdBlockType.heading && b.text.startsWith('v1.4.1'));
      final part = doc.blocks.sublist(i + 1, j);
      expect(part.where((b) => b.type == MdBlockType.heading).map((b) => b.text), ['新增']);
      expect(part.any((b) => b.text.contains('Ctrl+K')), isTrue);
      expect(part.where((b) => b.type == MdBlockType.bullet && b.level == 0).length, 8);
      expect(part.every((b) => b.type == MdBlockType.heading || b.type == MdBlockType.bullet), isTrue);
    });

    test('1.4.1 的条目完整显示', () {
      final i = doc.blocks.indexWhere((b) => b.type == MdBlockType.heading && b.text.startsWith('v1.4.1'));
      final j = doc.blocks.indexWhere((b) => b.type == MdBlockType.heading && b.text.startsWith('v1.4.0'));
      final part = doc.blocks.sublist(i + 1, j);
      expect(part.where((b) => b.type == MdBlockType.heading).map((b) => b.text), ['新增', '修复']);
      expect(part.any((b) => b.text.contains('导出到 Obsidian / Notion')), isTrue);
      expect(part.any((b) => b.text.contains('错题.csv')), isTrue);
      expect(part.every((b) => b.type == MdBlockType.heading || b.type == MdBlockType.bullet), isTrue);
    });

    testWidgets('整页渲染：标题不带井号，没有公式部件', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: MathText(shown, style: const TextStyle(fontSize: 14))))));
      expect(find.byType(Math), findsNothing);
      final all = t.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('\n');
      expect(all.contains('## '), isFalse);
      expect(all.contains('v1.3.3  ·  2026-11-21'), isTrue);
      expect(all.contains('v1.1.7  ·  2026-11-20'), isTrue);
      expect(t.takeException(), isNull);
    });
  });

  group('代码里的公式写法和 HTML 标签只是文字', () {
    test(r'行内代码里的 \( \[ $ 不当公式，也不拆开列表', () {
      final d = MdMath.parse(r'- 公式（包括 `\(…\)` 和 `\[…\]`）显示完全不变。' '\n' r'- 价格 `$5` 和 `$10`');
      expect(d.math, isEmpty);
      expect(d.blocks.map((b) => b.type), [MdBlockType.bullet, MdBlockType.bullet]);
      expect(d.blocks.first.text, contains(r'`\(…\)`'));
    });

    test('代码块里的公式原样保留，代码块外的公式照常排版', () {
      final d = MdMath.parse('前面 \$x^2\$\n\n```\nprint("\$a\$")\n\\[b\\]\n```\n\n后面 \\(y\\)');
      expect(d.math.map((m) => m.text), ['x^2', 'y']);
      expect(d.codeBlocks.single, 'print("\$a\$")\n\\[b\\]');
    });

    test('普通公式不受影响：\\( \\) 和 \\[ \\] 仍是公式', () {
      final d = MdMath.parse(r'行内 \(a+b\) 和独立 \[c\]');
      expect(d.math.map((m) => (m.text, m.display)), [('a+b', false), ('c', true)]);
    });

    test('反引号里的 <table> 不当表格，后面的列表照常显示', () {
      final d = MdMath.parse('- 以 `<table><tr><td>…` 原始标签显示\n  - 子项一\n  - 子项二\n\n## 下一节');
      expect(d.tables, isEmpty);
      expect(d.blocks.map((b) => (b.type, b.level)).toList(), [
        (MdBlockType.bullet, 0),
        (MdBlockType.bullet, 1),
        (MdBlockType.bullet, 1),
        (MdBlockType.heading, 2),
      ]);
    });

    test('没写完的 <table> 不会吞掉空行之后的内容', () {
      final out = cleanForDisplay('<table><tr><td>1</td><td>2</td></tr>\n\n## 后面的标题\n\n正文', table: (t) => '[表格:${t.rows.length}]');
      expect(out, contains('[表格:1]'));
      expect(out, contains('## 后面的标题'));
      expect(out, contains('正文'));
      // 流式输出时只有半张表：照样当表格
      expect(cleanForDisplay('<table><tr><td>a<td>b', table: (t) => '[表格:${t.rows.length}]'), contains('[表格:1]'));
    });

    test('完整的 HTML 表格照常识别', () {
      final d = MdMath.parse('前\n<table><tr><td>\$x\$</td><td>2</td></tr></table>\n后');
      expect(d.tables.length, 1);
      expect(d.math.single.text, 'x');
    });
  });
}
