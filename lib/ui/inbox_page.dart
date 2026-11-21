import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';
import 'feedback_sheet.dart';
import '../help/help_articles.dart' show HelpIds;
import 'help_page.dart' show HelpButton;

/// 审核生成结果。
/// - 不传 ids：显示「待审核」里的内容（开启了「生成后先审核」时生成的）；
/// - 传 ids：审核刚生成、已经加入复习的这一批。
class InboxPage extends StatefulWidget {
  final String projectId;
  final List<String>? cardIds;
  final List<String>? questionIds;
  final String? summary; // 质检摘要，如「生成 30 张，自动修正 2 张，去重 3 张」
  const InboxPage({super.key, required this.projectId, this.cardIds, this.questionIds, this.summary});
  bool get isBatch => cardIds != null || questionIds != null;
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  List<Object> items = [];
  bool loading = true;
  final busy = <String>{};

  AppState get s => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = <Object>[];
    if (widget.isBatch) {
      for (final id in widget.cardIds ?? const <String>[]) {
        final c = await s.repo.card(id);
        if (c != null) out.add(c);
      }
      for (final id in widget.questionIds ?? const <String>[]) {
        final q = await s.repo.question(id);
        if (q != null) out.add(q);
      }
    } else {
      out
        ..addAll(await s.repo.inboxCards(projectId: widget.projectId))
        ..addAll(await s.repo.inboxQuestions(projectId: widget.projectId));
    }
    if (mounted) {
      setState(() {
        items = out;
        loading = false;
      });
    }
  }

  String idOf(Object o) => o is Flashcard ? o.id : (o as Question).id;

  Future<void> _save(Object item) async {
    if (widget.isBatch) {
      if (item is Flashcard) await s.repo.saveCards([item]);
      if (item is Question) await s.repo.saveQuestions([item]);
    } else {
      await s.repo.saveInbox([if (item is Flashcard) item], [if (item is Question) item]);
    }
  }

  Future<void> _delete(Object item) async {
    final id = idOf(item);
    if (widget.isBatch) {
      if (item is Flashcard) await s.repo.deleteCard(id);
      if (item is Question) await s.repo.deleteQuestion(id);
    } else {
      await s.repo.deleteInbox(id);
    }
    s.changed();
  }

  void _replace(Object old, Object neu) {
    final i = items.indexWhere((e) => idOf(e) == idOf(old));
    if (i >= 0) setState(() => items[i] = neu);
  }

  Future<void> _acceptAll() async {
    if (!widget.isBatch) {
      await s.repo.acceptInbox(items.whereType<Flashcard>().toList(), items.whereType<Question>().toList());
      s.changed();
    }
    if (!mounted) return;
    toast(context, widget.isBatch ? '这批内容已全部保留' : '已收下 ${items.length} 条，加入复习和测验');
    Navigator.pop(context);
  }

  Future<void> _rewrite(Object item) async {
    final id = idOf(item);
    setState(() => busy.add(id));
    try {
      final fixed = await s.aiRewrite(
          card: item is Flashcard ? item : null,
          q: item is Question ? item : null,
          reason: '用户要求换一种更好的写法：表述更清楚、答案严格依据原文，难度保持不变');
      if (fixed != null) {
        await _save(fixed);
        _replace(item, fixed);
      }
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    if (mounted) setState(() => busy.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    final nc = items.whereType<Flashcard>().length, nq = items.whereType<Question>().length;
    return GlassScaffold(
      title: widget.isBatch ? '审核这批' : '待审核',
      actions: const [HelpButton(HelpIds.quality)],
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Glass(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(children: [
                    Icon(Icons.verified_outlined, color: M.sageDark),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('闪卡 $nc · 题目 $nq', style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(widget.summary ?? '左滑删除，点「编辑」修改，或让 AI 重写', style: TextStyle(color: M.sub, fontSize: 12)),
                      ]),
                    ),
                  ]),
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? Center(child: Text('没有需要审核的内容', style: TextStyle(color: M.sub)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          final it = items[i];
                          final id = idOf(it);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Dismissible(
                              key: ValueKey(id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 24),
                                decoration:
                                    BoxDecoration(color: M.rose.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(22)),
                                child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                              ),
                              onDismissed: (_) async {
                                setState(() => items.removeAt(i));
                                await _delete(it);
                              },
                              child: Glass(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(it is Flashcard ? '闪卡' : (it as Question).type,
                                        style: TextStyle(color: M.sageDark, fontSize: 12, fontWeight: FontWeight.w600)),
                                    const Spacer(),
                                    Text(s.sourceLabel(
                                            it is Flashcard ? it.docId : (it as Question).docId,
                                            it is Flashcard ? it.page : (it as Question).page,
                                            it is Flashcard ? it.chapter : (it as Question).chapter,
                                            it is Flashcard ? it.section : (it as Question).section),
                                        style: TextStyle(color: M.sub, fontSize: 11)),
                                  ]),
                                  const SizedBox(height: 6),
                                  ItemPreview(item: it, compact: true),
                                  const SizedBox(height: 6),
                                  if (busy.contains(id))
                                    const LinearProgressIndicator(minHeight: 2)
                                  else
                                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                      TextButton.icon(
                                        onPressed: () async {
                                          final r = await showItemEditor(context,
                                              card: it is Flashcard ? it : null, question: it is Question ? it : null, save: _save);
                                          if (r != null) _replace(it, r);
                                        },
                                        icon: const Icon(Icons.edit_outlined, size: 18),
                                        label: const Text('编辑'),
                                      ),
                                      TextButton.icon(
                                        onPressed: () => _rewrite(it),
                                        icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                                        label: const Text('AI 重写这张'),
                                      ),
                                    ]),
                                ]),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (items.isNotEmpty)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: GlassButton(
                      label: widget.isBatch ? '没问题，完成' : '全部收下（${items.length}）',
                      icon: Icons.done_all_rounded,
                      tint: M.sage,
                      expand: true,
                      onTap: _acceptAll,
                    ),
                  ),
                ),
            ]),
    );
  }
}

