import 'dart:convert';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/prompts.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/theme/html_clean.dart';
import 'package:ai_flashcards/theme/rich_text.dart';
import 'package:ai_flashcards/ui/chapter_view_page.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户截图里的情形：DeepSeek OCR 把教材里的 Excel 库对比表输出成 HTML 表格。
const excelPage = '''9.3 Excel 文件的读写
Python 中常用 xlrd 读取 Excel 文件，用 xlwt 写入 Excel 文件。
<table><tr><td>模块</td><td>功能</td><td>支持的格式</td><td>安装命令</td></tr><tr><td>xlrd</td><td>读取 Excel 文件</td><td>.xls、.xlsx（2.0 版起只支持 .xls）</td><td>pip install xlrd</td></tr><tr><td>xlwt</td><td>写入 Excel 文件</td><td>.xls</td><td>pip install xlwt</td></tr><tr><td>openpyxl</td><td>读写 Excel 文件</td><td>.xlsx</td><td>pip install openpyxl</td></tr></table>
使用 xlrd.open_workbook() 打开工作簿，再用 sheet_by_index(0) 获取第一个工作表。''';

void main() {
  group('HTML 表格解析', () {
    test('截图里的 Excel xlrd/xlwt 表格', () {
      final t = parseHtmlTable(RegExp(r'<table>.*</table>').stringMatch(excelPage)!);
      expect(t.rows.length, 4);
      expect(t.rows.map((r) => r.length).toSet(), {4});
      expect(t.rows[1].map((c) => c.text), ['xlrd', '读取 Excel 文件', '.xls、.xlsx（2.0 版起只支持 .xls）', 'pip install xlrd']);
      expect(t.rows[2][0].text, 'xlwt');

      final plain = displayPlainText(excelPage);
      expect(plain, isNot(contains('<')));
      expect(plain, contains('模块\t功能\t支持的格式\t安装命令\nxlrd\t读取 Excel 文件\t'));
      expect(plain, contains('xlwt\t写入 Excel 文件\t.xls\tpip install xlwt'));
      expect(plain, startsWith('9.3 Excel 文件的读写'));
      expect(plain, endsWith('获取第一个工作表。'));

      final d = MdMath.parse(excelPage);
      expect(d.blocks.map((b) => b.type), [MdBlockType.paragraph, MdBlockType.table, MdBlockType.paragraph]);
      expect(d.tables.single.rows.length, 4);
      expect(d.blocks.first.text, isNot(contains('<')));
    });

    test('thead / th / colspan / rowspan / <br>', () {
      final t = parseHtmlTable('<table><thead><tr><th rowspan="2">项目</th><th colspan=2>成绩</th></tr>'
          '<tr><th>期中</th><th>期末</th></tr></thead><tbody><tr><td>张三</td><td>90</td><td>88<br>补考</td></tr></tbody></table>');
      expect(t.headerRows, 2);
      final g = t.grid();
      expect(g.length, 3);
      expect(g.map((r) => r.length).toSet(), {3});
      expect(g[0].map((c) => c?.text), ['项目', '成绩', null]);
      expect(g[1].map((c) => c?.text), [null, '期中', '期末']);
      expect(t.toPlainText().split('\n'), ['项目\t成绩\t', '\t期中\t期末', '张三\t90\t88 补考']);
    });

    test('残缺 / 嵌套 / 未知标签都不崩溃', () {
      // 不闭合的单元格、行和表格
      var t = parseHtmlTable('<table><tr><td>a<td>b<tr><td>c');
      expect(t.rows.map((r) => r.map((c) => c.text).toList()), [
        ['a', 'b'],
        ['c']
      ]);
      expect(t.grid()[1], hasLength(2)); // 补齐列数
      // 嵌套表格：内层转成文字放进单元格
      t = parseHtmlTable('<table><tr><td>外<table><tr><td>内1</td><td>内2</td></tr></table></td><td>右</td></tr></table>');
      expect(t.rows.single.length, 2);
      expect(displayPlainText('<table><tr><td>外<table><tr><td>内1</td><td>内2</td></tr></table></td><td>右</td></tr></table>'),
          '外 内1 / 内2\t右');
      // 缺少 <table> 的表格片段
      expect(displayPlainText('前<tr><td>1</td><td>2</td></tr>后'), '前\n\n1\t2\n\n后');
      // 未知标签和比较符号原样显示；已知排版标签去掉
      expect(displayPlainText('<foo>x</foo> a < b, List<int> <span>c</span></div>'), '<foo>x</foo> a < b, List<int> c');
      // 不成对的 <b> 当文字显示，不误删
      expect(displayPlainText('HTML 中 <b> 标签表示加粗'), 'HTML 中 <b> 标签表示加粗');
      // 任意截断都不抛异常
      final src = '<table border="1"><caption>表 1</caption><thead><tr><th colspan="2">A&amp;B</th></tr></thead>'
          '<tbody><tr><td rowspan="3">x<sup>2</sup></td><td>\$\\frac{1}{2}\$<br/>y</td></tr></tbody></table><p>尾</p>';
      for (var i = 0; i <= src.length; i++) {
        final s = src.substring(0, i);
        displayPlainText(s);
        MdMath.parse(s);
        parseHtmlTable(s).grid();
      }
      expect(parseHtmlTable(src).caption, '表 1');
    });
  });

  group('零散标签与实体', () {
    test('实体解码', () {
      expect(decodeEntities('a&nbsp;b &lt;x&gt; &amp; &#39;q&#39; &#x4e2d;&#25991; &unknown; &#0;'),
          "a b <x> & 'q' 中文 &unknown; &#0;");
      // 实体解出来的尖括号不会再被当成标签
      expect(displayPlainText('&lt;b&gt;不是粗体&lt;/b&gt;'), '<b>不是粗体</b>');
      expect(MdMath.parse('&lt;b&gt;x&lt;/b&gt;').blocks.single.text, '<b>x</b>');
    });

    test('常见行内标签', () {
      expect(htmlInline('<b>粗</b>和<strong> 强 </strong>、<i>斜</i>'), '**粗**和 **强** 、*斜*');
      expect(htmlInline('x<sup>2</sup>+H<sub>2</sub>O, e<sup>ix</sup>, a<sub>ij</sub>'), 'x²+H₂O, e^(ix), a_(ij)');
      expect(htmlInline('一<br>二<br/>三<p>段落</p>'), '一\n二\n三\n\n段落\n\n');
      expect(htmlInline('<img src="a.png">图'), '[插图]图');
      expect(htmlInline('代码 `<br>` 保持原样<br>'), '代码 `<br>` 保持原样\n');
      expect(htmlInline('<!-- 注释 -->文字'), '文字');
    });

    test('DeepSeek OCR 定位标记和图片占位', () {
      const s = '<|ref|>title<|/ref|><|det|>[[10, 20, 300, 40]]<|/det|>\n# 标题\n'
          '<｜ref｜>image<｜/ref｜><｜det｜>[[1,2,3,4]]<｜/det｜>\n![](images/0.jpg)\n<|grounding|>正文';
      final p = displayPlainText(s);
      expect(p, isNot(contains('<|')));
      expect(p, isNot(contains('[[')));
      expect(p, contains('# 标题'));
      expect('[插图]'.allMatches(p).length, 2);
      expect(p, endsWith('正文'));
    });
  });

  group('渲染', () {
    test('单元格里的公式照常保护和排版；Markdown 管道表格', () {
      final d = MdMath.parse(r'<table><tr><td>公式</td><td>$x^2<y$</td></tr><tr><td>积分</td><td>$$\int_0^1 x\,dx$$</td></tr></table>');
      expect(d.math.length, 2);
      expect(d.math.first.text, 'x^2<y'); // 公式里的 < 不被当成标签
      expect(MdMath.parse(r'$0&lt;p&lt;1$, $\begin{matrix}a & b\end{matrix}$').math.map((m) => m.text),
          ['0<p<1', r'\begin{matrix}a & b\end{matrix}']);
      expect(d.tables.single.rows[0][1].text, contains(MdMath.ph));

      final p = MdMath.parse('说明\n\n| 模块 | 功能 |\n|:---|---:|\n| xlrd | 读取 \\| 只读 |\n| xlwt | 写入 |\n\n结束');
      expect(p.blocks.map((b) => b.type), [MdBlockType.paragraph, MdBlockType.table, MdBlockType.paragraph]);
      expect(p.tables.single.rows.map((r) => r.map((c) => c.text).toList()), [
        ['模块', '功能'],
        ['xlrd', '读取 | 只读'],
        ['xlwt', '写入']
      ]);
      expect(p.tables.single.headerRows, 1);
      // 普通含竖线的文字不当表格
      expect(MdMath.parse('a | b\n下一行').blocks.single.type, MdBlockType.paragraph);
    });

    for (final dark in [false, true]) {
      testWidgets('MathText 显示真正的表格（${dark ? '深色' : '浅色'}），宽表可横向滚动', (t) async {
        SharedPreferences.setMockInitialValues({'theme_mode': dark ? 'dark' : 'light'});
        final state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
        final wide = '<table><tr>${[for (var i = 0; i < 12; i++) '<td>第 $i 列的较长内容</td>'].join()}</tr>'
            '<tr><td>\$\\sqrt{2}\$</td><td>&lt;tag&gt;</td></tr></table>';
        await t.pumpWidget(StudyApp(
            state: state,
            home: Scaffold(body: SingleChildScrollView(child: Column(children: [MathText(excelPage), MathText(wide)])))));
        await t.pump();
        expect(t.takeException(), isNull);
        expect(find.byType(Table), findsNWidgets(2));
        expect(find.textContaining('<td>'), findsNothing);
        expect(find.textContaining('xlrd', findRichText: true), findsWidgets);
        expect(find.text('pip install xlwt', findRichText: true), findsOneWidget);
        expect(find.descendant(of: find.byType(Table).last, matching: find.byType(Math)), findsOneWidget);
        expect(find.text('<tag>', findRichText: true), findsOneWidget);
        final scrolls = t.widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView));
        expect(scrolls.where((s) => s.scrollDirection == Axis.horizontal).length, 2);
      });
    }
  });

  test('章节查看页：搜索计数和复制用整理后的文字', () {
    final p = ChapterPageView(5, excelPage, 'ds_text', true, const []);
    final copy = chapterPlainText('第九章', [p]);
    expect(copy, contains('xlrd\t读取 Excel 文件'));
    expect(copy, isNot(contains('<td>')));
    expect(countMatches(displayPlainText(p.text), 'td'), 0);
    expect(countMatches(displayPlainText(p.text), 'xlwt'), 3);
    expect(pageNote(p), isNull);
  });

  test('出题提示词里的教材原文与保存的解析文本逐字节一致（显示层修改不影响发给 AI 的内容）', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository(MemoryDocStore());
    final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    await repo.saveProject(Project(id: 'p', name: 'Python'));
    await repo.savePages([PageText(docId: 'd', projectId: 'p', page: 1, text: excelPage)]);
    await repo.replaceChunks('p', 'd', chunkPages('p', 'd', await repo.pages('p', docId: 'd')));
    final stored = (await repo.pages('p', docId: 'd')).single.text;
    expect(stored, excelPage); // 保存的解析文本没有被改动

    final prompts = <String>[];
    final llm = LlmClient(
        baseUrl: 'x',
        apiKey: 'k',
        model: 'm',
        client: MockClient((req) async {
          prompts.add((jsonDecode(req.body)['messages'] as List).last['content'] as String);
          final r = jsonEncode({'knowledge_points': [{'title': 'xlrd', 'type': '定义', 'content': '读取 Excel', 'page': 1}]});
          return http.Response.bytes(utf8.encode(jsonEncode({'choices': [{'message': {'content': r}}]})), 200);
        }));
    final chunks = await repo.chunks('p');
    await GenerationService(repo, settings, llm, qualityCheck: false).extractKps('p', chunks, (_, _) {});
    final c = chunks.single;
    expect(prompts.single, Prompts.fill(settings.prompt('kp'), {
      'chapter': c.chapter,
      'section': c.section,
      'pages': '${c.pageStart}–${c.pageEnd}',
      'text': c.text,
    }));
    expect(prompts.single, contains(c.text));
    expect(prompts.single, contains('<table><tr><td>模块</td>'));
    expect(prompts.single, contains(stored.substring(stored.indexOf('<table>'))));
  });
}
