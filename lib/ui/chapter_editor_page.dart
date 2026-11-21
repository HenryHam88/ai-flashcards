import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/chapters.dart';
import '../theme/glass.dart';
import 'home_page.dart' show promptText;

/// 编辑一份资料的章节：重命名、新增、删除、与下一章合并、按页拆分、调整起始页；
/// 也可以按页数自动切分、让 AI 重新分章或恢复自动识别。保存后用于生成范围和出处显示。
class ChapterEditorPage extends StatefulWidget {
  final PdfDoc doc;
  const ChapterEditorPage({super.key, required this.doc});
  @override
  State<ChapterEditorPage> createState() => _ChapterEditorPageState();
}

class _ChapterEditorPageState extends State<ChapterEditorPage> {
  List<ChapterRange> list = [];
  String source = 'manual';
  int total = 1;
  bool loading = true, dirty = false, busy = false;

  AppState get s => context.read<AppState>();
  PdfDoc get doc => widget.doc;
  String get unit => doc.isWord ? '节' : '页';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pages = await s.repo.pages(doc.projectId, docId: doc.id);
    total = [1, doc.pageCount, if (pages.isNotEmpty) pages.last.page].reduce((a, b) => a > b ? a : b);
    var plan = await s.repo.chapterPlan(doc.id);
    // 旧版本解析的资料还没有方案：先用不花钱的自动识别生成一个
    plan ??= await s.chapterService.autoPlan(doc, allowAi: false);
    if (!mounted) return;
    setState(() {
      list = plan!.chapters;
      source = plan.source;
      loading = false;
    });
  }

  void _set(List<ChapterRange> l, {String src = 'manual'}) => setState(() {
        list = l;
        source = src;
        dirty = true;
      });

  Future<int?> _askPage(String title, {int? initial, String hint = ''}) async {
    final v = await promptText(context, title, initial: initial?.toString() ?? '', hint: hint);
    final n = int.tryParse(v?.trim() ?? '');
    if (v != null && n == null && mounted) toast(context, '请输入数字');
    return n;
  }

  Future<void> _rename(int i) async {
    final t = await promptText(context, '重命名章节', initial: list[i].title);
    if (t != null && t.trim().isNotEmpty) _set(renameChapter(list, i, t));
  }

  Future<void> _split(int i) async {
    final c = list[i];
    if (c.end <= c.start) return toast(context, '这一章只有 1 $unit，无法拆分');
    final p = await _askPage('从第几$unit开始拆出新章节？', hint: '${c.start + 1}–${c.end}');
    if (p == null) return;
    if (p <= c.start || p > c.end) return mounted ? toast(context, '请输入 ${c.start + 1}–${c.end} 之间的$unit码') : null;
    final t = mounted ? await promptText(context, '新章节名称', hint: '例如：第三章 随机变量') : null;
    _set(splitChapter(list, i, p, t ?? ''));
  }

  Future<void> _start(int i) async {
    final lo = list[i - 1].start + 1, hi = list[i].end;
    final p = await _askPage('「${list[i].title}」从第几$unit开始？', initial: list[i].start, hint: '$lo–$hi');
    if (p == null) return;
    if (p < lo || p > hi) return mounted ? toast(context, '请输入 $lo–$hi 之间的$unit码') : null;
    _set(setChapterStart(list, i, p));
  }

  Future<void> _add() async {
    final p = await _askPage('新章节从第几$unit开始？', hint: '1–$total');
    if (p == null) return;
    if (p < 1 || p > total) return mounted ? toast(context, '请输入 1–$total 之间的$unit码') : null;
    final t = mounted ? await promptText(context, '新章节名称') : null;
    if (t == null || t.trim().isEmpty) return;
    _set(addChapter(list, p, t));
  }

  Future<void> _fixed() async {
    final n = await _askPage('每几$unit切成一章？', initial: defaultEvery(total, word: doc.isWord));
    if (n == null || n < 1) return;
    _set(fixedRanges(total, n, word: doc.isWord), src: 'fixed');
  }

  Future<void> _ai() async {
    setState(() => busy = true);
    try {
      final pages = await s.repo.pages(doc.projectId, docId: doc.id);
      final r = await s.chapterService.aiRanges(doc, pages);
      if (!mounted) return;
      if (r.isEmpty) {
        toast(context, 'AI 分章失败（可能未配置出题模型密钥），已保留当前章节');
      } else {
        _set(r, src: 'ai');
        toast(context, 'AI 分为 ${r.length} 章，确认后点「保存」');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _auto() async {
    final plan = await s.chapterService.autoPlan(doc, allowAi: false, keepManual: false);
    if (!mounted) return;
    _set(plan.chapters, src: plan.source);
    toast(context, '已按「${chapterSourceNames[plan.source]}」重新识别为 ${plan.chapters.length} 章');
  }

  Future<void> _save() async {
    if (!validRanges(list, total)) return toast(context, '章节范围有误，请检查');
    setState(() => busy = true);
    await s.chapterService.apply(doc, ChapterPlan(docId: doc.id, projectId: doc.projectId, source: source, chapters: list));
    s.changed();
    if (!mounted) return;
    setState(() => (busy = false, dirty = false));
    toast(context, '已保存，生成范围和卡片出处已按新章节更新');
    Navigator.pop(context, true);
  }

  Future<bool> _confirmLeave() async {
    if (!dirty) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF4F1EC),
        title: const Text('放弃修改？'),
        content: const Text('章节的修改还没有保存。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('继续编辑')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('放弃')),
        ],
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.pop(context);
      },
      child: GlassScaffold(
        title: '编辑章节',
        actions: [
          TextButton(
            onPressed: busy || loading ? null : _save,
            child: Text('保存', style: TextStyle(fontWeight: FontWeight.w700, color: dirty ? M.sageDark : M.sub)),
          ),
        ],
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
                Glass(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(doc.isWord ? Icons.description_outlined : Icons.picture_as_pdf_outlined,
                          size: 20, color: doc.isWord ? const Color(0xFF6F8296) : M.roseDark),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(doc.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: 6),
                    Text('共 $total $unit · ${list.length} 章 · 来源：${chapterSourceNames[source] ?? source}${dirty ? '（未保存）' : ''}',
                        style: const TextStyle(color: M.sub, fontSize: 12)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      _chip(Icons.add, '新增章节', _add),
                      _chip(Icons.view_agenda_outlined, '按$unit数切分', _fixed),
                      _chip(Icons.auto_awesome_outlined, '让 AI 重新分章', _ai),
                      _chip(Icons.restart_alt_rounded, '恢复自动识别', _auto),
                    ]),
                    if (busy) ...[
                      const SizedBox(height: 10),
                      const LinearProgressIndicator(minHeight: 3, color: M.sage, backgroundColor: Colors.white54),
                    ],
                  ]),
                ),
                const SizedBox(height: 6),
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 6, 4, 8),
                  child: Text('点章节可重命名；右侧菜单可拆分、合并、调整起始页或删除。',
                      style: TextStyle(color: M.sub, fontSize: 12)),
                ),
                for (var i = 0; i < list.length; i++) _tile(i),
              ]),
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) => ActionChip(
        avatar: Icon(icon, size: 16, color: M.sageDark),
        label: Text(label),
        onPressed: busy ? null : onTap,
      );

  Widget _tile(int i) {
    final c = list[i];
    final pages = c.end - c.start + 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        onTap: () => _rename(i),
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: M.sage.withValues(alpha: 0.18), shape: BoxShape.circle),
            child: Text('${i + 1}', style: const TextStyle(color: M.sageDark, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('第 ${c.start}–${c.end} $unit · 共 $pages $unit', style: const TextStyle(color: M.sub, fontSize: 12)),
            ]),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: M.sub),
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  _rename(i);
                case 'split':
                  _split(i);
                case 'start':
                  _start(i);
                case 'merge':
                  _set(mergeWithNext(list, i));
                case 'delete':
                  _set(deleteChapter(list, i));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('重命名')),
              if (c.end > c.start) PopupMenuItem(value: 'split', child: Text('在某一$unit拆分')),
              if (i > 0) const PopupMenuItem(value: 'start', child: Text('调整起始页')),
              if (i < list.length - 1) const PopupMenuItem(value: 'merge', child: Text('与下一章合并')),
              if (list.length > 1) const PopupMenuItem(value: 'delete', child: Text('删除（并入相邻章节）')),
            ],
          ),
        ]),
      ),
    );
  }
}
