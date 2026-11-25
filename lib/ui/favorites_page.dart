import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';
import 'explain_sheet.dart';
import 'notes_page.dart' show openNoteFor;
import 'quiz_page.dart';
import 'review_page.dart';

/// 收藏按钮（星标）：闪卡、题目、知识点通用。状态从数据库读，点一下切换。
class FavoriteButton extends StatefulWidget {
  final String kind; // kp / card / question
  final String targetId;
  final String projectId;
  final String title;
  final double size;
  const FavoriteButton({
    super.key,
    required this.kind,
    required this.targetId,
    required this.projectId,
    required this.title,
    this.size = 24,
  });
  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  bool? on;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FavoriteButton old) {
    super.didUpdateWidget(old);
    if (old.targetId != widget.targetId) _load();
  }

  Future<void> _load() async {
    final v = await context.read<AppState>().repo.isFavorite(widget.kind, widget.targetId);
    if (mounted) setState(() => on = v);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: on == true ? '取消收藏' : '收藏',
    icon: Icon(on == true ? Icons.star_rounded : Icons.star_outline_rounded, size: widget.size, color: on == true ? M.sageDark : null),
    onPressed: on == null
        ? null
        : () async {
            tapFeedback();
            final v = await context.read<AppState>().repo.toggleFavorite(
              FavoriteItem(projectId: widget.projectId, kind: widget.kind, targetId: widget.targetId, title: widget.title),
            );
            if (!mounted || !context.mounted) return;
            setState(() => on = v);
            toast(context, v ? '已收藏，在项目页「收藏」里查看' : '已取消收藏');
          },
  );
}

/// 收藏夹里的一项（连同它指向的内容；内容被删除时为 null）。
class FavoriteEntry {
  final FavoriteItem fav;
  final KnowledgePoint? kp;
  final Flashcard? card;
  final Question? question;
  final int relatedCards; // 知识点：关联的闪卡数
  final int relatedQuestions;
  FavoriteEntry(this.fav, {this.kp, this.card, this.question, this.relatedCards = 0, this.relatedQuestions = 0});
  bool get gone => kp == null && card == null && question == null;
}

Future<List<FavoriteEntry>> loadFavorites(AppState s, {String? projectId}) async {
  final favs = await s.repo.favorites(projectId: projectId);
  final out = <FavoriteEntry>[];
  final cardsByKp = <String, int>{}, qsByKp = <String, int>{};
  if (favs.any((f) => f.kind == 'kp')) {
    for (final c in await s.repo.cards(projectId: projectId)) {
      if (c.kpId.isNotEmpty) cardsByKp[c.kpId] = (cardsByKp[c.kpId] ?? 0) + 1;
    }
    for (final q in await s.repo.questions(projectId: projectId)) {
      if (q.kpId.isNotEmpty) qsByKp[q.kpId] = (qsByKp[q.kpId] ?? 0) + 1;
    }
  }
  for (final f in favs) {
    switch (f.kind) {
      case 'kp':
        out.add(
          FavoriteEntry(
            f,
            kp: await s.repo.kp(f.targetId),
            relatedCards: cardsByKp[f.targetId] ?? 0,
            relatedQuestions: qsByKp[f.targetId] ?? 0,
          ),
        );
      case 'card':
        out.add(FavoriteEntry(f, card: await s.repo.card(f.targetId)));
      default:
        out.add(FavoriteEntry(f, question: await s.repo.question(f.targetId)));
    }
  }
  return out;
}

/// 收藏：项目里（或全部项目）收藏的知识点、闪卡和题目。
class FavoritesPage extends StatefulWidget {
  final String? projectId;
  const FavoritesPage({super.key, this.projectId});
  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  String kind = ''; // '' = 全部
  String? filter; // 全部项目时的项目筛选
  List<(String, String)> projects = [];

