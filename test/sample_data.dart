import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';

/// 截图和演示用的示例数据（不调用任何 API）。
/// [now] 固定时可让和日期有关的截图（统计、热力图）每天都一样。
Future<void> seedSampleData(Repository repo, {DateTime? now}) async {
  now ??= DateTime.now();
  final p1 = Project(id: 'p1', name: '概率论 第3章', createdAt: now);
  final p2 = Project(id: 'p2', name: '常微分方程', createdAt: now.subtract(const Duration(days: 1)));
  final p3 = Project(id: 'p3', name: '运筹学', createdAt: now.subtract(const Duration(days: 2)));
  for (final p in [p1, p2, p3]) {
    await repo.saveProject(p);
  }
  await repo.saveDoc(PdfDoc(id: 'd1', projectId: 'p1', name: '概率论与数理统计', path: '', pageCount: 186, parsedPages: 186, status: '已解析'));
  await repo.savePages([
    PageText(docId: 'd1', projectId: 'p1', page: 12, text: r'''1.4 条件概率
定义 设 $A,B$ 是两个事件，且 $P(B)>0$，称
$$P(A\mid B)=\frac{P(AB)}{P(B)}$$
为在事件 $B$ 发生的条件下事件 $A$ 发生的条件概率。'''),
  ]);
  final fronts = [
    ('什么是条件概率？', r'$P(A\mid B)=\dfrac{P(AB)}{P(B)}$，其中 $P(B)>0$'),
    ('乘法公式', r'$P(AB)=P(B)\,P(A\mid B)$'),
    ('全概率公式', r'$P(A)=\sum_{i=1}^{n}P(B_i)P(A\mid B_i)$'),
    ('贝叶斯公式', r'$P(B_i\mid A)=\dfrac{P(B_i)P(A\mid B_i)}{\sum_{j}P(B_j)P(A\mid B_j)}$'),
  ];
  final cards = <Flashcard>[];
  for (var i = 0; i < 32; i++) {
    final f = fronts[i % fronts.length];
    cards.add(Flashcard(
      id: 'c$i',
      projectId: 'p1',
      docId: 'd1',
      chapter: '第一章 随机事件与概率',
      section: '1.4 条件概率',
      front: f.$1,
      back: f.$2,
      explanation: '条件概率把样本空间缩小到 \$B\$ 上重新计算比例。',
      page: 12,
      due: now.subtract(const Duration(hours: 1)),
    ));
  }
  for (var i = 0; i < 8; i++) {
    cards.add(Flashcard(id: 'o$i', projectId: 'p2', chapter: '第二章 一阶微分方程', front: '一阶线性微分方程的标准形式', back: r"$y'+p(x)y=q(x)$", due: now.add(const Duration(days: 2))));
  }
  for (var i = 0; i < 12; i++) {
    cards.add(Flashcard(id: 'y$i', projectId: 'p3', chapter: '第一章 线性规划', front: '单纯形法的检验数', back: r'$\sigma_j=c_j-\sum_i c_{B_i}a_{ij}$', due: now.add(const Duration(days: 1))));
  }
  await repo.saveCards(cards);
  await repo.saveQuestions([
    Question(
      id: 'q1',
      projectId: 'p2',
      chapter: '第二章 一阶微分方程',
      type: QType.single,
      stem: '下列哪个是一阶线性微分方程？',
      options: [r"$y'+y^2=0$", r"$y'+p(x)y=q(x)$", r"$y''+y=\sin x$", r"$y'=ky^2$"],
      answer: 'B',
      explanation: r"一阶线性微分方程的标准形式为 $y'+p(x)y=q(x)$，其中 $p(x)$、$q(x)$ 为已知函数。其通解为 $$y=e^{-\int p(x)\,dx}\left(\int q(x)e^{\int p(x)\,dx}\,dx+C\right)$$",
      difficulty: '基础',
      page: 30,
    ),
  ]);
  for (var i = 0; i < 40; i++) {
    await repo.log(LogEntry(
        id: 'l$i',
        projectId: 'p1',
        kind: i.isEven ? 'card' : 'quiz',
        correct: i % 5 != 0,
        at: now.subtract(Duration(days: i % 7, minutes: i))));
  }
  await repo.saveExplain(ExplainCache(id: 'c11', projectId: 'p1', messages: [
    {'role': 'user', 'content': '...'},
    {
      'role': 'assistant',
      'content': r'''**通俗理解**：条件概率就是「已知 $B$ 已经发生」之后，再看 $A$ 发生的可能性。相当于把样本空间从 $\Omega$ 缩小到 $B$。
$$P(A\mid B)=\frac{P(AB)}{P(B)},\quad P(B)>0$$
**例子**：掷一枚骰子，已知点数是偶数（$B=\{2,4,6\}$），求点数大于 3（$A$）的概率：$P(A\mid B)=\dfrac{2/6}{3/6}=\dfrac{2}{3}$。
**常见误区**：$P(A\mid B)$ 与 $P(B\mid A)$ 一般不相等。'''
    },
  ]));
}

