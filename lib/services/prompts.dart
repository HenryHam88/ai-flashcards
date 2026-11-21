/// 默认提示词模板。可在「我的 → 高级」中修改，并可一键恢复默认。
/// 占位符用 {{name}} 表示。
class Prompts {
  static const formulaRule = '''公式规则（必须遵守）：
- 所有数学符号、变量、公式一律用 LaTeX 书写：行内公式用 \$...\$，独立公式用 \$\$...\$\$。
- 禁止出现 x^2、dy/dx、sqrt(x) 这类裸写法；不要用 \\( \\) 或 \\[ \\]。
- 在 JSON 字符串中，LaTeX 的反斜杠必须写成两个，例如 "\\\\frac{1}{2}"。''';

  static const answerStyle = '''回答格式：
- 直接开始讲解，不要任何开场白或元话语（不要说「好的」「下面重写」「公式均使用 LaTeX」之类）。
- 用 Markdown：小标题只用 ## 或 ###，且不要太多；要点用列表；重点用 **粗体**。
- 公式用 \$...\$（行内）和 \$\$...\$\$（独立成行）。''';

  static const names = {
    'kp': '知识点提取',
    'gen': '闪卡与题目生成',
    'explain': 'AI 解释',
    'grade': '主观题批改',
  };

  static const defaults = {
    'kp': '''你是一名严谨的大学课程助教。阅读下面教材片段，提取其中的知识点（定义、定理、公式、方法、典型例题思路、易错点）。
教材：{{chapter}} {{section}}，第 {{pages}} 页。

$formulaRule

只输出 json，格式示例：
{"knowledge_points":[{"title":"条件概率","type":"定义","content":"设 \$P(B)>0\$，则 \$P(A\\\\mid B)=\\\\dfrac{P(AB)}{P(B)}\$","page":12}]}

要求：每个知识点 title 简短、不重复；content 忠于原文，可含公式；page 为该知识点所在页码。

教材片段：
{{text}}''',
    'gen': '''你是一名出题经验丰富的大学教师。根据下列知识点生成学习闪卡和练习题。

生成要求：
- 闪卡数量：{{card_count}} 张（正面是问题，背面是简洁答案）。
- 题目数量：{{question_count}} 道，题型只从这些中选：{{types}}。
- 难度：{{difficulty}}。
- 侧重点：{{focus}}。
- 用户的自定义要求：{{custom}}
- 每张闪卡和每道题都要有 explanation（解析）和 kp_index（对应下方知识点的序号）以及 page（出处页码）。
- 单选/多选：options 为 4 个选项文本（不要带 A. 前缀），answer 为字母，如 "B" 或 "AC"。
- 判断：options 为空，answer 为 "对" 或 "错"。
- 填空：题干用 ____ 表示空，answer 为标准答案，有多个等价写法时用 | 分隔。
- 简答/计算：answer 为参考答案（含关键步骤）。

$formulaRule

只输出 json，格式示例：
{"flashcards":[{"front":"什么是条件概率？","back":"\$P(A\\\\mid B)=\\\\dfrac{P(AB)}{P(B)}\$，其中 \$P(B)>0\$","explanation":"……","kp_index":0,"page":12}],
 "questions":[{"type":"单选","stem":"下列哪个是一阶线性微分方程？","options":["\$y'+y^2=0\$","\$y'+p(x)y=q(x)\$","\$y''+y=\\\\sin x\$","\$y'=ky^2\$"],"answer":"B","explanation":"……","difficulty":"基础","kp_index":1,"page":30}]}

知识点：
{{kps}}''',
    'explain': '''你是一位耐心的老师。学生在复习时对下面这个内容不理解，请结合教材原文讲清楚这个概念：先用通俗的话解释，再给出一个具体的例子，最后指出常见误区。篇幅适中，用中文。

$answerStyle

$formulaRule

学习内容：
{{item}}

教材原文（第 {{page}} 页）：
{{source}}''',
    'grade': '''你是一名阅卷老师。请根据参考答案批改学生的作答，满分 10 分，按要点和步骤给分。

$formulaRule

题目：{{stem}}
参考答案：{{answer}}
学生作答：{{user_answer}}

只输出 json，格式示例：{"score":7,"comment":"思路正确，但第二步求导有误……"}''',
  };

  static String fill(String tpl, Map<String, String> vars) {
    var s = tpl;
    vars.forEach((k, v) => s = s.replaceAll('{{$k}}', v));
    return s;
  }
}
