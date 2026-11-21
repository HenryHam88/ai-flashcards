import 'package:flutter/services.dart';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/study_queue.dart';
import '../theme/glass.dart';
import 'explain_sheet.dart';
import 'feedback_sheet.dart';

/// 闪卡复习。进度（如 12/32）每一步都写入本地，切出 App、被系统杀掉后都能恢复。
class ReviewPage extends StatefulWidget {
  final String? projectId;
  final bool resume;
  /// 指定要复习的卡片（如统计页「复习这些」薄弱章节）；这种临时复习不会覆盖正在进行的复习进度。
  final List<String>? cardIds;
  /// 学习入口：全部学习（默认）/ 学新卡 / 复习。
  final StudyMode mode;
  /// 临时学习时的标题提示（如「到期安排」里选的那天）。
  const ReviewPage({super.key, this.projectId, this.resume = false, this.cardIds, this.mode = StudyMode.all});
  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> with WidgetsBindingObserver {
  List<Flashcard> cards = [];
  int index = 0;
  bool flipped = false;
  bool loading = true;
  double dx = 0;
  String? filter; // 混合复习时的项目筛选（null=全部）
  List<(String, String)> projects = [];
  List<Map<String, dynamic>> undoStack = []; // 本轮每次评分的撤销记录（可多步返回）
  List<Map<String, dynamic>> redoStack = []; // 退回后可「下一张」原样恢复的评分
  bool hintSeen = true;
  late StudyMode mode = widget.mode;
  StudyCounts? counts; // 完成页：新卡是否已达今日上限
  late final SessionTimer timer; // 统计学习时长

  AppState get s => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = s.startSession(widget.projectId, 'review');
    _init();
  }

  @override
  void dispose() {
    timer.end();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _persist();
  }

