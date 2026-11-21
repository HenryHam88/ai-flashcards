import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';

/// 编辑一张卡 / 一道题。返回修改后的对象（已保存到 [save] 指定的位置），取消返回 null。
Future<Object?> showItemEditor(BuildContext context,
    {Flashcard? card, Question? question, Future<void> Function(Object item)? save}) {
  return showGlassSheet<Object>(context, (ctx, sc) => _Editor(card: card, question: question, save: save, controller: sc),
      initial: 0.85, maxSize: 0.95);
}

class _Editor extends StatefulWidget {
  final Flashcard? card;
  final Question? question;
  final Future<void> Function(Object item)? save;
  final ScrollController controller;
  const _Editor({this.card, this.question, this.save, required this.controller});
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final a = TextEditingController(text: widget.card?.front ?? widget.question!.stem);
  late final b = TextEditingController(text: widget.card?.back ?? widget.question!.answer);
  late final e = TextEditingController(text: widget.card?.explanation ?? widget.question!.explanation);
  late final opts = [for (final o in widget.question?.options ?? const <String>[]) TextEditingController(text: o)];

  Object _build() {
    if (widget.card != null) {
      return Flashcard.fromJson({...widget.card!.toJson(), 'front': a.text.trim(), 'back': b.text.trim(), 'explanation': e.text.trim()});
    }
    final q = widget.question!;
    var ans = b.text.trim();
    if (q.type == QType.single || q.type == QType.multi) ans = ans.toUpperCase().replaceAll(RegExp(r'[^A-F]'), '');
    return Question.fromJson({
      ...q.toJson(),
      'stem': a.text.trim(),
      'answer': ans,
      'explanation': e.text.trim(),
      'options': [for (final c in opts) c.text.trim()],
    });
  }

  @override
  Widget build(BuildContext context) {
    final isCard = widget.card != null;
    final q = widget.question;
    Widget field(String label, TextEditingController c, {int lines = 3}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(controller: c, minLines: 1, maxLines: lines, decoration: InputDecoration(labelText: label)),
        );
    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
      Text(isCard ? '编辑闪卡' : '编辑题目（${q!.type}）', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(r'公式用 $...$ 书写，例如 $\frac{1}{2}$', style: TextStyle(color: M.sub, fontSize: 12)),
      const SizedBox(height: 12),
      field(isCard ? '正面（问题）' : '题干', a, lines: 6),
      for (var i = 0; i < opts.length; i++) field('选项 ${String.fromCharCode(65 + i)}', opts[i]),
      field(
          isCard
              ? '背面（答案）'
              : (q!.type == QType.single || q.type == QType.multi)
                  ? '答案（字母，如 B 或 AC）'
                  : (q.type == QType.judge ? '答案（对 / 错）' : '参考答案'),
          b,
          lines: 6),
      field('解析', e, lines: 8),
      GlassButton(
        label: '保存',
        icon: Icons.check_rounded,
        tint: M.sage,
        expand: true,
        onTap: () async {
          final item = _build();
          await widget.save?.call(item);
          if (context.mounted) Navigator.pop(context, item);
        },
      ),
    ]);
  }
}

/// 「这张有问题」：选原因 + 备注，可暂停、编辑或让 AI 修正。返回更新后的对象（可能为 null）。
Future<Object?> showFeedbackSheet(BuildContext context, {Flashcard? card, Question? question}) {
  return showGlassSheet<Object>(context, (ctx, sc) => _FeedbackBody(card: card, question: question, controller: sc),
      initial: 0.72, maxSize: 0.95);
}

class _FeedbackBody extends StatefulWidget {
  final Flashcard? card;
  final Question? question;
  final ScrollController controller;
  const _FeedbackBody({this.card, this.question, required this.controller});
  @override
  State<_FeedbackBody> createState() => _FeedbackBodyState();
}

class _FeedbackBodyState extends State<_FeedbackBody> {
  String reason = FeedbackEntry.reasons.first;
  final note = TextEditingController();
  bool suspend = false;
  bool busy = false;

  AppState get s => context.read<AppState>();

  Future<void> _saveItem(Object item) async {
    if (item is Flashcard) {
      await s.repo.saveCards([item]);
    } else if (item is Question) {
      await s.repo.saveQuestions([item]);
    }
  }

