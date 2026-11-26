import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/pipeline.dart';
import '../theme/glass.dart';
import 'explain_sheet.dart';
import 'favorites_page.dart' show FavoriteButton;
import 'feedback_sheet.dart';

/// 测验页。当前题号和每题作答都持久化，返回/重进不会回到第一题。
class QuizPage extends StatefulWidget {
  final String? projectId; // null：跨项目（如全部错题），此时需传 questionIds
  final List<String>? questionIds;
  final String? sessionKey;
  final String? chapter;
  const QuizPage({super.key, this.projectId, this.questionIds, this.sessionKey, this.chapter});
  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  List<Question> qs = [];
  int index = 0;
  bool loading = true;
  Map<String, Map<String, dynamic>> answers = {};
  Set<int> picked = {};
  final input = TextEditingController();
  bool grading = false;
  late final SessionTimer timer; // 统计学习时长

  AppState get s => context.read<AppState>();
  String get key => widget.sessionKey ?? '${widget.projectId ?? 'mixed'}_${widget.chapter ?? 'all'}';

  @override
  void initState() {
    super.initState();
    timer = s.startSession(widget.projectId, 'quiz');
    _init();
  }

  @override
  void dispose() {
    timer.end();
    super.dispose();
  }

  Future<void> _init() async {
    final saved = s.settings.quizSession(key);
    List<String> ids;
    if (saved != null) {
      ids = (saved['ids'] as List).cast<String>();
      index = saved['index'] as int;
      answers = ((saved['answers'] as Map?) ?? {}).map(
        (k, v) => MapEntry(k.toString(), (v as Map).cast<String, dynamic>()),
      );
    } else if (widget.questionIds != null) {
      ids = widget.questionIds!;
    } else {
      final all = await s.repo.questions(projectId: widget.projectId);
      ids = all.where((q) => !q.suspended && (widget.chapter == null || q.chapter == widget.chapter)).map((q) => q.id).toList();
    }
    for (final id in ids) {
      final q = await s.repo.question(id);
      if (q != null) qs.add(q);
    }
    if (index > qs.length) index = qs.length;
    loading = false;
    _persist();
    if (mounted) setState(() {});
  }

  void _persist() {
    if (index >= qs.length) {
      s.settings.setQuizSession(key, null);
    } else {
      s.settings.setQuizSession(key, {'ids': qs.map((q) => q.id).toList(), 'index': index, 'answers': answers});
    }
  }

  Future<void> _submit(Question q, String userAnswer) async {
    if (answers.containsKey(q.id)) return;
    timer.touch();
    if (QType.isObjective(q.type)) {
      final ok = gradeObjective(q, userAnswer);
      answers[q.id] = {'answer': userAnswer, 'correct': ok};
      await s.recordAnswer(q, ok, userAnswer);
    } else {
      setState(() => grading = true);
      try {
        final (score, comment) = await s.gradeSubjective(q, userAnswer);
        final ok = score >= 6;
        answers[q.id] = {'answer': userAnswer, 'correct': ok, 'score': score, 'comment': comment};
        await s.recordAnswer(q, ok, userAnswer);
      } catch (e) {
        if (mounted) toast(context, 'AI 批改失败：$e');
      }
      grading = false;
    }
    _persist();
    if (mounted) setState(() {});
  }

  void _prev() {
    if (index == 0) return;
    setState(() {
      index--;
      picked = {};
      input.clear();
    });
    _persist();
  }

  void _next() {
    setState(() {
      index++;
      picked = {};
      input.clear();
    });
    _persist();
  }

