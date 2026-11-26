import 'dart:convert';
import 'dart:io';

import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/services/kb_export.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kb_fixture.dart';

void main() {
  late Repository repo;
  late Directory dir;
  late Map<String, File> files;
  late KbExportService svc;

  setUp(() async {
    repo = Repository(MemoryDocStore());
    dir = Directory.systemTemp.createTempSync('afc_kb');
    files = await seedKbData(repo, dir);
    svc = KbExportService(repo: repo, media: (id) async => files[id], now: () => DateTime(2026, 11, 26, 8, 5));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, ArchiveFile> unzip(KbExportResult r) {
    final a = ZipDecoder().decodeBytes(r.bytes);
    return {for (final f in a.files) if (f.isFile) f.name: f};
  }

  String text(ArchiveFile f) => utf8.decode(f.content);
  String find(Map<String, ArchiveFile> z, String prefix) => z.keys.firstWhere((k) => k.startsWith(prefix), orElse: () => '(没有 $prefix)');

  test('压缩包结构：根文件夹、按类型 / 项目分文件夹、使用说明、错题表格、附件', () async {
    final r = await svc.export(const KbExportOptions());
    expect(r.fileName, '闪卡刷题导出-2026-11-26.zip');
    final z = unzip(r);
    const root = '闪卡刷题导出-2026-11-26';
    expect(z.keys.every((k) => k.startsWith('$root/')), isTrue);
    expect(z.keys, contains('$root/使用说明.md'));
    expect(z.keys, contains('$root/错题/错题.csv'));
    expect(find(z, '$root/笔记/概率论 第3章/条件概率 P(A B) 怎么理解-'), endsWith('.md'));
    expect(find(z, '$root/AI伴学/概率论 第3章/全概率公式和贝叶斯的区别-'), endsWith('.md'));
    expect(find(z, '$root/AI解释/常微分方程/下列哪个是一阶线性微分方程？-'), endsWith('.md'));
    expect(find(z, '$root/收藏/概率论 第3章/知识点/条件概率-'), endsWith('.md'));
    expect(find(z, '$root/收藏/概率论 第3章/闪卡/'), endsWith('.md'));
    expect(find(z, '$root/错题/常微分方程/'), endsWith('.md'));
    expect(z.keys.where((k) => k.startsWith('$root/附件/')).length, 3); // 笔记照片 + 伴学图片 + 伴学讲义
    expect(r.missingFiles, 1); // photo_missing 不在本机
    // 没有隐藏文件（Notion 导入会失败）
    expect(z.keys.any((k) => k.split('/').any((s) => s.startsWith('.'))), isFalse);
    expect(r.paths.toSet(), z.keys.toSet());
  });

  test('笔记：YAML 属性 + 可见信息列表，公式保持 \$ 写法，照片用相对路径', () async {
    final z = unzip(await svc.export(const KbExportOptions()));
    final md = text(z[find(z, '闪卡刷题导出-2026-11-26/笔记/')]!);
    expect(md, startsWith('---\ntitle: "条件概率: \$P(A|B)\$ 怎么理解?"\ntype: "笔记"\n'));
    expect(md, contains('project: "概率论 第3章"'));
    expect(md, contains('created: "2026-11-25T21:30:00"'));
    expect(md, contains('tags:\n  - "闪卡刷题"\n  - "笔记"'));
    expect(md, contains('id: "n1"'));
    expect(md, contains('\n---\n\n# 条件概率: \$P(A|B)\$ 怎么理解?\n\n- 项目：概率论 第3章\n- 章节：第一章 随机事件与概率\n- 知识点：条件概率\n'));
    expect(md, contains(r'$$P(A\mid B)=\frac{P(AB)}{P(B)}$$'));
    expect(md, contains('## 我的理解'));
    expect(md, contains('**参考网页**\n\n1. [条件概率 - 维基百科](https://zh.wikipedia.org/wiki/条件概率)'));
    expect(md, contains('> 称 P(A|B) 为在事件 B 发生的条件下事件 A 发生的条件概率。\n>\n> —— 概率论与数理统计 · 第 12 页'));
    // 相关题目：**问题** / **答案**，选项带字母
    expect(md, contains('**问题**\n\n下列哪个是一阶线性微分方程？\n\n- A. \$y\'+y^2=0\$\n- B.'));
    expect(md, contains('**答案**\n\nB'));
    // 照片：笔记在 根/笔记/项目/ 下，附件在 根/附件/ → 向上两级
    final img = RegExp(r'!\[照片 1\]\(([^)]+)\)').firstMatch(md)!;
    expect(img[1], startsWith('../../${Uri.encodeComponent('附件')}/${Uri.encodeComponent('照片_1')}-'));
    final target = '闪卡刷题导出-2026-11-26/笔记/概率论 第3章/${Uri.decodeComponent(img[1]!)}';
    expect(z.keys, contains(Uri.file(target).normalizePath().toFilePath().replaceFirst(RegExp('^/'), '')));
    expect(md, contains('（照片 2 未能导出：文件不在本机）'));
  });

  test('伴学对话：我 / AI 伴学 轮流，附件和参考网页都在', () async {
    final z = unzip(await svc.export(const KbExportOptions()));
    final md = text(z[find(z, '闪卡刷题导出-2026-11-26/AI伴学/')]!);
    expect(md, contains('materials:\n  - "概率论与数理统计 · 第一章 随机事件与概率"'));
    expect(md, contains('## 附件\n\n![板书 照片.png](../../${Uri.encodeComponent('附件')}/'));
    expect(md, contains('- [习题课讲义.txt](../../'));
    expect(md, contains('## 对话\n\n### 我\n\n全概率公式和贝叶斯公式有什么区别？\n\n### AI 伴学\n\n全概率公式由因求果：\$P(A)=\\sum_i P(B_i)P(A\\mid B_i)\$'));
    expect(md, contains('1. [贝叶斯公式](https://example.com/bayes)'));
    // 附件文件名不含空格
    final att = z.keys.where((k) => k.contains('/附件/板书')).single;
    expect(att.contains(' '), isFalse);
    expect(z[att]!.content.length, 70);
  });

  test('AI 解释：不导出提示词，带上原题和追问', () async {
    final z = unzip(await svc.export(const KbExportOptions()));
    final md = text(z[find(z, '闪卡刷题导出-2026-11-26/AI解释/常微分方程/')]!);
    expect(md.contains('prompt'), isFalse);
    expect(md, contains('- 追问：1 次'));
    expect(md, contains('## 题目\n\n**问题**'));
    expect(md, contains("### AI 解释\n\n标准形式是 \$y'+p(x)y=q(x)\$。\n\n### 我\n\n为什么"));
  });

  test('收藏：原内容删除时保留标题；错题：我的答案和 CSV', () async {
    final z = unzip(await svc.export(const KbExportOptions()));
    final gone = text(z[find(z, '闪卡刷题导出-2026-11-26/收藏/概率论 第3章/题目/已删除的题-')]!);
    expect(gone, contains('（原内容已删除，只保留收藏时的标题）'));
    final wrongQ = text(z[find(z, '闪卡刷题导出-2026-11-26/错题/常微分方程/')]!);
    expect(wrongQ, contains('**我的答案**\n\nA'));
    expect(wrongQ, contains('mark: "答错"'));
    expect(wrongQ, contains('streak: 0'));
    final csv = text(z['闪卡刷题导出-2026-11-26/错题/错题.csv']!);
    expect(z['闪卡刷题导出-2026-11-26/错题/错题.csv']!.content.sublist(0, 3), [0xEF, 0xBB, 0xBF]); // BOM：Excel 打开不乱码
    expect(csv.replaceFirst('\uFEFF', ''), startsWith('题目,项目,章节,题型,选项,正确答案,我的答案,解析,标记,连续答对,加入时间,页码,ID\r\n'));
    // 含逗号 / 引号 / 换行的字段加引号，引号写两次
    expect(csv, contains('"记不清, ""大概""是乘法"'));
    expect(csv, contains('"A. \$y\'+y^2=0\$\nB. \$y\'+p(x)y=q(x)\$'));
    expect(csv.split('\r\n').where((l) => l.isNotEmpty).length, greaterThanOrEqualTo(3));
  });

  test('只导出一个项目、只选部分内容', () async {
    final r = await svc.export(const KbExportOptions(projectId: 'p2', notes: false, studyChats: false, favorites: false));
    expect(r.fileName, '闪卡刷题导出-常微分方程-2026-11-26.zip');
    final z = unzip(r);
    final cats = z.keys.map((k) => k.split('/')[1]).toSet();
    expect(cats, {'使用说明.md', 'AI解释', '错题'});
    expect(z.keys.any((k) => k.contains('概率论')), isFalse);
    expect(text(z.entries.firstWhere((e) => e.key.endsWith('使用说明.md')).value), contains('范围：常微分方程'));
  });

  test('重复导出文件名不变（可直接覆盖）', () async {
    final a = (await svc.export(const KbExportOptions())).paths.toSet();
    final b = (await svc.export(const KbExportOptions())).paths.toSet();
    expect(a, b);
  });

  test('数量统计', () async {
    final c = await svc.counts();
    expect((c.notes, c.studyChats, c.explains, c.favorites, c.wrong), (1, 1, 2, 3, 2));
    final c2 = await svc.counts(projectId: 'p2');
    expect((c2.notes, c2.studyChats, c2.explains, c2.wrong), (0, 0, 1, 1));
  });

  // 示例压缩包：KB_SAMPLE_OUT=/path/sample.zip flutter test test/kb_export_test.dart
  test('示例压缩包可以正常解开', () async {
    final r = await svc.export(const KbExportOptions());
    final out = Platform.environment['KB_SAMPLE_OUT'];
    if (out != null) File(out)..createSync(recursive: true)..writeAsBytesSync(r.bytes);
    for (final f in ZipDecoder().decodeBytes(r.bytes).files.where((f) => f.isFile && f.name.endsWith('.md') && !f.name.endsWith('使用说明.md'))) {
      final t = utf8.decode(f.content);
      expect(t, startsWith('---\n'), reason: f.name);
      expect(t.endsWith('\n'), isTrue);
    }
  });

  group('工具函数', () {
    test('文件名清理', () {
      expect(KbExportService.sanitizeName(r'a/b\1:d*e?f"g<h>i|j#k^l[m]n'), 'a b 1 d e f g h i j k l m n');
      expect(KbExportService.sanitizeName(r'$P(A\mid B)$ 的含义'), 'P(A B) 的含义');
      expect(KbExportService.sanitizeName('  ..隐藏.. '), '隐藏');
      expect(KbExportService.sanitizeName('第一行\n第二行\t结尾'), '第一行 第二行 结尾');
      expect(KbExportService.sanitizeName('???'), '未命名');
      expect(KbExportService.sanitizeName('con'), '_con');
      expect(KbExportService.sanitizeName('长' * 80).runes.length, 50);
      expect(KbExportService.sanitizeName('😀' * 60, max: 10), '😀' * 10);
    });

    test('稳定的短后缀', () {
      expect(KbExportService.shortId('n1'), KbExportService.shortId('n1'));
      expect(KbExportService.shortId('n1'), hasLength(6));
      expect(KbExportService.shortId('n1') == KbExportService.shortId('n2'), isFalse);
      expect(KbExportService.fileNameFor('同名', 'a') == KbExportService.fileNameFor('同名', 'b'), isFalse);
    });

    test('CSV 转义', () {
      expect(KbExportService.csvField('普通'), '普通');
      expect(KbExportService.csvField('a,b'), '"a,b"');
      expect(KbExportService.csvField('他说"好"'), '"他说""好"""');
      expect(KbExportService.csvField('两\n行'), '"两\n行"');
      expect(KbExportService.toCsv([
        ['a', 'b'],
        ['1', '2']
      ]), 'a,b\r\n1,2\r\n');
    });
  });
}
