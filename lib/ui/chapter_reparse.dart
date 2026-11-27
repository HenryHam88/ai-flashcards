import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/chapter_reparse.dart';
import '../theme/glass.dart';
import 'favorites_page.dart' show FavoriteButton;

// ============================================================================
// 按章重新解析（选引擎 → 进度 / 取消 → 新旧对比 → 保存）和章节知识点（查看 / 重新分析）。
// ============================================================================

/// 重新解析保存后，用户在提示里选的下一步。
enum AfterReparse { none, analyze, redetect }

/// 重新解析这一章。返回 true 表示有页面被替换。[onRedetect]：用户点「重新识别章节」时调用。
Future<bool> startChapterReparse(
  BuildContext context,
  PdfDoc doc,
  ChapterRange range, {
  VoidCallback? onRedetect,
}) async {
  final why = reparseUnsupported(doc);
  if (why != null) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: M.sheet,
        title: const Text('无法只重新解析这一章'),
        content: Text(why),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
      ),
    );
    return false;
  }
  final result = await showGlassSheet<ReparseResult>(
    context,
    (ctx, sc) => ReparseSheet(doc: doc, range: range, scroll: sc),
    initial: 0.72,
  );
  if (result == null || !context.mounted) return false;
  final saved = await Navigator.of(context)
      .push<int>(MaterialPageRoute(builder: (_) => ReparseDiffPage(result: result)));
  if (saved == null || saved == 0 || !context.mounted) return false;
  context.read<AppState>().changed();
  final next = await showDialog<AfterReparse>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: M.sheet,
      title: Text('已替换 $saved ${doc.isSectioned ? '节' : '页'}'),
      content: const Text(
        '这一章的文字变了，原来的知识点已失效，自动数量和出题会改用新的知识点。现在重新分析知识点吗？\n\n'
        '章节划分保持不变；不满意可以在菜单里点「恢复上次解析」。',
      ),
      actions: [
        if (onRedetect != null)
          TextButton(onPressed: () => Navigator.pop(ctx, AfterReparse.redetect), child: const Text('重新识别章节')),
        TextButton(onPressed: () => Navigator.pop(ctx, AfterReparse.none), child: const Text('稍后')),
        TextButton(onPressed: () => Navigator.pop(ctx, AfterReparse.analyze), child: const Text('现在分析')),
      ],
    ),
  );
  if (!context.mounted) return true;
  if (next == AfterReparse.analyze) await showChapterKps(context, doc, range, reanalyze: true);
  if (next == AfterReparse.redetect) onRedetect?.call();
  return true;
}

/// 恢复上次解析（再点一次可以换回来）。返回 true 表示有改动。
Future<bool> undoChapterReparse(BuildContext context, PdfDoc doc, ChapterRange range) async {
  final s = context.read<AppState>();
  final snap = await s.reparser.snapshot(doc, range);
  if (!context.mounted) return false;
  if (snap == null) {
    toast(context, '这一章还没有重新解析过，没有可恢复的记录');
    return false;
  }
  final n = snap.pages.length + snap.missing.length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: M.sheet,
      title: const Text('恢复上次解析？'),
      content: Text(
        '把这一章的 $n ${doc.isSectioned ? '节' : '页'}恢复成上一次替换前的文字。'
        '恢复后再点一次「恢复上次解析」可以换回来。闪卡和题目不受影响。',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('恢复')),
      ],
    ),
  );
  if (ok != true) return false;
  await s.reparser.undo(doc, range);
  s.changed();
  if (context.mounted) toast(context, '已恢复上次解析，知识点会在下次分析时按恢复后的文字重新提取');
  return true;
}

/// 第一步：选择引擎、看预估，开始后显示进度，可以取消。
class ReparseSheet extends StatefulWidget {
  final PdfDoc doc;
  final ChapterRange range;
  final ScrollController scroll;
  const ReparseSheet({super.key, required this.doc, required this.range, required this.scroll});
  @override
  State<ReparseSheet> createState() => _ReparseSheetState();
}

class _ReparseSheetState extends State<ReparseSheet> {
  late ReparseEngine engine;
  Map<ReparseEngine, bool> hasKey = {};
  bool running = false;
  String message = '';
  double frac = 0;
  CancelToken? token;
  String? error;

  AppState get s => context.read<AppState>();
  String get unit => widget.doc.isSectioned ? '节' : '页';

  @override
  void initState() {
    super.initState();
    final st = context.read<AppState>().settings;
    engine = defaultEngine(widget.doc, st);
    _keys();
  }

