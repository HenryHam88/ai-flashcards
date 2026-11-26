import 'package:flutter/services.dart';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/review_history.dart';
import '../services/study_queue.dart';
import '../desktop/platform.dart';
import '../theme/glass.dart';
import 'explain_sheet.dart';
import 'favorites_page.dart' show FavoriteButton;
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
  /// 本轮已评分的卡（第 i 条 = 第 i 张）。index < history.length 时是在回看，可以改评分。
  List<ReviewEntry> history = [];
  int base = 0; // history[0] 对应第 base 张（旧版会话恢复时前面的卡没有评分记录）
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
      history = [for (final e in (saved['history'] as List?) ?? const []) ReviewEntry.fromJson((e as Map).cast<String, dynamic>())];
      // 旧版会话（撤销栈）：转换成评分记录，评分从复习记录里读出
      for (final e in (saved['undo'] as List?) ?? const []) {
        final u = (e as Map).cast<String, dynamic>();
        final log = await s.repo.logEntry('${u['log']}');
        history.add(ReviewEntry(
            cardId: '${(u['card'] as Map)['id']}',
            pre: (u['card'] as Map).cast<String, dynamic>(),
            grade: log == null ? Grade.good : (log.grade > 0 ? log.grade : (log.correct ? Grade.good : Grade.again)),
            at: log?.at ?? DateTime.now(),
            logId: '${u['log']}'));
      }
      base = (saved['base'] as int?) ?? 0;
      if (base + history.length > index) history = history.sublist(0, max(0, index - base));
      // 很旧的会话没有评分记录：前面这些卡算已评分，但不能回看修改
      if (base + history.length < index) {
        base = index;
        history = [];
      }
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
        'history': [for (final e in history) e.toJson()],
        if (base > 0) 'base': base,
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
      history = [];
      base = 0;
    });
    _persist();
  }

  Widget _filterBar() => widget.projectId == null && projects.length > 1
      ? ProjectFilterChips(projects: projects, value: filter, onChanged: _setFilter)
      : const SizedBox();

  /// 正在回看已经评过分的卡。
  bool get reviewing => index >= base && index - base < history.length;
  ReviewEntry? get entry => reviewing ? history[index - base] : null;
  bool get canBack => index - 1 >= base && history.isNotEmpty;

  /// 评分。回看时点另一个评分 = 修改这张卡的评分（按评分前的快照和原时间重新计算，不影响后面已评的卡）。
  Future<void> _rate(int grade) async {
    timer.touch();
    if (M.haptics) HapticFeedback.lightImpact();
    if (index >= cards.length) return;
    if (reviewing) {
      final e = entry!;
      if (e.grade != grade) {
        final old = e.grade;
        cards[index] = await s.changeRating(history, index - base, grade);
        if (mounted) toast(context, '已把「${Grade.label(old)}」改为「${Grade.label(grade)}」');
      }
    } else {
      history.add(await s.rateCard(cards[index], grade));
    }
    if (!hintSeen) {
      hintSeen = true;
      s.settings.prefs.setBool('swipe_hint_seen', true);
    }
    if (!mounted) return;
    setState(() {
      index++;
      flipped = reviewing; // 回看的卡直接显示答案
      dx = 0;
    });
    _persist();
    if (index >= cards.length && widget.cardIds == null) {
      final c = await s.studyCounts(projectId: widget.projectId ?? filter);
      if (mounted) setState(() => counts = c);
    }
  }

  /// 上一张：回到上一张卡看答案和当时的评分，不改动任何数据；想改就点另一个评分。
  void _back() {
    if (!canBack) return;
    setState(() {
      index--;
      flipped = true;
      dx = 0;
    });
    _persist();
  }

  /// 下一张：回看时向前，最多到还没评分的那张。
  void _forward() {
    if (!reviewing) return;
    setState(() {
      index++;
      flipped = reviewing;
      dx = 0;
    });
    _persist();
  }

  bool _rating = false;
  Future<void> _rateKey(int g) async {
    if (_rating) return; // 连按时不会给同一张卡评两次
    _rating = true;
    try {
      await _rate(g);
    } finally {
      _rating = false;
    }
  }

  void _flip() {
    setState(() => flipped = !flipped);
    _persist();
  }

  /// 键盘：空格 / 回车翻面，翻开后再按一次 = 记住了；翻开后 1–4 评分；← → 上一张 / 下一张；E 打开 AI 解释。
  Map<ShortcutActivator, VoidCallback> _keys(Flashcard? card) {
    if (card == null) return const {};
    void space() => flipped ? _rateKey(Grade.good) : _flip();
    // 和 Anki 一样，翻开看过答案才能用数字键评分，避免误按。
    void rate(int g) {
      if (flipped) _rateKey(g);
    }

    return {
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.space): space,
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.enter): space,
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.digit1): () => rate(Grade.again),
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.digit2): () => rate(Grade.hard),
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.digit3): () => rate(Grade.good),
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.digit4): () => rate(Grade.easy),
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.numpad1): () => rate(Grade.again),
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.numpad2): () => rate(Grade.hard),
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.numpad3): () => rate(Grade.good),
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.numpad4): () => rate(Grade.easy),
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.arrowLeft): _back,
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.arrowRight): _forward,
      const SingleActivator(includeRepeats: false, LogicalKeyboardKey.keyE): () => showExplainSheet(context, card: card),
    };
  }

  @override
  Widget build(BuildContext context) {
    final done = !loading && index >= cards.length;
    final card = done || loading ? null : cards[index];
    return CallbackShortcuts(
      bindings: _keys(card),
      child: Focus(autofocus: true, child: _scaffold(done, card)),
    );
  }

  Widget _scaffold(bool done, Flashcard? card) {
    return GlassScaffold(
      deskMax: 780,
      titleWidget: Text(
        loading ? '' : (done ? '完成' : '${index + 1} / ${cards.length}'),
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
      ),
      leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
      actions: [
        if (card != null) FavoriteButton(kind: 'card', targetId: card.id, projectId: card.projectId, title: card.front),
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
                              KindBadge(cardKind(reviewing ? withFsrsState(card!, entry!.pre) : card!)),
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
                          if (Desk.platform)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '空格 翻面 / 记住了 · 翻面后 1 没记住 · 2 模糊 · 3 记住了 · 4 很简单 · ← → 上一张 / 下一张 · E AI 解释',
                                style: TextStyle(color: M.sub, fontSize: 12),
                              ),
                            )
                          else if (!hintSeen)
                            Padding(
                              padding: EdgeInsets.only(bottom: 8),
                              child: Text(
                                '右滑 = 记住了，左滑 = 没记住；上一张可回看、改评分',
                                style: TextStyle(color: M.sub, fontSize: 12),
                              ),
                            ),
                          Row(
                            children: [
                              GlassButton(
                                label: '上一张',
                                icon: Icons.undo_rounded,
                                onTap: canBack ? _back : null,
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
                                onTap: reviewing ? _forward : null,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (reviewing)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text('本轮已评「${Grade.label(entry!.grade)}」，点其他评分可以修改',
                                  style: TextStyle(color: M.sub, fontSize: 12)),
                            ),
                          _gradeRow(card),
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
      onTap: _flip,
      onHorizontalDragUpdate: (d) => setState(() => dx += d.delta.dx),
      onHorizontalDragEnd: (d) {
        if (dx > 110) {
          _rate(Grade.good);
        } else if (dx < -110) {
          _rate(Grade.again);
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

  /// 四档评分按钮：没记住 / 模糊 / 记住了 / 很简单，下面显示下次复习的间隔。
  /// 回看时只有当时选的那个是实心的，点其他的就是修改评分。
  Widget _gradeRow(Flashcard card) {
    final e = entry;
    final iv = previewIntervals(card, s.fsrs, pre: e?.pre, now: e?.at);
    final specs = [
      (Grade.again, M.rose, M.roseDark),
      (Grade.hard, M.oat, M.text),
      (Grade.good, M.sage, M.sageDark),
      (Grade.easy, M.greyBlue, M.wordBlue),
    ];
    return Row(children: [
      for (var i = 0; i < specs.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: GradeButton(
            label: Grade.label(specs[i].$1),
            interval: iv[specs[i].$1] ?? '',
            tint: specs[i].$2,
            fg: specs[i].$3,
            selected: e == null || e.grade == specs[i].$1,
            onTap: () => _rate(specs[i].$1),
          ),
        ),
      ],
    ]);
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
                if (canBack) ...[
                  GlassButton(label: '上一张', icon: Icons.undo_rounded, onTap: _back),
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

/// 评分按钮：玻璃底 + 评分名 + 下次间隔。[selected] 为 false 时只显示描边文字（回看时未选中的评分）。
class GradeButton extends StatelessWidget {
  final String label;
  final String interval;
  final Color tint;
  final Color fg;
  final bool selected;
  final VoidCallback onTap;
  const GradeButton(
      {super.key, required this.label, required this.interval, required this.tint, required this.fg, this.selected = true, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : fg;
    return Glass(
      radius: 18,
      tint: selected ? tint : null,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label, maxLines: 1, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 1),
        Text(interval, maxLines: 1, style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 11)),
      ]),
    );
  }
}