  /// 键盘：1–4（或 A–D）选选项，判断题 1 = 对、2 = 错；回车提交多选 / 下一题；← → 上一题 / 下一题。
  /// 填空和解答题要打字，不绑定按键。
  Map<ShortcutActivator, VoidCallback> _keys() {
    if (loading || index >= qs.length) return const {};
    final q = qs[index];
    final answered = answers.containsKey(q.id);
    final isChoice = q.type == QType.single || q.type == QType.multi;
    if (!isChoice && q.type != QType.judge) return const {};
    SingleActivator k(LogicalKeyboardKey key) => SingleActivator(key, includeRepeats: false);
    void choose(int i) {
      if (answered) return;
      if (q.type == QType.judge) {
        if (i < 2) _submit(q, i == 0 ? '对' : '错');
        return;
      }
      if (i >= q.options.length) return;
      final letter = String.fromCharCode(65 + i);
      if (q.type == QType.single) {
        _submit(q, letter);
      } else {
        setState(() => picked.contains(i) ? picked.remove(i) : picked.add(i));
      }
    }

    void enter() {
      if (answered) {
        _next();
      } else if (q.type == QType.multi && picked.isNotEmpty) {
        _submit(q, (picked.toList()..sort()).map((i) => String.fromCharCode(65 + i)).join());
      }
    }

    final digits = [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6];
    final letters = [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyB, LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.keyE, LogicalKeyboardKey.keyF];
    return {
      for (var i = 0; i < digits.length; i++) k(digits[i]): () => choose(i),
      if (isChoice)
        for (var i = 0; i < letters.length; i++) k(letters[i]): () => choose(i),
      k(LogicalKeyboardKey.enter): enter,
      k(LogicalKeyboardKey.arrowLeft): _prev,
      k(LogicalKeyboardKey.arrowRight): () => answered ? _next() : null,
    };
  }

  @override
  Widget build(BuildContext context) =>
      CallbackShortcuts(bindings: _keys(), child: Focus(autofocus: true, child: _scaffold()));