  Future<void> _keys() async {
    final ocr = (await s.settings.ocrKey()).isNotEmpty;
    final kimi = (await s.settings.kimiKey()).isNotEmpty;
    if (!mounted) return;
    setState(
      () => hasKey = {
        ReparseEngine.deepseekText: ocr,
        ReparseEngine.deepseekRich: ocr,
        ReparseEngine.kimi: kimi,
        ReparseEngine.local: true,
        ReparseEngine.txt: true,
      },
    );
  }

  Future<void> _start() async {
    final t = CancelToken();
    setState(() {
      running = true;
      error = null;
      token = t;
      message = '准备中…';
      frac = 0;
    });
    try {
      final r = await s.reparser.run(
        widget.doc,
        widget.range,
        engine,
        cancel: t,
        onProgress: (m, f) {
          if (mounted) {
            setState(() {
              message = m;
              frac = f;
            });
          }
        },
      );
      if (t.cancelled) throw ReparseCancelled();
      if (mounted) Navigator.pop(context, r);
    } on ReparseCancelled {
      if (!mounted) return;
      toast(context, '已取消，原来的文字没有改动');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          running = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final engines = enginesFor(widget.doc);
    final r = widget.range;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        const Text('重新解析这一章', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('${r.title} · 第 ${r.start}–${r.end} $unit', style: TextStyle(color: M.sub, fontSize: 13)),
        const SizedBox(height: 4),
        Text('只解析这一章，解析完先对比新旧文字，由你决定替换哪些页；分章和已生成的闪卡、题目都不变。', style: TextStyle(color: M.sub, fontSize: 12)),
        const SizedBox(height: 12),
        for (final e in engines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Opacity(
              opacity: hasKey[e] == false ? 0.5 : 1,
              child: Glass(
                radius: 16,
                tint: e == engine ? M.sage.withValues(alpha: 0.35) : null,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                onTap: running || hasKey[e] == false ? null : () => setState(() => engine = e),
                child: Row(
                  children: [
                    Icon(
                      e == engine ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                      size: 20,
                      color: e == engine ? M.sageDark : M.sub,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(e.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    if (hasKey[e] == false) Text('未填写密钥', style: TextStyle(color: M.sub, fontSize: 12)),
                    if (e.online && hasKey[e] != false) Text('联网 · 计费', style: TextStyle(color: M.sub, fontSize: 12)),
                    if (!e.online) Text('免费', style: TextStyle(color: M.sageDark, fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: M.sub),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                reparseEstimate(widget.doc, r, engine, batch: s.settings.ocrBatchPages),
                style: TextStyle(color: M.sub, fontSize: 12),
              ),
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!, style: TextStyle(color: M.roseDark, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        if (running) ...[
          Text(message, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: frac <= 0 ? null : frac,
            minHeight: 4,
            color: M.sage,
            backgroundColor: M.glass.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          GlassButton(
            label: token?.cancelled == true ? '正在取消…' : '取消',
            icon: Icons.close_rounded,
            expand: true,
            onTap: token?.cancelled == true ? null : () => setState(() => token?.cancel()),
          ),
        ] else
          GlassButton(label: '开始重新解析', icon: Icons.refresh_rounded, tint: M.sage, expand: true, onTap: _start),
      ],
    );
  }
}

/// 第二步：逐页对比新旧文字，选择「替换全部」、逐页保留旧的 / 用新的，或「放弃」。
class ReparseDiffPage extends StatefulWidget {
  final ReparseResult result;
  const ReparseDiffPage({super.key, required this.result});
  @override
  State<ReparseDiffPage> createState() => _ReparseDiffPageState();
}

class _ReparseDiffPageState extends State<ReparseDiffPage> {
  bool onlyChanged = true, saving = false;
  final showNew = <int, bool>{};

  ReparseResult get r => widget.result;
  String get unit => r.doc.isSectioned ? '节' : '页';

  Future<void> _save({bool all = false}) async {
    if (all) {
      for (final p in r.pages) {
        if (p.changed) p.useNew = true;
      }
    }
    if (r.chosen.isEmpty) {
      toast(context, '没有选择要替换的$unit');
      return;
    }
    setState(() => saving = true);
    try {
      final n = await context.read<AppState>().reparser.commit(r);
      if (mounted) Navigator.pop(context, n);
    } catch (e) {
      if (!mounted) return;
      setState(() => saving = false);
      toast(context, '保存失败，原来的文字没有改动：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = r.pages.where((p) => !onlyChanged || p.changed || p.failed).toList();
    final chosen = r.chosen.length;
    return GlassScaffold(
      title: '对比解析结果',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
            child: Glass(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${r.range.title} · 第 ${r.range.start}–${r.range.end} $unit',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${r.engine.label} · 有变化 ${r.changedCount} $unit${r.failedCount > 0 ? ' · ${r.failedCount} $unit失败（保留旧的）' : ''}',
                    style: TextStyle(color: M.sub, fontSize: 12),
                  ),
                  Row(
                    children: [
                      Text('只看有变化的$unit', style: TextStyle(color: M.sub, fontSize: 12)),
                      const Spacer(),
                      Switch(
                        value: onlyChanged,
                        activeThumbColor: M.sageDark,
                        onChanged: (v) => setState(() => onlyChanged = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text('新解析的文字和原来一样', style: TextStyle(color: M.sub)),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    children: [for (final p in list) _page(p)],
                  ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: GlassButton(
                    label: '放弃',
                    onTap: saving
                        ? null
                        : () {
                            toast(context, '已放弃，原来的文字没有改动');
                            Navigator.pop(context, 0);
                          },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GlassButton(
                    label: '替换全部',
                    onTap: saving || r.changedCount == 0 ? null : () => _save(all: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GlassButton(
                    label: '保存所选 $chosen',
                    tint: M.sage,
                    onTap: saving || chosen == 0 ? null : () => _save(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _page(ReparsePage p) {
    final viewNew = showNew[p.page] ?? !p.failed;
    final text = viewNew ? p.newText : p.oldText;
    int len(String t) => t.replaceAll(RegExp(r'\s'), '').length;
    Widget seg(String label, bool v) => GestureDetector(
      onTap: p.failed && v ? null : () => setState(() => showNew[p.page] = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: viewNew == v ? M.greyBlue.withValues(alpha: 0.35) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, fontWeight: viewNew == v ? FontWeight.w700 : FontWeight.w500),
        ),
      ),
    );
    final oldLabel = PageText.sourceLabel(p.oldSource);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Glass(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('第 ${p.page} $unit', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: M.glass.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [seg('旧', false), seg('新', true)]),
                ),
                const Spacer(),
                if (p.failed)
                  Text('解析失败 · 保留旧的', style: TextStyle(color: M.roseDark, fontSize: 12))
                else if (!p.changed)
                  Text('无变化', style: TextStyle(color: M.sub, fontSize: 12))
                else
                  GestureDetector(
                    onTap: () => setState(() => p.useNew = !p.useNew),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: p.useNew ? M.sage : M.glass.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        p.useNew ? '用新的' : '保留旧的',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: p.useNew ? Colors.white : M.text,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '旧：${p.oldParsed ? '${oldLabel.isEmpty ? '未记录来源' : oldLabel} · ${len(p.oldText)} 字' : '未解析'}'
              '${p.failed ? '' : '　新：${PageText.sourceLabel(p.newSource)} · ${len(p.newText)} 字'}',
              style: TextStyle(color: M.sub, fontSize: 11),
            ),
            const SizedBox(height: 8),
            if (text.trim().isEmpty)
              Text(viewNew ? '（新解析没有识别到文字）' : '（原来没有文字）', style: TextStyle(color: M.sub, fontSize: 13))
            else
              MathText(text.trim(), style: const TextStyle(fontSize: 14, height: 1.6)),
          ],
        ),
      ),
    );
  }
}

/// 查看这一章的知识点；[reanalyze] 为 true 时打开后直接重新分析（会先确认）。
Future<void> showChapterKps(BuildContext context, PdfDoc doc, ChapterRange range, {bool reanalyze = false}) =>
    showGlassSheet<void>(
      context,
      (ctx, sc) => ChapterKpSheet(doc: doc, range: range, scroll: sc, autoStart: reanalyze),
      initial: 0.8,
    );

class ChapterKpSheet extends StatefulWidget {
  final PdfDoc doc;
  final ChapterRange range;
  final ScrollController scroll;
  final bool autoStart;

  /// 测试 / 截图用：直接显示这份对比。
  final KpDiff? diff;
  const ChapterKpSheet({
    super.key,
    required this.doc,
    required this.range,
    required this.scroll,
    this.autoStart = false,
    this.diff,
  });
  @override
  State<ChapterKpSheet> createState() => _ChapterKpSheetState();
}

class _ChapterKpSheetState extends State<ChapterKpSheet> {
  List<KnowledgePoint>? kps;
  (int, int) coverage = (0, 0);
  KpDiff? diff;
  bool showOld = false, running = false;
  String message = '';
  double frac = 0;
  String? error;

  AppState get s => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    diff = widget.diff;
    _load().then((_) {
      if (widget.autoStart && mounted) _reanalyze();
    });
  }

  Future<void> _load() async {
    final l = await s.reparser.chapterKps(widget.doc, widget.range);
    final c = await s.reparser.kpCoverage(widget.doc, widget.range);
    if (mounted) {
      setState(() {
        kps = l;
        coverage = c;
      });
    }
  }

  /// 只分析这一章里还没分析的段落，已经有知识点的不动。
  Future<void> _continue() async {
    setState(() {
      running = true;
      error = null;
      message = '分析知识点…';
      frac = 0;
    });
    try {
      final gen = await s.generator(projectId: widget.doc.projectId);
      final r = await s.reparser.analyzePendingKps(widget.doc.projectId, gen, doc: widget.doc, chapter: widget.range, onProgress: (m, f) {
        if (mounted) {
          setState(() {
            message = m;
            frac = f;
          });
        }
      });
      await _load();
      if (mounted) {
        setState(() {
          running = false;
          if (!r.allDone) error = r.summary;
        });
        if (r.allDone) toast(context, r.summary);
      }
      s.changed();
    } catch (e) {
      await _load();
      if (mounted) {
        setState(() {
          running = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> _reanalyze() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: M.sheet,
        title: const Text('重新分析知识点？'),
        content: Text(
          '会清除这一章已缓存的知识点，用出题模型重新分析（${coverage.$2} 段文字，会产生少量费用）。'
          '之后的自动数量和出题都用新的知识点；已生成的闪卡和题目不受影响。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始分析')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      running = true;
      error = null;
      message = '分析知识点…';
      frac = 0;
    });
    try {
      final gen = await s.generator(projectId: widget.doc.projectId);
      final d = await s.reparser.reanalyzeKps(
        widget.doc,
        widget.range,
        gen,
        onProgress: (m, f) {
          if (mounted) {
            setState(() {
              message = m.replaceFirst('提取知识点', '分析知识点');
              frac = f;
            });
          }
        },
      );
      await _load();
      if (mounted) {
        setState(() {
          diff = d;
          running = false;
          showOld = false;
        });
      }
      s.changed();
    } catch (e) {
      await _load();
      if (mounted) {
        setState(() {
          running = false;
          error = '分析失败，原来的知识点已保留：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = diff;
    final list = d == null ? (kps ?? []) : (showOld ? d.oldKps : d.newKps);
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('本章知识点', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              onPressed: running || kps == null ? null : _reanalyze,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重新分析知识点'),
              style: TextButton.styleFrom(foregroundColor: M.sageDark),
            ),
          ],
        ),
        Text(
          '${widget.range.title} · ${d == null ? '${kps?.length ?? 0} 个知识点' : '新 ${d.newKps.length} 个 · 之前 ${d.oldKps.length} 个'}'
          '${coverage.$2 > 0 && coverage.$1 < coverage.$2 && d == null ? ' · ${coverage.$2 - coverage.$1}/${coverage.$2} 段还没分析' : ''}',
          style: TextStyle(color: M.sub, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text('自动数量和出题会用这些知识点。', style: TextStyle(color: M.sub, fontSize: 12)),
        if (!running && d == null && kps != null && coverage.$2 > 0 && coverage.$1 < coverage.$2) ...[
          const SizedBox(height: 10),
          GlassButton(
            label: '分析没分析的 ${coverage.$2 - coverage.$1} 段',
            icon: Icons.auto_awesome_outlined,
            tint: M.sage,
            expand: true,
            onTap: _continue,
          ),
        ],
        if (running) ...[
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: frac <= 0 ? null : frac.clamp(0.0, 1.0),
            color: M.sage,
            backgroundColor: M.glass.withValues(alpha: 0.5),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!, style: TextStyle(color: M.roseDark, fontSize: 13)),
        ],
        if (d != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              _tab('新的 ${d.newKps.length}', !showOld, () => setState(() => showOld = false)),
              const SizedBox(width: 8),
              _tab('之前的 ${d.oldKps.length}', showOld, () => setState(() => showOld = true)),
              const Spacer(),
              Text('新增 ${d.addedIds.length} · 移除 ${d.removedIds.length}', style: TextStyle(color: M.sub, fontSize: 12)),
            ],
          ),
        ],
        const SizedBox(height: 10),
        if (kps == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (list.isEmpty && !running)
          Glass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(showOld ? '之前没有分析过知识点' : '这一章还没有分析知识点', style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('用「自动数量」或出题时会自动分析；也可以现在分析。', style: TextStyle(color: M.sub, fontSize: 12)),
                if (!showOld) ...[
                  const SizedBox(height: 10),
                  GlassButton(label: '分析知识点', icon: Icons.auto_awesome_outlined, tint: M.sage, onTap: _reanalyze),
                ],
              ],
            ),
          )
        else
          for (final k in list) _kp(k, d),
      ],
    );
  }

  Widget _tab(String label, bool sel, VoidCallback onTap) => Glass(
    radius: 14,
    tint: sel ? M.sage : null,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    onTap: onTap,
    child: Text(
      label,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sel ? Colors.white : M.text),
    ),
  );

  Widget _kp(KnowledgePoint k, KpDiff? d) {
    final tag = d == null
        ? null
        : showOld
        ? (d.removedIds.contains(k.id) ? ('已移除', M.roseDark) : null)
        : (d.addedIds.contains(k.id) ? ('新增', M.sageDark) : null);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: MathText(k.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                ),
                if (k.type.isNotEmpty) Text(k.type, style: TextStyle(color: M.sub, fontSize: 11)),
                if (d == null)
                  SizedBox(
                    width: 32,
                    height: 28,
                    child: FavoriteButton(kind: 'kp', targetId: k.id, projectId: k.projectId, title: k.title, size: 20),
                  ),
                if (tag != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: tag.$2.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      tag.$1,
                      style: TextStyle(color: tag.$2, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ],
            ),
            if (k.content.isNotEmpty) ...[
              const SizedBox(height: 4),
              MathText(k.content, style: TextStyle(fontSize: 13, height: 1.5, color: M.sub)),
            ],
            if (k.page > 0) ...[
              const SizedBox(height: 2),
              Text('第 ${k.page} ${widget.doc.isSectioned ? '节' : '页'}', style: TextStyle(color: M.sub, fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}


/// 「分析未分析的章节」：只分析还没分析完的章节，已经分析好的不动。没有要分析的章节时不显示。
class KpPendingCard extends StatefulWidget {
  final String projectId;
  final PdfDoc? doc; // 只看这一份资料；为空就是整个项目
  final VoidCallback? onDone;
  const KpPendingCard({super.key, required this.projectId, this.doc, this.onDone});
  @override
  State<KpPendingCard> createState() => _KpPendingCardState();
}

class _KpPendingCardState extends State<KpPendingCard> {
  List<KpPending>? pending;
  bool running = false;
  String message = '';
  double frac = 0;

  AppState get s => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await s.reparser.pendingKps(widget.projectId, doc: widget.doc);
    if (mounted) setState(() => pending = l);
  }

  Future<void> _run() async {
    final list = pending ?? const <KpPending>[];
    final chunks = {for (final p in list) for (final c in p.chunks) c.id}.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: M.sheet,
        title: const Text('分析未分析的章节？'),
        content: Text('共 ${list.length} 章、$chunks 段文字还没分析。只分析这些，已经分析好的不动；会产生少量费用。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始分析')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final app = s; // 分析期间页面可能被刷新，之后不能再用 context
    setState(() => (running = true, message = '分析知识点…', frac = 0));
    String result;
    try {
      final gen = await app.generator(projectId: widget.projectId);
      final r = await app.reparser.analyzePendingKps(widget.projectId, gen, doc: widget.doc, onProgress: (m, f) {
        if (mounted) setState(() => (message = m, frac = f));
      });
      result = r.summary;
    } catch (e) {
      result = '$e';
    }
    if (mounted) toast(context, result);
    if (mounted) setState(() => running = false);
    app.changed();
    if (mounted) await _load();
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final list = pending;
    if (list == null || (list.isEmpty && !running)) return const SizedBox();
    final chunks = {for (final p in list) for (final c in p.chunks) c.id}.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Glass(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('还有 ${list.length} 章没分析完', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('共 $chunks 段文字。只分析这些，已经分析好的不动。', style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
          const SizedBox(height: 10),
          if (running) ...[
            Text(message, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: frac <= 0 ? null : frac.clamp(0.0, 1.0), color: M.sage, backgroundColor: M.glass.withValues(alpha: 0.5)),
          ] else
            GlassButton(label: '分析未分析的章节', icon: Icons.auto_awesome_outlined, tint: M.sage, expand: true, onTap: _run),
        ]),
      ),
    );
  }
}
