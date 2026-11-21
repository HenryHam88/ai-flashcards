import 'dart:convert';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/latex.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/theme/latex_text.dart';
import 'package:ai_flashcards/theme/rich_text.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户截图里闪卡背面和解析的原文。
const userBack = r'\texttt{print()} 将字符串输出到屏幕；示例输出 \texttt{Hello World！这是我的第一个Python程序!}，并用等号行包围。';
const userExplain = r'\texttt{print()} 是Python内置输出函数…';

final _mk = RegExp('[\uE001-\uE015]');

/// 解析后去掉样式标记的文字（看内容有没有丢）。
String shown(String s) => MdMath.parse(s).blocks.map((b) => Mk.restore(b.text)).join('\n');

void main() {
  group('文本命令', () {
    test('用户截图里的 \\texttt', () {
      final d = MdMath.parse(userBack);
      expect(d.math, isEmpty);
      final t = d.blocks.single.text;
      expect(t, isNot(contains(r'\texttt')));
      expect(t, contains('${Mk.codeOpen}print()${Mk.codeClose} 将字符串输出到屏幕'));
      expect(t, contains('${Mk.codeOpen}Hello World！这是我的第一个Python程序!${Mk.codeClose}，并用等号行包围。'));
      expect(shown(userExplain), 'print() 是Python内置输出函数…');
    });

    test('粗体、斜体、下划线、\\text、\\verb、嵌套括号', () {
      expect(shown(r'\textbf{重点：\texttt{f(a{b}c)} 和 \textit{斜体}} \underline{下划线} \emph{强调} \text{普通} \mathrm{d}'),
          '重点：f(a{b}c) 和 斜体 下划线 强调 普通 d');
      final t = MdMath.parse(r'\textbf{a \textbf{b} c}').blocks.single.text;
      expect(Mk.boldOpen.allMatches(t).length, 1); // 同类嵌套只保留一层
      expect(MdMath.parse(r'用 \verb|x_y{}| 表示').blocks.single.text, '用 ${Mk.codeOpen}x_y{}${Mk.codeClose} 表示');
    });

    test('转义字符按字面显示，不会变成 Markdown 格式', () {
      expect(shown(r'my\_file\_name.txt 占 50\%，A \& B，\#1，\{x\}，\$5'), r'my_file_name.txt 占 50%，A & B，#1，{x}，$5');
      // \_\_init\_\_ 不会被当成 __粗体__
      final d = MdMath.parse(r'\_\_init\_\_ 方法');
      expect(MdMath.inlineRe.hasMatch(d.blocks.single.text), isFalse);
      expect(shown(r'\_\_init\_\_ 方法'), '__init__ 方法');
      // \&lt; 不会被当成 HTML 实体
      expect(shown(r'A \&lt; B'), 'A &lt; B');
    });

    test('\\\\ 换行，~ 保持原样，字面量 \\n 换行但不误伤 \\nabla 等命令', () {
      expect(shown(r'第一行\\第二行 a~b'), '第一行\n第二行 a~b');
      expect(MdMath.parse(r'第一行\n第二行\n\n第三段').blocks.map((b) => b.text), ['第一行\n第二行', '第三段']);
      expect(shown(r'梯度 \nabla f 与 \neq'), r'梯度 \nabla f 与 \neq');
    });

    test('残缺写法和未知命令原样显示，任意截断都不崩溃', () {
      expect(shown(r'\texttt{未闭合'), r'\texttt{未闭合');
      expect(shown(r'只有命令 \textbf 没有参数'), r'只有命令 \textbf 没有参数');
      expect(shown(r'\foo{x} 和 \LaTeX'), r'\foo{x} 和 \LaTeX');
      expect(shown(r'\begin{itemize}\item 没有结束'), r'\begin{itemize}\item 没有结束');
      expect(shown(r'\begin{weird}x\end{weird}'), r'\begin{weird}x\end{weird}');
      const src = r'\begin{itemize}\item \textbf{a{b} \texttt{c\_d}} \item $x^2$ \begin{enumerate}\item 子\end{enumerate}\end{itemize}'
          r'\begin{tabular}{|c|c|}\hline \multicolumn{2}{c}{表头}\\ a \& b & $\frac12$ \\\hline\end{tabular} ```py' '\n'
          r'print(1)' '\n' r'``` \verb|z| \n \\ \(\alpha\) \[x\]';
      for (var i = 0; i <= src.length; i++) {
        MdMath.parse(src.substring(0, i));
      }
    });
  });

  group('公式和代码不受影响', () {
    test('公式里的 \\texttt 等保持原样交给公式排版', () {
      final d = MdMath.parse(r'$\texttt{print}$ 与 \texttt{print}，$a\_b$，$$\textbf{A}\\x$$');
      expect(d.math.map((m) => m.text), [r'\texttt{print}', r'a\_b', r'\textbf{A}\\x']);
      expect(d.math.map((m) => m.text), LatexUtil.split(r'$\texttt{print}$ 与 \texttt{print}，$a\_b$，$$\textbf{A}\\x$$')
          .where((s) => s.isMath).map((s) => s.text));
      // flutter_math_fork 本身支持这些命令
      for (final t in [r'\texttt{print}', r'\textbf{A}', r'\textit{b}', r'\underline{x}', r'\text{中文}']) {
        expect(LatexUtil.parseError(t), isNull, reason: t);
      }
    });

    test('\\( \\) 和 \\[ \\] 原来就当公式处理，结果不变', () {
      const s = r'行内 \(E(X)=\sum x_i p_i\) 与独立 \[D(X)=E(X^2)-[E(X)]^2\]';
      final d = MdMath.parse(s);
      expect(d.math, LatexUtil.split(s).where((x) => x.isMath).toList());
      expect(d.math.map((m) => m.display), [false, true]);
    });

    test('行内代码和成对的代码块里不转换', () {
      final d = MdMath.parse(r'`\texttt{x}` 和 \texttt{y}');
      final m = MdMath.inlineRe.firstMatch(d.blocks.single.text)!;
      expect(m[4], r'\texttt{x}');
      final c = MdMath.parse("说明\n```python\nprint('\\texttt{x}', a_b)\n# 注释 **不是粗体**\n```\n后文 \\textbf{粗}");
      expect(c.blocks.map((b) => b.type), [MdBlockType.paragraph, MdBlockType.code, MdBlockType.paragraph]);
      expect(c.codeBlocks.single, "print('\\texttt{x}', a_b)\n# 注释 **不是粗体**");
    });

    test('没闭合的代码块 / 反引号不会吞掉后面的内容', () {
      final d = MdMath.parse('```python\nprint(1)\n后面的 **粗体** 正常\n\n- 列表');
      expect(d.codeBlocks, isEmpty);
      expect(d.blocks.map((b) => b.type), [MdBlockType.paragraph, MdBlockType.bullet]);
      expect(MdMath.inlineRe.allMatches(d.blocks.first.text).map((m) => m[1]), contains('粗体'));
      final e = MdMath.parse('a `b 没闭合\n**粗** c `d`');
      final ms = MdMath.inlineRe.allMatches(e.blocks.single.text).toList();
      expect(ms.map((m) => m[1] ?? m[4]), ['粗', 'd']);
    });
  });

  group('环境', () {
    test('itemize / enumerate（含嵌套）/ description → 列表', () {
      final d = MdMath.parse(r'''常用函数：
\begin{itemize}
  \item \texttt{print()}：输出
  \item \texttt{input()}：输入
  \begin{enumerate}
    \item 返回字符串
    \item 可带提示 $x$
  \end{enumerate}
  \item[注意] 区分大小写
\end{itemize}''');
      expect(d.blocks.map((b) => '${b.type.name}${b.level}'), ['paragraph0', 'bullet0', 'bullet0', 'ordered1', 'ordered1', 'bullet0']);
      expect(Mk.restore(d.blocks[1].text), 'print()：输出');
      expect(d.blocks[3].marker, '1.');
      expect(d.blocks[4].marker, '2.');
      expect(Mk.restore(d.blocks.last.text), '注意 区分大小写');
      expect(d.math.single.text, 'x');
    });

    test('tabular → 表格（\\hline、\\multicolumn、\\& 都处理）', () {
      final d = MdMath.parse(r'''\begin{center}
\begin{tabular}{|l|c|}
\hline
\multicolumn{2}{|c|}{Python 输出} \\
\hline
函数 & 作用 \\
\texttt{print()} & 输出 A \& B \\
$x^2$ & 平方 \\
\hline
\end{tabular}
\end{center}''');
      expect(d.blocks.single.type, MdBlockType.table);
      final g = d.tables.single.grid();
      expect(g.length, 4);
      expect(g[0].map((c) => c?.text), ['Python 输出', null]);
      expect(Mk.restore(g[2][0]!.text), 'print()');
      expect(Mk.restore(g[2][1]!.text), '输出 A & B');
      expect(d.math.single.text, 'x^2');
    });

    test('quote 变引用，center 等去掉外壳', () {
      final d = MdMath.parse(r'\begin{quote}人生苦短\end{quote}\begin{flushright}右对齐\end{flushright}');
      expect(d.blocks.map((b) => b.type), [MdBlockType.quote, MdBlockType.paragraph]);
      expect(d.blocks.last.text, '右对齐');
    });

    test('公式外裸露的数学环境变成独立公式；公式里原本能显示的环境不变', () {
      final d = MdMath.parse(r'推导：\begin{align}a&=b+c\\&=d\label{eq1}\end{align}以及\begin{cases}1&x>0\\0&x\le0\end{cases}');
      expect(d.math.length, 2);
      expect(d.math.every((m) => m.display), isTrue);
      expect(d.math.first.text, r'\begin{aligned}a&=b+c\\&=d\end{aligned}');
      for (final m in d.math) {
        expect(LatexUtil.parseError(m.text), isNull);
      }
      const ok = r'$$\begin{cases}1&x>0\\0&x\le0\end{cases}$$';
      expect(MdMath.parse(ok).math.single.text, r'\begin{cases}1&x>0\\0&x\le0\end{cases}');
    });
  });

  test('公式修复只用于排版失败的公式：环境改写、中文包进 \\text{}', () {
    expect(repairTex(r'\begin{align*}a&=b\end{align*}'), r'\begin{aligned}a&=b\end{aligned}');
    expect(repairTex(r'x=中文+\text{已包}1'), r'x=\text{中文}+\text{已包}1');
    expect(repairTex(r'\emph{x}'), r'\textit{x}');
  });

  test('多余的 Markdown 符号不吞内容', () {
    expect(shown('**重点：没有闭合'), '**重点：没有闭合'); // 解析层保留，显示时去掉多余的 **（见下方界面测试）
    final d = MdMath.parse('#标题\n*\n##\n正文 2**3');
    expect(d.blocks.map((b) => b.type), [MdBlockType.heading, MdBlockType.paragraph]);
    expect(d.blocks.first.text, '标题');
    expect(d.blocks.last.text, '正文 2**3');
    expect(MdMath.parse('#include <stdio.h>').blocks.single.type, MdBlockType.paragraph);
  });

  group('界面', () {
    Future<void> pump(WidgetTester t, List<String> texts, {bool dark = false}) async {
      SharedPreferences.setMockInitialValues({'theme_mode': dark ? 'dark' : 'light'});
      final state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
      await t.pumpWidget(StudyApp(
          state: state,
          home: Scaffold(body: SingleChildScrollView(child: Column(children: [for (final s in texts) MathText(s)])))));
      await t.pump();
    }

    List<TextSpan> spans(WidgetTester t) {
      final out = <TextSpan>[];
      for (final r in t.widgetList<RichText>(find.byType(RichText))) {
        r.text.visitChildren((s) {
          if (s is TextSpan && s.text != null) out.add(s);
          return true;
        });
      }
      return out;
    }

    testWidgets('用户的闪卡：\\texttt 显示为代码样式，看不到反斜杠命令', (t) async {
      await pump(t, [userBack, userExplain, '**重点：没有闭合', r'\underline{下划线}']);
      expect(t.takeException(), isNull);
      final all = spans(t);
      expect(all.any((s) => s.text!.contains(r'\texttt')), isFalse);
      final code = all.where((s) => s.style?.fontFamily == 'monospace').map((s) => s.text).toList();
      expect(code, ['print()', 'Hello World！这是我的第一个Python程序!', 'print()']);
      expect(all.any((s) => s.text == '重点：没有闭合'), isTrue);
      expect(all.any((s) => s.text!.contains(_mk)), isFalse);
      expect(find.textContaining('下划线', findRichText: true), findsOneWidget);
    });

    testWidgets('排版失败的公式：能修就修，修不了显示原始写法（不再是红字）', (t) async {
      await pump(t, [r'$\begin{align}a&=b\end{align}$', r'$\foo{x}+1$'], dark: true);
      expect(t.takeException(), isNull);
      expect(find.byType(Math), findsWidgets); // 修复后的公式嵌在原 Math 的降级位置里
      final src = t.widget<Text>(find.text(r'\foo{x}+1'));
      expect(src.style?.fontFamily, 'monospace');
      expect(find.text(r'\begin{align}a&=b\end{align}'), findsNothing); // 第一个修好后正常排版
    });

    testWidgets('列表、表格、代码块、\\( \\) 都能显示（深色模式）', (t) async {
      await pump(t, [
        r'\begin{itemize}\item 行内公式 \(x^2\) \item \textbf{粗体}\end{itemize}',
        r'\begin{tabular}{cc}a & b \\ c & d\end{tabular}',
        '```\ncode \\texttt{x}\n```',
      ], dark: true);
      expect(t.takeException(), isNull);
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('code \\texttt{x}'), findsOneWidget);
      expect(find.text('•'), findsNWidgets(2));
    });
  });

  test('保存的卡片内容和发给 AI 的内容保持原样', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository(MemoryDocStore());
    final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    await repo.saveProject(Project(id: 'p', name: 'Python'));
    final card = Flashcard(id: 'c1', projectId: 'p', front: 'print() 的作用？', back: userBack, explanation: userExplain);
    await repo.saveCards([card]);
    MdMath.parse(userBack); // 渲染解析不会改动原文
    final saved = (await repo.cards(projectId: 'p')).single;
    expect((saved.back, saved.explanation), (userBack, userExplain));

    const page = '第 1 章 Python 入门\n$userBack\n$userExplain\n\\begin{itemize}\\item \\texttt{input()}\\end{itemize}';
    await repo.savePages([PageText(docId: 'd', projectId: 'p', page: 1, text: page)]);
    await repo.replaceChunks('p', 'd', chunkPages('p', 'd', await repo.pages('p', docId: 'd')));
    final prompts = <String>[];
    final llm = LlmClient(
        baseUrl: 'x',
        apiKey: 'k',
        model: 'm',
        client: MockClient((req) async {
          prompts.add((jsonDecode(req.body)['messages'] as List).last['content'] as String);
          final r = jsonEncode({'knowledge_points': [{'title': 'print', 'type': '定义', 'content': '输出', 'page': 1}]});
          return http.Response.bytes(utf8.encode(jsonEncode({'choices': [{'message': {'content': r}}]})), 200);
        }));
    final chunks = await repo.chunks('p');
    await GenerationService(repo, settings, llm, qualityCheck: false).extractKps('p', chunks, (_, _) {});
    expect(prompts.single, contains(chunks.single.text));
    expect(prompts.single, contains(userBack));
    expect(prompts.single, contains(r'\begin{itemize}\item \texttt{input()}\end{itemize}'));
  });
}