  Future<void> _submit({String then = ''}) async {
    setState(() => busy = true);
    try {
      await s.submitFeedback(card: widget.card, q: widget.question, reason: reason, note: note.text.trim(), suspend: suspend);
      Object? result = widget.card ?? widget.question;
      if (!mounted) return;
      if (then == 'edit') {
        result = await showItemEditor(context, card: widget.card, question: widget.question, save: _saveItem) ?? result;
      } else if (then == 'ai') {
        final why = '用户反馈：$reason${note.text.trim().isEmpty ? '' : '（${note.text.trim()}）'}';
        final fixed = await s.aiRewrite(card: widget.card, q: widget.question, reason: why);
        if (!mounted) return;
        final ok = await _confirmFix(fixed!);
        if (ok == true) {
          await _saveItem(fixed);
          result = fixed;
        }
      }
      s.changed();
      if (!mounted) return;
      Navigator.pop(context, result);
      toast(context, suspend ? '已记录并暂停，之后不会再出现；后续出题会避开这类问题' : '已记录，后续出题会避开这类问题');
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<bool?> _confirmFix(Object fixed) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('AI 修改后的内容'),
          content: SingleChildScrollView(child: ItemPreview(item: fixed)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不用了')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('替换原来的')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final isCard = widget.card != null;
    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
      Row(children: [
        Icon(Icons.flag_outlined, color: M.roseDark),
        const SizedBox(width: 8),
        Text(isCard ? '这张有问题' : '这道题有问题', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 4),
      Text('反馈会记下来，之后给这个项目出题时自动避开同类问题。', style: TextStyle(color: M.sub, fontSize: 13)),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final r in FeedbackEntry.reasons)
          ChoiceChip(
            label: Text(r),
            selected: reason == r,
            showCheckmark: false,
            selectedColor: M.rose.withValues(alpha: 0.55),
            onSelected: (_) => setState(() => reason = r),
          ),
      ]),
      const SizedBox(height: 12),
      TextField(
          controller: note,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '补充说明（可选），比如「正确答案应该是 C」')),
      const SizedBox(height: 6),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: suspend,
        onChanged: (v) => setState(() => suspend = v),
        activeThumbColor: M.sageDark,
        title: Text(isCard ? '暂停这张卡' : '暂停这道题', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('不再出现在复习 / 测验里，可在资料页恢复', style: TextStyle(color: M.sub, fontSize: 12)),
      ),
      const SizedBox(height: 10),
      if (busy)
        Padding(padding: const EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(color: M.sage)))
      else ...[
        GlassButton(label: '提交反馈', icon: Icons.send_rounded, tint: M.sage, expand: true, onTap: () => _submit()),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: GlassButton(label: '提交并编辑', icon: Icons.edit_outlined, onTap: () => _submit(then: 'edit'))),
          const SizedBox(width: 10),
          Expanded(child: GlassButton(label: '提交并 AI 修正', icon: Icons.auto_fix_high_rounded, onTap: () => _submit(then: 'ai'))),
        ]),
      ],
    ]);
  }
}

/// 卡片 / 题目的紧凑预览（审核、确认修改时用）。
class ItemPreview extends StatelessWidget {
  final Object item;
  final bool compact;
  const ItemPreview({super.key, required this.item, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final it = item;
    final small = TextStyle(color: M.sub, fontSize: 13, height: 1.5);
    if (it is Flashcard) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MathText(it.front, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, height: 1.5)),
        const SizedBox(height: 6),
        MathText(it.back, style: const TextStyle(fontSize: 14, height: 1.5)),
        if (!compact && it.explanation.isNotEmpty) ...[const SizedBox(height: 6), MathText(it.explanation, style: small)],
      ]);
    }
    final q = it as Question;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      MathText(q.stem, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, height: 1.5)),
      for (var i = 0; i < q.options.length; i++)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: MathText('${String.fromCharCode(65 + i)}. ${q.options[i]}',
              style: TextStyle(
                  fontSize: 14,
                  color: q.answer.contains(String.fromCharCode(65 + i)) ? M.sageDark : null,
                  fontWeight: q.answer.contains(String.fromCharCode(65 + i)) ? FontWeight.w700 : null)),
        ),
      if (q.options.isEmpty) ...[
        const SizedBox(height: 6),
        MathText('答案：${q.answer}', style: TextStyle(fontSize: 14, color: M.sageDark, fontWeight: FontWeight.w600)),
      ],
      if (!compact && q.explanation.isNotEmpty) ...[const SizedBox(height: 6), MathText(q.explanation, style: small)],
    ]);
  }
}