  @override
  void initState() {
    super.initState();
    if (widget.projectId == null) {
      context.read<AppState>().repo.projects().then((l) => mounted ? setState(() => projects = [for (final p in l) (p.id, p.name)]) : null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return GlassScaffold(
      title: '收藏',
      body: FutureBuilder<List<FavoriteEntry>>(
        key: ValueKey('${s.version}-$filter'),
        future: loadFavorites(s, projectId: widget.projectId ?? filter),
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const SizedBox();
          final list = kind.isEmpty ? all : all.where((e) => e.fav.kind == kind).toList();
          final cards = [
            for (final e in list)
              if (e.card != null && !e.card!.suspended) e.card!.id,
          ];
          final qs = [
            for (final e in list)
              if (e.question != null) e.question!.id,
          ];
          return Column(
            children: [
              if (widget.projectId == null && projects.length > 1)
                ProjectFilterChips(projects: projects, value: filter, onChanged: (v) => setState(() => filter = v)),
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  children: [
                    for (final k in ['', ...FavoriteItem.kinds])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Glass(
                          radius: 18,
                          tint: kind == k ? M.sage : null,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          onTap: () => setState(() => kind = k),
                          child: Text(
                            '${k.isEmpty ? '全部' : FavoriteItem.kindNames[k]} ${k.isEmpty ? all.length : all.where((e) => e.fav.kind == k).length}',
                            style: TextStyle(
                              color: kind == k ? Colors.white : M.text,
                              fontSize: 13,
                              fontWeight: kind == k ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                  children: [
                    if (cards.isNotEmpty || qs.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (cards.isNotEmpty)
                            Expanded(
                              child: GlassButton(
                                label: '复习 ${cards.length} 张',
                                icon: Icons.style_outlined,
                                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReviewPage(cardIds: cards))),
                              ),
                            ),
                          if (cards.isNotEmpty && qs.isNotEmpty) const SizedBox(width: 8),
                          if (qs.isNotEmpty)
                            Expanded(
                              child: GlassButton(
                                label: '做 ${qs.length} 道题',
                                icon: Icons.quiz_outlined,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => QuizPage(
                                      projectId: widget.projectId,
                                      questionIds: qs,
                                      sessionKey: 'fav_${widget.projectId ?? 'all'}',
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('还没有收藏。复习闪卡、做题或看知识点时，点右上角的星标就能收藏重要的内容。', style: TextStyle(color: M.sub, height: 1.6)),
                      ),
                    for (final e in list)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: FavoriteTile(entry: e),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class FavoriteTile extends StatelessWidget {
  final FavoriteEntry entry;
  const FavoriteTile({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final (title, body, meta) = switch (e.fav.kind) {
      'kp' => (
        e.kp?.title ?? e.fav.title,
        e.kp?.content ?? '',
        [
          if (e.kp?.chapter.isNotEmpty == true) e.kp!.chapter,
          if (e.relatedCards > 0) '${e.relatedCards} 张闪卡',
          if (e.relatedQuestions > 0) '${e.relatedQuestions} 道题',
        ].join(' · '),
      ),
      'card' => (e.card?.front ?? e.fav.title, e.card?.back ?? '', e.card?.chapter ?? ''),
      _ => (
        e.question?.stem ?? e.fav.title,
        e.question == null ? '' : '答案：${e.question!.answer}',
        '${e.question?.type ?? ''}${e.question?.chapter.isNotEmpty == true ? ' · ${e.question!.chapter}' : ''}',
      ),
    };
    final kindColor = switch (e.fav.kind) {
      'kp' => M.oat,
      'card' => M.sage,
      _ => M.greyBlue,
    };
    return Glass(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      onTap: e.gone ? null : () => showFavoriteDetail(context, e),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(color: kindColor.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        FavoriteItem.kindNames[e.fav.kind] ?? '',
                        style: TextStyle(fontSize: 11, height: 1.4, fontWeight: FontWeight.w700, color: M.text),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        e.gone ? '（原内容已删除）' : meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: M.sub, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                MathText(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  MathText(body, style: TextStyle(fontSize: 13, color: M.sub, height: 1.5)),
                ],
              ],
            ),
          ),
          FavoriteButton(kind: e.fav.kind, targetId: e.fav.targetId, projectId: e.fav.projectId, title: e.fav.title, size: 22),
        ],
      ),
    );
  }
}

/// 收藏详情：完整内容 + 查看原文 / AI 解释 / 复习相关闪卡。
Future<void> showFavoriteDetail(BuildContext context, FavoriteEntry e) => showGlassSheet(context, (ctx, sc) {
  final s = ctx.read<AppState>();
  final c = e.card, q = e.question, k = e.kp;
  final docId = c?.docId ?? q?.docId ?? k?.docId ?? '';
  final page = c?.page ?? q?.page ?? k?.page ?? 0;
  return ListView(
    controller: sc,
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
    children: [
      Text(
        FavoriteItem.kindNames[e.fav.kind] ?? '',
        style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      if (k != null) ...[
        MathText(k.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        MathText(k.content, style: const TextStyle(fontSize: 15, height: 1.6)),
      ],
      if (c != null) ...[
        MathText(c.front, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Text(
          '答案',
          style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        MathText(c.back, style: const TextStyle(fontSize: 15, height: 1.6)),
        if (c.explanation.isNotEmpty) ...[
          const SizedBox(height: 8),
          MathText(c.explanation, style: TextStyle(fontSize: 14, color: M.sub, height: 1.5)),
        ],
      ],
      if (q != null) ...[
        MathText(q.stem, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.5)),
        for (var i = 0; i < q.options.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: MathText('${String.fromCharCode(65 + i)}. ${q.options[i]}', style: const TextStyle(fontSize: 14)),
          ),
        const SizedBox(height: 10),
        Text(
          '答案：${q.answer}',
          style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w600),
        ),
        if (q.explanation.isNotEmpty) ...[
          const SizedBox(height: 6),
          MathText(q.explanation, style: TextStyle(fontSize: 14, color: M.sub, height: 1.5)),
        ],
      ],
      if (page > 0) ...[
        const SizedBox(height: 10),
        Text(
          '出处：${s.sourceLabel(docId, page, c?.chapter ?? q?.chapter ?? k?.chapter ?? '', c?.section ?? q?.section ?? k?.section ?? '')}',
          style: TextStyle(color: M.sub, fontSize: 13),
        ),
      ],
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (page > 0)
            GlassButton(
              label: '查看原文',
              icon: Icons.menu_book_outlined,
              onTap: () => showSourceSheet(ctx, docId: docId, page: page, chapter: c?.chapter ?? q?.chapter ?? k?.chapter ?? ''),
            ),
          if (c != null || q != null)
            GlassButton(
              label: 'AI 解释',
              icon: Icons.auto_awesome_rounded,
              onTap: () => showExplainSheet(ctx, card: c, question: q),
            ),
          if (k != null)
            GlassButton(
                label: '写笔记',
                icon: Icons.edit_note_rounded,
                onTap: () => openNoteFor(ctx, projectId: k.projectId, kpId: k.id)),
          if (k != null && e.relatedCards > 0)
            GlassButton(
              label: '复习相关闪卡',
              icon: Icons.style_outlined,
              onTap: () async {
                final ids = [
                  for (final x in await s.repo.cards(projectId: k.projectId))
                    if (x.kpId == k.id && !x.suspended) x.id,
                ];
                if (ctx.mounted) Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => ReviewPage(cardIds: ids)));
              },
            ),
          if (k != null && e.relatedQuestions > 0)
            GlassButton(
              label: '做相关题目',
              icon: Icons.quiz_outlined,
              onTap: () async {
                final ids = [
                  for (final x in await s.repo.questions(projectId: k.projectId))
                    if (x.kpId == k.id && !x.suspended) x.id,
                ];
                if (ctx.mounted) {
                  Navigator.of(ctx).push(
                    MaterialPageRoute(
                      builder: (_) => QuizPage(projectId: k.projectId, questionIds: ids, sessionKey: 'kp_${k.id}'),
                    ),
                  );
                }
              },
            ),
        ],
      ),
    ],
  );
}, initial: 0.7);
