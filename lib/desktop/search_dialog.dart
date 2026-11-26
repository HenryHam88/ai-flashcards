import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';

/// 搜索结果：打开项目、打开笔记，或打开卡片 / 题目所在的项目。
sealed class SearchResult {
  const SearchResult();
}

class SearchProject extends SearchResult {
  final String id;
  const SearchProject(this.id);
}

class SearchNote extends SearchResult {
  final StudyNote note;
  const SearchNote(this.note);
}

class SearchItem extends SearchResult {
  final String projectId;
  const SearchItem(this.projectId);
}

class _Hit {
  final IconData icon;
  final String group, title, sub;
  final SearchResult result;
  _Hit(this.icon, this.group, this.title, this.sub, this.result);
}

class _Corpus {
  final List<Project> projects;
  final List<StudyNote> notes;
  final List<Flashcard> cards;
  final List<Question> questions;
  _Corpus(this.projects, this.notes, this.cards, this.questions);
}

/// 搜索项目、笔记、闪卡和题目（Ctrl/⌘ K）。↑ ↓ 选择，回车打开，Esc 关闭。
Future<SearchResult?> showDesktopSearch(BuildContext context) => showDialog<SearchResult>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      builder: (_) => const _SearchDialog(),
    );

/// 按关键词筛选（不分大小写），每组最多 [per] 条。
List<_Hit> _filter(_Corpus c, String q, {int per = 6}) {
  final k = q.trim().toLowerCase();
  if (k.isEmpty) {
    return [for (final p in c.projects.take(8)) _Hit(Icons.menu_book_rounded, '项目', p.name, '', SearchProject(p.id))];
  }
  bool has(String s) => s.toLowerCase().contains(k);
  final names = {for (final p in c.projects) p.id: p.name};
  String one(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return [
    for (final p in c.projects.where((p) => has(p.name)).take(per)) _Hit(Icons.menu_book_rounded, '项目', p.name, '', SearchProject(p.id)),
    for (final n in c.notes.where((n) => has(n.title) || has(n.own) || has(n.ai)).take(per))
      _Hit(Icons.edit_note_rounded, '笔记', n.title.isEmpty ? '未命名笔记' : n.title, names[n.projectId] ?? '', SearchNote(n)),
    for (final f in c.cards.where((f) => has(f.front) || has(f.back)).take(per))
      _Hit(Icons.style_outlined, '闪卡', one(f.front), names[f.projectId] ?? '', SearchItem(f.projectId)),
    for (final x in c.questions.where((x) => has(x.stem)).take(per))
      _Hit(Icons.quiz_outlined, '题目', one(x.stem), names[x.projectId] ?? '', SearchItem(x.projectId)),
  ];
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog();
  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  _Corpus? corpus;
  String q = '';
  int sel = 0;

  @override
  void initState() {
    super.initState();
    final r = context.read<AppState>().repo;
    () async {
      final c = _Corpus(await r.projects(), await r.notes(), await r.cards(), await r.questions());
      if (mounted) setState(() => corpus = c);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final hits = corpus == null ? <_Hit>[] : _filter(corpus!, q);
    if (sel >= hits.length) sel = hits.isEmpty ? 0 : hits.length - 1;
    void open(int i) {
      if (i < hits.length) Navigator.pop(context, hits[i].result);
    }

    return Dialog(
      backgroundColor: M.sheet,
      alignment: const Alignment(0, -0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 520),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => setState(() => sel = (sel + 1).clamp(0, hits.isEmpty ? 0 : hits.length - 1)),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(() => sel = (sel - 1).clamp(0, hits.isEmpty ? 0 : hits.length - 1)),
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => (q = v, sel = 0)),
                onSubmitted: (_) => open(sel),
                decoration: const InputDecoration(hintText: '搜索项目、笔记、闪卡和题目', prefixIcon: Icon(Icons.search_rounded)),
              ),
            ),
            Flexible(
              child: corpus == null
                  ? const Padding(padding: EdgeInsets.all(24), child: SizedBox())
                  : hits.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(q.trim().isEmpty ? '还没有项目' : '没有找到「${q.trim()}」', style: TextStyle(color: M.sub)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                          itemCount: hits.length,
                          itemBuilder: (_, i) {
                            final h = hits[i];
                            final head = i == 0 || hits[i - 1].group != h.group;
                            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              if (head)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                                  child: Text(h.group, style: TextStyle(color: M.sub, fontSize: 12, fontWeight: FontWeight.w600)),
                                ),
                              Material(
                                color: i == sel ? M.sage.withValues(alpha: 0.22) : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                                child: ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  leading: Icon(h.icon, color: M.sageDark, size: 20),
                                  title: Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                                  subtitle: h.sub.isEmpty ? null : Text(h.sub, style: TextStyle(color: M.sub, fontSize: 12)),
                                  onTap: () => open(i),
                                ),
                              ),
                            ]);
                          },
                        ),
            ),
          ]),
        ),
      ),
    );
  }
}