/// 统计页截图用：以固定的 [now] 生成半年学习记录、复习进度、学习时长和错题。
Future<void> seedStudyHistory(Repository repo, DateTime now) async {
  // 覆盖示例数据里相对真实时间的 40 条记录，保证截图稳定
  for (var i = 0; i < 40; i++) {
    await repo.log(LogEntry(id: 'l$i', projectId: 'p1', kind: i.isEven ? 'card' : 'quiz', correct: i % 5 != 0,
        at: now.subtract(Duration(days: i % 7, minutes: 30 + i))));
  }
  for (var d = 1; d < 182; d++) {
    final h = (d * 2654435761) >> 9;
    final active = d < 14 || h % 10 < (d > 120 ? 4 : 7);
    if (!active) continue;
    final n = 3 + (h ~/ 10) % 26;
    for (var i = 0; i < n; i++) {
      await repo.log(LogEntry(id: 'h${d}_$i', projectId: i.isEven ? 'p1' : 'p2', kind: i % 3 == 0 ? 'quiz' : 'card',
          correct: (d + i) % 7 != 0, isNew: i % 4 == 0, at: now.subtract(Duration(days: d, minutes: 40 + i))));
    }
    await repo.saveSession(StudySession(id: 's$d', projectId: 'p1', kind: 'review',
        start: now.subtract(Duration(days: d, hours: 1)), seconds: 300 + n * 40));
  }
  for (var i = 0; i < 14; i++) {
    await repo.log(LogEntry(id: 't$i', projectId: 'p1', kind: 'card', correct: i % 6 != 0, isNew: i < 5,
        at: now.subtract(Duration(minutes: 5 + i * 3))));
  }
  await repo.saveSession(StudySession(id: 'today1', projectId: 'p1', kind: 'review', start: now.subtract(const Duration(hours: 3)), seconds: 1260));
  await repo.saveSession(StudySession(id: 'today2', projectId: 'p2', kind: 'quiz', start: now.subtract(const Duration(minutes: 40)), seconds: 1020));

  final cards = await repo.cards();
  for (final c in cards) {
    final i = int.tryParse(c.id.substring(1)) ?? 0;
    switch (c.projectId) {
      case 'p1':
        if (i >= 16) {
          c.chapter = '第二章 随机变量及其分布';
          c.section = '';
        }
        c.reps = 3 + i % 4;
        c.stability = i >= 16 ? 1.5 + (i % 3) : 18.0 + i;
        c.lapses = i >= 16 ? 1 + i % 3 : (i % 9 == 0 ? 1 : 0);
        c.lastReview = now.subtract(Duration(days: i >= 16 ? 4 + i % 5 : 2 + i % 6));
        c.due = now.add(Duration(days: i >= 16 ? -(i % 3) : (i % 23) - 1));
      case 'p2':
        c.reps = 2;
        c.stability = 6 + i * 1.0;
        c.lastReview = now.subtract(Duration(days: 3 + i % 3));
        c.due = now.add(Duration(days: 1 + i * 2));
      default:
        if (i < 7) {
          c.reps = 1;
          c.stability = 3;
          c.lastReview = now.subtract(Duration(days: 1 + i % 2));
          c.due = now.add(Duration(days: 2 + i));
        }
    }
  }
  await repo.saveCards(cards);
  await repo.saveWrong(WrongEntry(id: 'q1', projectId: 'p2', questionId: 'q1', mark: '答错'));
}

