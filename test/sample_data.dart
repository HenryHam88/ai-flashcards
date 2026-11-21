import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';

/// 截图和演示用的示例数据（不调用任何 API）。
Future<void> seedSampleData(Repository repo) async {
  final now = DateTime.now();
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