  Widget _scaffold() {
    final done = !loading && index >= qs.length;
    return GlassScaffold(
      deskMax: 820,
      title: loading || done ? '测验' : '测验  ${index + 1}/${qs.length}',
      leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
      actions: [
        if (!loading && !done)
          FavoriteButton(kind: 'question', targetId: qs[index].id, projectId: qs[index].projectId, title: qs[index].stem),
        if (!loading && !done)
          IconButton(
            tooltip: '这道题有问题',
            icon: Icon(qs[index].flag.isEmpty ? Icons.flag_outlined : Icons.flag_rounded),
            onPressed: () async {
              final q = qs[index];
              final r = await showFeedbackSheet(context, question: q);
              if (r is Question && mounted) setState(() => qs[index] = r);
            },
          ),
        if (!loading && !done)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (v) async {
              final q = qs[index];
              if (v == 'src') {
                showSourceSheet(context, docId: q.docId, page: q.page, chapter: q.chapter, section: q.section);
              } else {
                await s.mark(q: q, mark: v);
                if (mounted) toast(context, '已标记为「$v」');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'src', child: Text('查看原文')),
              PopupMenuItem(value: '不确定', child: Text('标记：不确定')),
              PopupMenuItem(value: 'AI出错了', child: Text('标记：AI出错了')),
            ],
          ),
      ],
      body: loading
          ? Center(child: CircularProgressIndicator(color: M.sage))
          : done
          ? _summary()
          : _question(qs[index]),
    );
  }

  Widget _question(Question q) {
    final a = answers[q.id];
    final answered = a != null;
    final correct = a?['correct'] == true;
    final isChoice = q.type == QType.single || q.type == QType.multi;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Glass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.description_outlined, size: 20, color: M.text),
                    const SizedBox(width: 8),
                    Text('${q.type}题', style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text(q.difficulty, style: TextStyle(color: M.sub, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 12),
                MathText(q.stem, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.5)),
                const SizedBox(height: 12),
                if (isChoice)
                  for (var i = 0; i < q.options.length; i++) _option(q, i, a),
                if (q.type == QType.judge)
                  Row(
                    children: [
                      for (final v in ['对', '错']) ...[
                        Expanded(
                          child: GlassButton(
                            label: v,
                            tint: answered && q.answer == v ? M.sage : (answered && a['answer'] == v ? M.rose : null),
                            onTap: answered ? null : () => _submit(q, v),
                          ),
                        ),
                        if (v == '对') const SizedBox(width: 12),
                      ],
                    ],
                  ),
                if (!isChoice && q.type != QType.judge) ...[
                  if (!answered)
                    TextField(
                      controller: input,
                      minLines: QType.isObjective(q.type) ? 1 : 4,
                      maxLines: QType.isObjective(q.type) ? 2 : 10,
                      decoration: InputDecoration(
                        hintText: q.type == QType.fill ? '填写答案（公式可用 \$...\$）' : '写下你的解答，AI 会按步骤批改',
                      ),
                    ),
                  if (answered) MathText('你的作答：${a['answer']}', style: TextStyle(color: M.sub, height: 1.5)),
                ],
                if (q.type == QType.multi && !answered) ...[
                  const SizedBox(height: 8),
                  GlassButton(
                    label: '提交',
                    tint: M.sage,
                    expand: true,
                    onTap: picked.isEmpty
                        ? null
                        : () => _submit(q, (picked.toList()..sort()).map((i) => String.fromCharCode(65 + i)).join()),
                  ),
                ],
                if (!isChoice && q.type != QType.judge && !answered) ...[
                  const SizedBox(height: 10),
                  grading
                      ? Center(
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: Text('AI 正在批改…', style: TextStyle(color: M.sub)),
                          ),
                        )
                      : GlassButton(
                          label: QType.isObjective(q.type) ? '提交' : '提交并让 AI 批改',
                          tint: M.sage,
                          expand: true,
                          onTap: () => input.text.trim().isEmpty ? null : _submit(q, input.text.trim()),
                        ),
                ],
              ],
            ),
          ),
          if (answered) ...[
            const SizedBox(height: 12),
            Glass(
              tint: null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        correct ? Icons.check_circle_rounded : Icons.cancel_rounded,
                        color: correct ? M.sageDark : M.roseDark,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        a['score'] != null ? 'AI 评分：${a['score']} / 10' : (correct ? '回答正确' : '回答错误，已加入错题本'),
                        style: TextStyle(fontWeight: FontWeight.w700, color: correct ? M.sageDark : M.roseDark),
                      ),
                    ],
                  ),
                  if (a['comment'] != null) ...[
                    const SizedBox(height: 8),
                    MathText('${a['comment']}', style: const TextStyle(height: 1.5)),
                  ],
                  if (!isChoice) ...[
                    const SizedBox(height: 8),
                    MathText('参考答案：${q.answer.replaceAll('|', ' 或 ')}', style: const TextStyle(height: 1.5)),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.menu_book_outlined, size: 18, color: M.text),
                      SizedBox(width: 6),
                      Text('解析', style: TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  MathText(
                    q.explanation.isEmpty ? '（暂无解析）' : q.explanation,
                    style: const TextStyle(fontSize: 14, height: 1.6),
                  ),
                  if (q.page > 0)
                    TextButton(
                      onPressed: () => showSourceSheet(context, docId: q.docId, page: q.page, chapter: q.chapter, section: q.section),
                      child: Text('出处：${s.sourceLabel(q.docId, q.page, q.chapter, q.section)} · 查看原文', style: TextStyle(color: M.sageDark)),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              // 上一题：只读回看（显示当时的作答和结果，不重新判分、不重复记错题）
              GlassButton(label: '上一题', icon: Icons.undo_rounded, onTap: index > 0 ? _prev : null),
              const SizedBox(width: 10),
              Expanded(
                child: GlassButton(
                  label: 'AI 解释',
                  icon: Icons.auto_awesome_rounded,
                  onTap: () => showExplainSheet(context, question: q),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GlassButton(label: '下一题 →', onTap: answered ? _next : null),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _option(Question q, int i, Map<String, dynamic>? a) {
    final letter = String.fromCharCode(65 + i);
    final answered = a != null;
    final isAnswer = q.answer.contains(letter);
    final chosen = answered ? (a['answer'] as String).contains(letter) : picked.contains(i);
    Color? tint;
    if (answered && isAnswer) tint = M.sage;
    if (answered && chosen && !isAnswer) tint = M.rose;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 16,
        tint: tint,
        opacity: chosen && !answered ? 0.7 : 0.42,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: answered
            ? null
            : () {
                if (q.type == QType.single) {
                  _submit(q, letter);
                } else {
                  setState(() => chosen ? picked.remove(i) : picked.add(i));
                }
              },
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: answered && isAnswer ? M.sageDark : M.glass.withValues(alpha: chosen ? 0.95 : 0.6),
              ),
              child: answered && isAnswer
                  ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                  : Text(letter, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 12),
            Expanded(child: MathText(q.options[i], style: const TextStyle(fontSize: 16))),
          ],
        ),
      ),
    );
  }

  Widget _summary() {
    final total = answers.length;
    final right = answers.values.where((a) => a['correct'] == true).length;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Glass(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.emoji_events_outlined, color: M.sageDark, size: 40),
              const SizedBox(height: 12),
              Text(
                qs.isEmpty ? '还没有题目' : '完成！答对 $right / $total',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (qs.isNotEmpty) ...[
                    GlassButton(label: '上一题', icon: Icons.undo_rounded, onTap: _prev),
                    const SizedBox(width: 12),
                  ],
                  GlassButton(label: '返回', onTap: () => Navigator.pop(context)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