/// 章节内容截图 / 测试用：第一章第 11–13 页的解析结果（带解析来源）。
Future<ChapterPlan> seedChapterPages(Repository repo) async {
  await repo.savePages([
    PageText(docId: 'd1', projectId: 'p1', page: 11, source: 'deepseek_text', text: r'''**性质 1** $P(\varnothing)=0$。
**性质 2**（有限可加性）若 $A_1,A_2,\dots,A_n$ 两两互不相容，则
$$P(A_1\cup A_2\cup\cdots\cup A_n)=\sum_{i=1}^{n}P(A_i)$$
**性质 3** 对任一事件 $A$，$P(\bar A)=1-P(A)$。'''),
    PageText(docId: 'd1', projectId: 'p1', page: 12, source: 'deepseek_rich', text: r'''**定义** 设 $A,B$ 是两个事件，且 $P(B)>0$，称
$$P(A\mid B)=\frac{P(AB)}{P(B)}$$
为在事件 $B$ 发生的条件下事件 $A$ 发生的**条件概率**。
**乘法定理** 设 $P(B)>0$，则有 $P(AB)=P(B)\,P(A\mid B)$。
**例 1** 一盒子装有 4 只产品，其中 3 只一等品、1 只二等品。从中取产品两次，每次任取一只，作不放回抽样。求在第一次取到一等品的条件下，第二次取到一等品的条件概率：$P(B\mid A)=\dfrac{2}{3}$。'''),
    PageText(docId: 'd1', projectId: 'p1', page: 13, source: 'deepseek_rich', text: '图 1-3'),
  ]);
  final plan = ChapterPlan(docId: 'd1', projectId: 'p1', source: 'toc', chapters: [
    ChapterRange('前置内容', 1, 10),
    ChapterRange('第一章 随机事件与概率', 11, 13),
    ChapterRange('第二章 随机变量及其分布', 14, 40),
  ]);
  await repo.saveChapterPlan(plan);
  await repo.replaceChunks('p1', 'd1', [
    Chunk(id: 'k11', projectId: 'p1', docId: 'd1', chapter: '第一章 随机事件与概率', section: '1.3 概率的性质', pageStart: 11, pageEnd: 11, text: ''),
    Chunk(id: 'k12', projectId: 'p1', docId: 'd1', chapter: '第一章 随机事件与概率', section: '1.4 条件概率', pageStart: 12, pageEnd: 13, text: ''),
  ]);
  return plan;
}

/// 第二章第 14–15 页：DeepSeek OCR 输出的 HTML 表格（含公式、合并单元格、实体），用于表格显示截图。
Future<void> seedTablePages(Repository repo) async {
  await seedChapterPages(repo);
  await repo.savePages([
    PageText(docId: 'd1', projectId: 'p1', page: 14, source: 'deepseek_text', text: r'''<|ref|>title<|/ref|><|det|>[[80, 60, 520, 90]]<|/det|>
## 2.3 常用离散型分布
<table><thead><tr><th>分布</th><th>记号</th><th>分布律</th><th>期望</th></tr></thead><tbody><tr><td>0–1 分布</td><td>$B(1,p)$</td><td>$P\{X=k\}=p^k(1-p)^{1-k}$</td><td>$p$</td></tr><tr><td>二项分布</td><td>$B(n,p)$</td><td>$C_n^k p^k(1-p)^{n-k}$</td><td>$np$</td></tr><tr><td>泊松分布</td><td>$P(\lambda)$</td><td>$\dfrac{\lambda^k e^{-\lambda}}{k!}$</td><td>$\lambda$</td></tr></tbody></table>
注：表中 $0&lt;p&lt;1$，$k$ 取非负整数。'''),
    PageText(docId: 'd1', projectId: 'p1', page: 15, source: 'deepseek_text', text: '''**附：用 Python 读写实验数据**
<table><tr><td>模块</td><td>功能</td><td>支持的格式</td><td>安装命令</td></tr><tr><td>xlrd</td><td>读取 Excel 文件</td><td>.xls、.xlsx（2.0 版起只支持 .xls）</td><td>pip install xlrd</td></tr><tr><td>xlwt</td><td>写入 Excel 文件</td><td>.xls</td><td>pip install xlwt</td></tr><tr><td>openpyxl</td><td>读写 Excel 文件<br>（推荐）</td><td>.xlsx</td><td>pip install openpyxl</td></tr></table>
用 xlrd.open_workbook() 打开工作簿，sheet_by_index(0) 取第一个工作表。'''),
  ]);
  await repo.replaceChunks('p1', 'd1', [
    ...await repo.chunks('p1'),
    Chunk(id: 'k23', projectId: 'p1', docId: 'd1', chapter: '第二章 随机变量及其分布', section: '2.3 常用离散型分布', pageStart: 14, pageEnd: 15, text: ''),
  ]);
}
