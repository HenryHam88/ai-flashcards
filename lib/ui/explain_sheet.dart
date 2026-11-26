import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/llm.dart';
import '../theme/glass.dart';
import 'ai_widgets.dart';
import 'quiz_page.dart';

/// 查看教材原文（半屏面板）。
Future<void> showSourceSheet(BuildContext context, {required String docId, required int page, String chapter = '', String section = ''}) async {
  final s = context.read<AppState>();
  final text = await s.sourceText(docId, page);
  if (!context.mounted) return;
  final word = s.repo.isWordDoc(docId) || s.repo.isTextDoc(docId); // 出处文字里已含章节名
  await showGlassSheet(context, (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.all(20), children: [
        Text('原文出处 · ${s.sourceLabel(docId, page, chapter, section)}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        if (chapter.isNotEmpty && !word) Text(chapter, style: TextStyle(color: M.sub)),
        const SizedBox(height: 12),
        MathText(text.isEmpty ? '没有找到这一页的解析结果。' : text, style: const TextStyle(fontSize: 15, height: 1.6)),
      ]), side: true);
}

/// AI 解释：半屏毛玻璃面板，盖在当前闪卡/题目上方，不跳转路由。
/// 关闭后底下的页面状态（当前第几张）完全不变。
Future<void> showExplainSheet(BuildContext context, {Flashcard? card, Question? question}) {
  return showGlassSheet(context, (ctx, sc) => _ExplainBody(card: card, question: question, controller: sc), initial: 0.55, side: true);
}

class _ExplainBody extends StatefulWidget {
  final Flashcard? card;
  final Question? question;
  final ScrollController controller;
  const _ExplainBody({this.card, this.question, required this.controller});
  @override
  State<_ExplainBody> createState() => _ExplainBodyState();
}

class _ExplainBodyState extends State<_ExplainBody> {
  ExplainCache? cache;
  String? error;
  bool busy = true;
  final input = TextEditingController();
  final run = AiRun();
  String? pending; // 正在等回答的追问

  @override
  void dispose() {
    run.dispose();
    input.dispose();
    super.dispose();
  }

  String get itemId => widget.card?.id ?? widget.question!.id;
  String get projectId => widget.card?.projectId ?? widget.question!.projectId;
  String get kpId => widget.card?.kpId ?? widget.question!.kpId;

  String get itemText {
    final c = widget.card;
    if (c != null) return '闪卡问题：${c.front}\n答案：${c.back}';
    final q = widget.question!;
    final opts = [for (var i = 0; i < q.options.length; i++) '${String.fromCharCode(65 + i)}. ${q.options[i]}'].join('\n');
    return '${q.type}题：${q.stem}\n$opts\n参考答案：${q.answer}\n解析：${q.explanation}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await context.read<AppState>().explain(
          itemId: itemId,
          projectId: projectId,
          itemText: itemText,
          docId: widget.card?.docId ?? widget.question!.docId,
          page: widget.card?.page ?? widget.question!.page,
          kind: widget.card != null ? 'card' : 'question',
          title: widget.card?.front ?? widget.question!.stem,
          io: run.start());
      if (mounted) setState(() => cache = c);
    } on LlmCancelled {
      if (mounted) setState(() => error = '已停止。关掉面板再打开可以重新生成。');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    run.finish();
    if (mounted) setState(() => busy = false);
  }

  Future<void> _ask() async {
    final q = input.text.trim();
    if (q.isEmpty || cache == null) return;
    setState(() => (busy = true, pending = q));
    input.clear();
    try {
      final c = await context.read<AppState>().followUp(cache!, q, io: run.start());
      if (mounted) setState(() => cache = c);
    } on LlmCancelled {
      if (mounted) toast(context, '已停止');
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    run.finish();
    if (mounted) setState(() => (busy = false, pending = null));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final msgs = cache?.messages.skip(1).toList() ?? [];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
        child: Row(children: [
          Icon(Icons.auto_awesome_rounded, color: M.sageDark, size: 20),
          const SizedBox(width: 8),
          const Text('AI 解释', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const Spacer(),
          IconButton(onPressed: () => Navigator.pop(context), icon: Icon(Icons.close_rounded, color: M.sub)),
        ]),
      ),
      Expanded(
        child: ListView(controller: widget.controller, padding: const EdgeInsets.symmetric(horizontal: 20), children: [
          if (error != null) Text(error!, style: TextStyle(color: M.roseDark)),
          for (final m in msgs)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ChatMessageView(text: m['content']!, user: m['role'] == 'user', sources: sourcesOf(m)),
            ),
          if (pending != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Align(
                  alignment: Alignment.centerRight,
                  child: Glass(
                      tint: M.greyBlue,
                      radius: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(pending!, style: const TextStyle(color: Colors.white)))),
            ),
          if (busy) Padding(padding: const EdgeInsets.only(bottom: 10), child: AiRunView(run: run, idle: aiIdleText(s))),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: GlassButton(
                label: '加入错题本',
                icon: Icons.bookmark_add_outlined,
                onTap: () async {
                  await s.mark(q: widget.question, card: widget.question == null ? widget.card : null, mark: '不确定');
                  if (context.mounted) toast(context, '已加入错题本');
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GlassButton(
                label: '生成相关题目',
                icon: Icons.add_task_rounded,
                onTap: () async {
                  toast(context, '正在生成…');
                  try {
                    final qs = await s.relatedQuestions(projectId, kpId);
                    if (!context.mounted) return;
                    // 新题在面板之上的新页面里做，返回后面板和原卡片都还在
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => QuizPage(projectId: projectId, questionIds: qs.map((e) => e.id).toList(), sessionKey: 'related_$kpId')));
                  } catch (e) {
                    if (context.mounted) toast(context, '$e');
                  }
                },
              ),
            ),
          ]),
          const SizedBox(height: 16),
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 10 + MediaQuery.of(context).viewInsets.bottom),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: input,
                    onSubmitted: (_) => _ask(),
                    decoration: const InputDecoration(hintText: '继续追问，比如「再讲简单点」'))),
            const SizedBox(width: 8),
            IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: M.sage),
                onPressed: busy ? null : _ask,
                icon: const Icon(Icons.send_rounded)),
          ]),
        ),
      ),
    ]);
  }
}