  Future<void> _init() async {
    final saved = s.settings.reviewSession;
    if (widget.cardIds != null) {
      for (final id in widget.cardIds!) {
        final c = await s.repo.card(id);
        if (c != null && !c.suspended) cards.add(c);
      }
      index = 0;
    } else if (saved != null && (widget.resume || (saved['projectId'] == widget.projectId && studyModeOf(saved['mode'] as String?) == widget.mode))) {
      final ids = (saved['ids'] as List).cast<String>();
      final loaded = <Flashcard>[];
      for (final id in ids) {
        final c = await s.repo.card(id);
        if (c != null) loaded.add(c);
      }
      cards = loaded;
      index = min(saved['index'] as int, max(0, loaded.length));
      flipped = saved['flipped'] == true;
      filter = saved['filter'] as String?;
      mode = studyModeOf(saved['mode'] as String?);
      undoStack = ((saved['undo'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      redoStack = ((saved['redo'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } else {
      cards = await s.studyQueue(projectId: widget.projectId, mode: mode);
      index = 0;
    }
    if (widget.cardIds == null) counts = await s.studyCounts(projectId: widget.projectId ?? filter);
    if (widget.projectId == null) {
      projects = [for (final p in await s.repo.projects()) (p.id, p.name)];
    }
    hintSeen = s.settings.prefs.getBool('swipe_hint_seen') ?? false;
    loading = false;
    _persist();
    if (mounted) setState(() {});
  }

  void _persist() {
    if (widget.cardIds != null) return; // 临时复习不保存会话
    // 一轮完成后清除会话（完成页仍可在内存里「上一张」，撤销后会重新保存）
    if (cards.isEmpty || index >= cards.length) {
      s.settings.reviewSession = null;
    } else {
      s.settings.reviewSession = {
        'projectId': widget.projectId,
        'ids': cards.map((c) => c.id).toList(),
        'index': index,
        'flipped': flipped,
        'filter': filter,
        'mode': mode.name,
        'undo': undoStack,
        'redo': redoStack,
      };
    }
  }

  /// 切换项目筛选：按新范围重新取到期卡片，从第一张开始（并保存为当前会话）。
  Future<void> _setFilter(String? pid) async {
    if (pid == filter) return;
    final l = await s.studyQueue(projectId: pid, mode: mode);
    final c = await s.studyCounts(projectId: pid);
    setState(() {
      counts = c;
      filter = pid;
      cards = l;
      index = 0;
      flipped = false;
      dx = 0;
      undoStack = [];
      redoStack = [];
    });
    _persist();
  }

  Widget _filterBar() => widget.projectId == null && projects.length > 1
      ? ProjectFilterChips(projects: projects, value: filter, onChanged: _setFilter)
      : const SizedBox();

  Future<void> _rate(bool remembered) async {
    timer.touch();
    if (M.haptics) HapticFeedback.lightImpact();
    if (index >= cards.length) return;
    final undo = await s.reviewCard(cards[index], remembered);
    if (!hintSeen) {
      hintSeen = true;
      s.settings.prefs.setBool('swipe_hint_seen', true);
    }
    setState(() {
      undoStack.add(undo);
      redoStack = []; // 重新评分：替换原来的结果，重做记录作废
      index++;
      flipped = false;
      dx = 0;
    });
    _persist();
    if (index >= cards.length && widget.cardIds == null) {
      final c = await s.studyCounts(projectId: widget.projectId ?? filter);
      if (mounted) setState(() => counts = c);
    }
  }

  /// 上一张：撤销上一次评分（恢复状态、删除记录），回到那张卡的正面；原评分进入重做栈。
  Future<void> _undo() async {
    if (undoStack.isEmpty || index == 0) return;
    final (restored, redo) = await s.undoReview(undoStack.removeLast());
    setState(() {
      redoStack.add(redo);
      index--;
      cards[index] = restored;
      flipped = false;
      dx = 0;
    });
    _persist();
  }

  /// 下一张：不用重新评分，原样恢复刚才撤销的评分并前进。
  Future<void> _redo() async {
    if (redoStack.isEmpty || index >= cards.length) return;
    final redo = redoStack.removeLast();
    final undo = await s.redoReview(redo);
    setState(() {
      undoStack.add(undo);
      cards[index] = Flashcard.fromJson((redo['post'] as Map).cast<String, dynamic>());
      index++;
      flipped = false;
      dx = 0;
    });
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final done = !loading && index >= cards.length;
    final card = done || loading ? null : cards[index];
    return GlassScaffold(
      titleWidget: Text(
        loading ? '' : (done ? '完成' : '${index + 1} / ${cards.length}'),
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
      ),
      leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
      actions: [
        if (card != null)
          IconButton(
            tooltip: '这张有问题',
            icon: Icon(card.flag.isEmpty ? Icons.flag_outlined : Icons.flag_rounded),
            onPressed: () async {
              final r = await showFeedbackSheet(context, card: card);
              if (r is Flashcard && mounted) setState(() => cards[index] = r);
            },
          ),
        if (card != null)
          IconButton(
            tooltip: '查看原文',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => showSourceSheet(context, docId: card.docId, page: card.page, chapter: card.chapter, section: card.section),
          ),
      ],
      body: loading
          ? Center(child: CircularProgressIndicator(color: M.sage))
          : done
          ? Column(
              children: [
                _filterBar(),
                Expanded(child: _done()),
              ],
            )
          : SafeArea(
              child: Column(
                children: [
                  _filterBar(),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              KindBadge(cardKind(card!)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  card.chapter.isEmpty ? '学习中' : card.chapter,
                                  style: TextStyle(color: M.sub, fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(child: _cardView(card)),
                          const SizedBox(height: 14),
                          if (!hintSeen)
                            Padding(
                              padding: EdgeInsets.only(bottom: 8),
                              child: Text(
                                '右滑 = 记得，左滑 = 忘了，点按翻面；上一张 / 下一张可回看',
                                style: TextStyle(color: M.sub, fontSize: 12),
                              ),
                            ),
                          Row(
                            children: [
                              GlassButton(
                                label: '上一张',
                                icon: Icons.undo_rounded,
                                onTap: index > 0 && undoStack.isNotEmpty ? _undo : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: GlassButton(
                                  label: 'AI 解释',
                                  icon: Icons.auto_awesome_rounded,
                                  onTap: () => showExplainSheet(context, card: card),
                                ),
                              ),
                              const SizedBox(width: 12),
                              GlassButton(
                                label: '下一张',
                                icon: Icons.redo_rounded,
                                onTap: redoStack.isNotEmpty ? _redo : null,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: GlassButton(
                                  label: '没记住',
                                  icon: Icons.cancel_outlined,
                                  tint: M.rose,
                                  onTap: () => _rate(false),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: GlassButton(
                                  label: '记住了',
                                  icon: Icons.check_circle_outline,
                                  tint: M.sage,
                                  onTap: () => _rate(true),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _cardView(Flashcard card) {
    return GestureDetector(
      onTap: () {
        setState(() => flipped = !flipped);
        _persist();
      },
      onHorizontalDragUpdate: (d) => setState(() => dx += d.delta.dx),
      onHorizontalDragEnd: (d) {
        if (dx > 110) {
          _rate(true);
        } else if (dx < -110) {
          _rate(false);
        } else {
          setState(() => dx = 0);
        }
      },
      child: Transform.translate(
        offset: Offset(dx, 0),
        child: Transform.rotate(
          angle: dx / 1200,
          child: TweenAnimationBuilder<double>(
            key: ValueKey(card.id),
            tween: Tween(begin: 0, end: flipped ? pi : 0),
            duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 380),
            curve: Curves.easeInOut,
            builder: (context, angle, _) {
              final showBack = angle > pi / 2;
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateY(angle),
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(showBack ? pi : 0),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Glass(
                          radius: 28,
                          tint: dx > 40 ? M.sage : (dx < -40 ? M.rose : null),
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!showBack)
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: M.glass.withValues(alpha: 0.6),
                                        border: Border.all(color: M.line),
                                      ),
                                      child: Icon(Icons.question_mark_rounded, color: M.text),
                                    ),
                                  if (showBack)
                                    Text(
                                      '答案',
                                      style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w600),
                                    ),
                                  const SizedBox(height: 18),
                                  MathText(
                                    showBack ? card.back : card.front,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: showBack ? 18 : 21,
                                      fontWeight: showBack ? FontWeight.w500 : FontWeight.w700,
                                      height: 1.5,
                                    ),
                                  ),
                                  if (showBack && card.explanation.isNotEmpty) ...[
                                    const SizedBox(height: 16),
                                    MathText(
                                      card.explanation,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(fontSize: 14, color: M.sub, height: 1.5),
                                    ),
                                  ],
                                  const SizedBox(height: 18),
                                  Text(
                                    showBack ? (card.page > 0 ? '出处：${s.sourceLabel(card.docId, card.page, card.chapter, card.section)}' : '') : '•  点击翻面  •',
                                    style: TextStyle(color: M.sub, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _emptyText() {
    final scope = filter == null && widget.projectId == null ? '' : '这个项目';
    return switch (mode) {
      StudyMode.newOnly => counts?.newLimitReached == true ? '今天的新卡已学完' : '$scope没有新卡',
      StudyMode.reviewOnly => '$scope现在没有到期的复习',
      StudyMode.all => counts?.newLimitReached == true ? '到期的复习已完成，今天的新卡已学完' : '$scope现在没有要学的闪卡',
    };
  }

  /// 「今天再学 10 张」：放宽今天的新卡上限，接着学新卡（保留本轮的撤销记录）。
  Future<void> _extend() async {
    s.extendNewToday(10);
    final more = await s.studyQueue(projectId: widget.projectId ?? filter, mode: StudyMode.newOnly);
    final have = cards.map((c) => c.id).toSet();
    final add = more.where((c) => !have.contains(c.id)).toList();
    final c = await s.studyCounts(projectId: widget.projectId ?? filter);
    setState(() {
      cards = [...cards, ...add];
      counts = c;
      flipped = false;
      dx = 0;
    });
    _persist();
  }

  Widget _done() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Glass(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.celebration_outlined, color: M.sageDark, size: 40),
            const SizedBox(height: 12),
            Text(
              cards.isEmpty ? _emptyText() : '本轮 ${cards.length} 张已学完',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            if (counts != null && widget.cardIds == null) ...[
              const SizedBox(height: 6),
              Text('${counts!.newProgress} · 待复习 ${counts!.due}', style: TextStyle(color: M.sub, fontSize: 13)),
            ],
            const SizedBox(height: 16),
            if (counts != null && widget.cardIds == null && mode != StudyMode.reviewOnly && counts!.newLimitReached) ...[
              GlassButton(label: '今天再学 10 张', icon: Icons.add_rounded, tint: M.sage, onTap: _extend),
              const SizedBox(height: 12),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (undoStack.isNotEmpty) ...[
                  GlassButton(label: '上一张', icon: Icons.undo_rounded, onTap: _undo),
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

/// 卡片身份标签：新（燕麦色）/ 复习（灰绿）/ 重学（玫瑰色）。
class KindBadge extends StatelessWidget {
  final CardKind kind;
  const KindBadge(this.kind, {super.key});
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      CardKind.fresh => (M.oat.withValues(alpha: 0.85), M.text),
      CardKind.review => (M.sage.withValues(alpha: 0.25), M.sageDark),
      CardKind.relearn => (M.rose.withValues(alpha: 0.3), M.roseDark),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(cardKindLabel(kind), style: TextStyle(fontSize: 11, height: 1.4, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}
