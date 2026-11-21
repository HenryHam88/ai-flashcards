import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';
import 'explain_sheet.dart';
import 'quiz_page.dart';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  return '${t.month} 月 ${t.day} 日';
}

/// 把 Markdown / LaTeX 粗略压成一行纯文本，用于列表预览。
String plainPreview(String md) => stripMetaPreamble(md)
    .replaceAllMapped(RegExp(r'\$\$?([^$]*)\$\$?'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'\\(?:d?frac|tfrac)\{([^{}]*)\}\{([^{}]*)\}'), (m) => '${m[1]}/${m[2]}')
    .replaceAll(RegExp(r'\\(mid)\b'), '|')
    .replaceAll(RegExp(r'[{}]'), '')
    .replaceAll(RegExp(r'[#*_`>]+'), '')
    .replaceAll(RegExp(r'\\[a-zA-Z]+'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// 解释历史：所有 AI 解释和追问，最新在前。
class ExplainHistoryPage extends StatefulWidget {
  const ExplainHistoryPage({super.key});
  @override
  State<ExplainHistoryPage> createState() => _ExplainHistoryPageState();
}

class _ExplainHistoryPageState extends State<ExplainHistoryPage> {
  List<ExplainCache> all = [];
  Map<String, String> projectNames = {};
  String? project;
  bool starredOnly = false;
  String query = '';
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final l = await s.repo.explainHistory();
    final ps = await s.repo.projects();
    if (!mounted) return;
    setState(() {
      all = l;
      projectNames = {for (final p in ps) p.id: p.name};
      loading = false;
    });
  }

  List<ExplainCache> get shown {
    final q = query.trim().toLowerCase();
    return all.where((e) {
      if (project != null && e.projectId != project) return false;
      if (starredOnly && !e.starred) return false;
      if (q.isEmpty) return true;
      return e.title.toLowerCase().contains(q) ||
          e.messages.skip(1).any((m) => (m['content'] ?? '').toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空解释历史？'),
        content: Text(starredOnly || project != null
            ? '将删除当前筛选下的 ${shown.length} 条记录（已收藏的保留）。'
            : '将删除全部 ${all.where((e) => !e.starred).length} 条未收藏的记录，已收藏的保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text('清空', style: TextStyle(color: M.roseDark))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final repo = context.read<AppState>().repo;
    for (final e in shown.where((e) => !e.starred)) {
      await repo.deleteExplain(e.id);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = shown;
    return GlassScaffold(
      title: '解释历史',
      actions: [
        IconButton(
          tooltip: '只看收藏',
          onPressed: () => setState(() => starredOnly = !starredOnly),
          icon: Icon(starredOnly ? Icons.star_rounded : Icons.star_border_rounded,
              color: starredOnly ? M.oat.withValues(alpha: 1) : M.text),
        ),
        PopupMenuButton<String>(
          onSelected: (_) => _clearAll(),
          itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('清空历史'))],
        ),
      ],
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: TextField(
            onChanged: (v) => setState(() => query = v),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: '搜索题目或解释内容'),
          ),
        ),
        if (projectNames.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 0, 8),
            child: ProjectFilterChips(
              projects: [for (final e in projectNames.entries) (e.key, e.value)],
              value: project,
              onChanged: (v) => setState(() => project = v),
            ),
          ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Text(
                            all.isEmpty ? '还没有解释记录。\n复习或答题时点「AI 解释」，解释和追问都会保存在这里。' : '没有符合条件的记录',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: M.sub, height: 1.7)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _HistoryTile(
                        e: items[i],
                        project: projectNames[items[i].projectId] ?? '',
                        onChanged: _load,
                      ),
                    ),
        ),
      ]),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final ExplainCache e;
  final String project;
  final VoidCallback onChanged;
  const _HistoryTile({required this.e, required this.project, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final repo = context.read<AppState>().repo;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Dismissible(
        key: ValueKey(e.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          decoration: BoxDecoration(color: M.rose.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(22)),
          child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
        ),
        onDismissed: (_) async {
          await repo.deleteExplain(e.id);
          onChanged();
        },
        child: Glass(
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExplainThreadPage(entry: e)));
            onChanged();
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(e.kind == 'question' ? Icons.quiz_outlined : Icons.style_outlined, size: 16, color: M.sageDark),
              const SizedBox(width: 6),
              Expanded(
                child: Text(e.kind == 'question' ? '题目' : (e.kind == 'gone' ? '已删除' : '闪卡'),
                    style: TextStyle(color: M.sageDark, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              if (e.starred) Icon(Icons.star_rounded, size: 18, color: M.oat.withValues(alpha: 1)),
            ]),
            const SizedBox(height: 6),
            Text(plainPreview(e.title), maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, height: 1.4)),
            const SizedBox(height: 4),
            Text(plainPreview(e.firstAnswer), maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: M.sub, fontSize: 13, height: 1.45)),
            const SizedBox(height: 8),
            Text(
                [if (project.isNotEmpty) project, _ago(e.updatedAt), if (e.followUps > 0) '追问 ${e.followUps} 次'].join(' · '),
                style: TextStyle(color: M.sub, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// 一条解释的完整对话，可以继续追问。
class ExplainThreadPage extends StatefulWidget {
  final ExplainCache entry;
  const ExplainThreadPage({super.key, required this.entry});
  @override
  State<ExplainThreadPage> createState() => _ExplainThreadPageState();
}

class _ExplainThreadPageState extends State<ExplainThreadPage> {
  late ExplainCache e = widget.entry;
  final input = TextEditingController();
  final sc = ScrollController();
  bool busy = false;

  Future<void> _ask() async {
    final q = input.text.trim();
    if (q.isEmpty || busy) return;
    setState(() => busy = true);
    input.clear();
    try {
      final c = await context.read<AppState>().followUp(e, q);
      if (mounted) setState(() => e = c);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (sc.hasClients) sc.animateTo(sc.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });
    } catch (err) {
      if (mounted) toast(context, '$err');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _open() async {
    final s = context.read<AppState>();
    if (e.kind == 'question') {
      final q = await s.repo.question(e.id);
      if (!mounted) return;
      if (q == null) return toast(context, '这道题已经被删除了');
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => QuizPage(projectId: q.projectId, questionIds: [q.id], sessionKey: 'history_${q.id}')));
    } else {
      final c = await s.repo.card(e.id);
      if (!mounted) return;
      if (c == null) return toast(context, '这张卡已经被删除了');
      await showGlassSheet(context, (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.all(20), children: [
            Text('闪卡 · ${s.sourceLabel(c.docId, c.page, c.chapter, c.section)}', style: TextStyle(color: M.sub, fontSize: 13)),
            const SizedBox(height: 10),
            Glass(child: MathText(c.front, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.5))),
            const SizedBox(height: 10),
            Glass(child: MathText(c.back, style: const TextStyle(fontSize: 15, height: 1.6))),
            if (c.explanation.isNotEmpty) ...[
              const SizedBox(height: 10),
              MathText(c.explanation, style: TextStyle(color: M.sub, fontSize: 14, height: 1.6)),
            ],
            const SizedBox(height: 14),
            GlassButton(
              label: '查看原文',
              icon: Icons.menu_book_outlined,
              onTap: () => showSourceSheet(ctx, docId: c.docId, page: c.page, chapter: c.chapter, section: c.section),
            ),
          ]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AppState>().repo;
    final msgs = e.messages.skip(1).toList();
    return GlassScaffold(
      title: e.kind == 'question' ? '题目解释' : '闪卡解释',
      actions: [
        IconButton(
          tooltip: e.starred ? '取消收藏' : '收藏',
          onPressed: () async {
            setState(() => e.starred = !e.starred);
            await repo.saveExplain(e);
          },
          icon: Icon(e.starred ? Icons.star_rounded : Icons.star_border_rounded,
              color: e.starred ? M.oat.withValues(alpha: 1) : M.text),
        ),
        IconButton(
          tooltip: '删除',
          onPressed: () async {
            await repo.deleteExplain(e.id);
            if (context.mounted) Navigator.pop(context);
          },
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
      body: Column(children: [
        Expanded(
          child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 4, 20, 20), children: [
            Glass(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                MathText(e.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, height: 1.5)),
                if (e.kind != 'gone') ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GlassButton(
                        label: e.kind == 'question' ? '去做这道题' : '去看这张卡',
                        icon: Icons.open_in_new_rounded,
                        onTap: _open),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 14),
            for (final m in msgs)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: m['role'] == 'user'
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: Glass(
                            tint: M.greyBlue,
                            radius: 16,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Text(m['content']!, style: const TextStyle(color: Colors.white))))
                    : MathText(stripMetaPreamble(m['content']!), style: const TextStyle(fontSize: 15, height: 1.6)),
              ),
            if (busy) Padding(padding: const EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(color: M.sage))),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      controller: input,
                      onSubmitted: (_) => _ask(),
                      decoration: const InputDecoration(hintText: '继续追问'))),
              const SizedBox(width: 8),
              IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: M.sage),
                  onPressed: busy ? null : _ask,
                  icon: const Icon(Icons.send_rounded)),
            ]),
          ),
        ),
      ]),
    );
  }
}
