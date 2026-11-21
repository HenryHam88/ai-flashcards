import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/help/help_articles.dart';

import 'sample_data.dart';

/// 典型公式写法（含各种分隔符、环境、\text、转义、实体）。
const typicalFormulas = <String>[
  r'设 $P(B)>0$，称 $P(A\mid B)=\frac{P(AB)}{P(B)}$ 为条件概率。',
  r'$$\sum_{i=1}^{n} P(A_i)=1$$',
  r'分布律 $P\{X=k\}=\binom{n}{k}p^k(1-p)^{n-k}$，$k=0,1,\dots,n$',
  r'$0<p<1$ 且 $x>0$',
  r'$0&lt;p&lt;1$',
  r'矩阵 $$\begin{pmatrix}1 & 2\\3 & 4\end{pmatrix}$$ 与 $\begin{bmatrix}a&b\\c&d\end{bmatrix}$',
  r'$$f(x)=\begin{cases}1, & x>0\\0, & x\le 0\end{cases}$$',
  r'$$\begin{aligned}a&=b+c\\&=d\end{aligned}$$',
  r'$\text{当 } x \to 0 \text{ 时}$，$\lim_{x\to0}\frac{\sin x}{x}=1$',
  r'行内 \(E(X)=\sum x_i p_i\) 与独立 \[D(X)=E(X^2)-[E(X)]^2\]',
  r'价格 \$5 和 $\$x$',
  r'$\int_0^1 x\,dx=\frac12$ **重点** *斜体* `code $x$`',
  r'$\mathrm{Var}(X)$, $\mathbb{R}$, $\vec{a}\cdot\vec{b}$, $\overline{X}$, $\hat\theta$',
  r'$\texttt{print}$ 与 $\textbf{A}$、$\textit{b}$',
  r'$a_{ij}$ 和 $x^{2}$ 以及 $$\left(\frac{a}{b}\right)^2$$',
  r'未闭合 $x+1 后面是文字',
  r'$$ $$ 空公式 $ $',
  r'$\sqrt[3]{x}$ $\iint_D f\,d\sigma$ $\oint$ $\prod_{k=1}^n k$',
  r'$\{x \mid x>0\}$ 与 $\lbrace a \rbrace$',
  "多行\n\$\$\nE(X)=\\int_{-\\infty}^{+\\infty} x f(x)\\,dx\n\$\$\n结束",
];

/// 收集现有所有示例数据中的文字：示例项目、章节页、表格页、帮助文章和典型公式。
Future<List<String>> mathCorpus() async {
  final repo = Repository(MemoryDocStore());
  await seedSampleData(repo);
  await seedTablePages(repo);
  final out = <String>{};
  void walk(Object? v) {
    if (v is String) {
      // 时间戳每次运行都不同，不算语料
      if (v.trim().isNotEmpty && !RegExp(r'^\d{4}-\d\d-\d\d').hasMatch(v)) out.add(v);
    } else if (v is Map) {
      v.values.forEach(walk);
    } else if (v is List) {
      v.forEach(walk);
    }
  }

  for (final c in ['cards', 'chapters', 'chunks', 'docs', 'explain', 'feedback', 'inbox_cards', 'inbox_questions', 'kps',
    'pages', 'projects', 'questions', 'wrong']) {
    for (final r in await repo.store.rows(c)) {
      walk(r.$3);
    }
  }
  for (final a in helpArticles) {
    out.add(a.body);
  }
  out.addAll(typicalFormulas);
  final l = out.toList()..sort();
  return l;
}
