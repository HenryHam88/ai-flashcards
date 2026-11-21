import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';
import '../theme/html_clean.dart' show displayPlainText;

// ============================================================================
// 章节内容（只读）：按页显示某一章解析出的文字，公式按教材样式排版。
// 不修改任何解析或分章数据。
// ============================================================================

/// 一页的显示内容。
class ChapterPageView {
  final int page;
  final String text;
  final String source; // 解析来源标记，见 PageText.sourceLabel
  final bool parsed; // false：这一页还没有解析
  final List<String> sections; // 从这一页开始的小节
  ChapterPageView(this.page, this.text, this.source, this.parsed, this.sections);
}

/// 组装一章的内容：范围内每一页（缺页标记为未解析），并在小节开始的页上标出小节名。
List<ChapterPageView> buildChapterPages(ChapterRange range, List<PageText> pages, List<Chunk> chunks) {
  final byPage = {for (final p in pages) p.page: p};
  final starts = <int, List<String>>{};
  String? last;
  for (final c in chunks.where((c) => c.pageEnd >= range.start && c.pageStart <= range.end)) {
    final s = c.section.trim();
    if (s.isEmpty || s == last) continue;
    last = s;
    starts.putIfAbsent(c.pageStart < range.start ? range.start : c.pageStart, () => []).add(s);
  }
  return [
    for (var p = range.start; p <= range.end; p++)
      ChapterPageView(p, byPage[p]?.text ?? '', byPage[p]?.source ?? '', byPage.containsKey(p), starts[p] ?? const []),
  ];
}

/// 页面提示：没有文字 / 文字很少（可能是图片页）。正常返回 null。
String? pageNote(ChapterPageView p, {String unit = '页'}) {
  if (!p.parsed) return '这一$unit还没有解析';
  final n = displayPlainText(p.text).replaceAll(RegExp(r'\s'), '').length;
  if (n == 0) return '这一$unit没有识别到文字（可能是空白页或图片）';
  if (n < 40) return '这一$unit文字很少，可能是图片、图表或解析不完整';
  return null;
}

/// 关键词出现次数（不区分大小写，公式源码也算）。
int countMatches(String text, String q) {
  final k = q.trim().toLowerCase();
  if (k.isEmpty) return 0;
  final t = text.toLowerCase();
  var n = 0, i = 0;
  while ((i = t.indexOf(k, i)) >= 0) {
    n++;
    i += k.length;
  }
  return n;
}

/// 本章出现过的解析来源（显示名），旧数据没有记录时返回空列表。
List<String> sourcesOf(List<ChapterPageView> pages) =>
    {for (final p in pages) PageText.sourceLabel(p.source)}.where((e) => e.isNotEmpty).toList();

/// 复制用的纯文本：带页码标记。
String chapterPlainText(String title, List<ChapterPageView> pages, {String unit = '页'}) => [
      title,
      for (final p in pages.where((p) => p.text.trim().isNotEmpty)) '【第 ${p.page} $unit】\n${displayPlainText(p.text)}',
    ].join('\n\n');

class ChapterViewPage extends StatefulWidget {
  final PdfDoc doc;
  final int initialIndex;
  /// 分章方案；为空时读取已保存的方案（章节编辑页会传入当前正在编辑的列表）。
  final List<ChapterRange>? chapters;
  const ChapterViewPage({super.key, required this.doc, this.initialIndex = 0, this.chapters});
  @override
  State<ChapterViewPage> createState() => _ChapterViewPageState();
}

class _ChapterViewPageState extends State<ChapterViewPage> {
  List<ChapterRange> chapters = [];
  List<PageText> allPages = [];
  List<Chunk> chunks = [];
  late int index = widget.initialIndex;
  bool loading = true;
  bool searching = false;
  final query = TextEditingController();
  int current = 0; // 当前定位到第几个匹配
  final scroll = ScrollController();
  final keys = <int, GlobalKey>{};

  PdfDoc get doc => widget.doc;
  String get unit => doc.isWord ? '节' : '页';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    query.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final pages = await s.repo.pages(doc.projectId, docId: doc.id);
    final cs = (await s.repo.chunks(doc.projectId)).where((c) => c.docId == doc.id).toList();
    var list = widget.chapters;
    if (list == null || list.isEmpty) list = (await s.repo.chapterPlan(doc.id))?.chapters;
    if (list == null || list.isEmpty) {
      final total = [1, doc.pageCount, if (pages.isNotEmpty) pages.last.page].reduce((a, b) => a > b ? a : b);
      list = [ChapterRange('全文', 1, total)];
    }
    if (!mounted) return;
    setState(() {
      allPages = pages;
      chunks = cs;
      chapters = list!;
      index = index.clamp(0, chapters.length - 1);
      loading = false;
    });
  }

  ChapterRange get chapter => chapters[index];
  List<ChapterPageView> get pages => buildChapterPages(chapter, allPages, chunks);

  void _go(int i) {
    if (i < 0 || i >= chapters.length) return;
    setState(() {
      index = i;
      current = 0;
      keys.clear();
    });
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  /// 跳到第 [i] 个匹配所在的页。
  void _jump(List<ChapterPageView> ps, int i) {
    final q = query.text;
    final total = ps.fold<int>(0, (a, p) => a + countMatches(displayPlainText(p.text), q));
    if (total == 0) return;
    current = (i % total + total) % total;
    var acc = 0;
    for (final p in ps) {
      final n = countMatches(displayPlainText(p.text), q);
      if (current < acc + n) {
        final ctx = keys[p.page]?.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), alignment: 0.05);
        break;
      }
      acc += n;
    }
    setState(() {});
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    toast(context, '已复制$what（${text.replaceAll(RegExp(r'\s'), '').length} 字）');
  }

  void _generate() {
    Navigator.pop(context, GenOptions(scope: 'chapters', chapters: [chapter.title]));
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const GlassScaffold(title: '章节内容', body: Center(child: CircularProgressIndicator()));
    }
    final ps = pages;
    final q = query.text.trim();
    final total = q.isEmpty ? 0 : ps.fold<int>(0, (a, p) => a + countMatches(displayPlainText(p.text), q));
    final sources = sourcesOf(ps);
    return GlassScaffold(
      title: '章节内容',
      actions: [
        IconButton(
          tooltip: '在本章搜索',
          icon: Icon(searching ? Icons.search_off_rounded : Icons.search_rounded),
          onPressed: () => setState(() {
            searching = !searching;
            if (!searching) query.clear();
          }),
        ),
        IconButton(
          tooltip: '复制本章文字',
          icon: const Icon(Icons.copy_rounded),
          onPressed: () => _copy(chapterPlainText(chapter.title, ps, unit: unit), '本章文字'),
        ),
      ],
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(children: [
            IconButton(
                tooltip: '上一章',
                onPressed: index > 0 ? () => _go(index - 1) : null,
                icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(
              child: Glass(
                radius: 16,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: index,
                    isExpanded: true,
                    dropdownColor: M.sheet,
                    borderRadius: BorderRadius.circular(14),
                    items: [
                      for (var i = 0; i < chapters.length; i++)
                        DropdownMenuItem(
                            value: i,
                            child: Text('${i + 1}. ${chapters[i].title}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
                    ],
                    onChanged: (v) => v == null ? null : _go(v),
                  ),
                ),
              ),
            ),
            IconButton(
                tooltip: '下一章',
                onPressed: index < chapters.length - 1 ? () => _go(index + 1) : null,
                icon: const Icon(Icons.chevron_right_rounded)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 4),
          child: Row(children: [
            Expanded(
              child: Text(
                '${doc.name} · 第 ${chapter.start}–${chapter.end} $unit · 解析：${sources.isEmpty ? '未记录（旧版本解析）' : sources.join('、')}',
                style: TextStyle(color: M.sub, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
        if (searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: query,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() => current = 0),
                  onSubmitted: (_) => _jump(ps, current + 1),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    hintText: '在本章中搜索',
                    filled: true,
                    fillColor: M.glass.withValues(alpha: 0.6),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(q.isEmpty ? '' : (total == 0 ? '无结果' : '${current + 1}/$total'),
                  style: TextStyle(color: M.sub, fontSize: 12)),
              IconButton(
                  onPressed: total == 0 ? null : () => _jump(ps, current - 1),
                  icon: const Icon(Icons.keyboard_arrow_up_rounded)),
              IconButton(
                  onPressed: total == 0 ? null : () => _jump(ps, current + 1),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded)),
            ]),
          ),
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
            children: [
              for (final p in ps) _page(p, q),
            ],
          ),
        ),
        SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: GlassButton(
              label: '用这章出题', icon: Icons.auto_awesome_rounded, tint: M.sage, expand: true, onTap: _generate),
        ),
      ]),
    );
  }

  Widget _page(ChapterPageView p, String q) {
    final note = pageNote(p, unit: unit);
    final key = keys.putIfAbsent(p.page, () => GlobalKey());
    final hits = q.isEmpty ? 0 : countMatches(displayPlainText(p.text), q);
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final s in p.sections)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(children: [
              Icon(Icons.bookmark_rounded, size: 16, color: M.sageDark),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(s, style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w700, fontSize: 14))),
            ]),
          ),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: M.greyBlue.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(8)),
                child: Text('第 ${p.page} $unit', style: TextStyle(fontSize: 12, color: M.text, fontWeight: FontWeight.w600)),
              ),
              if (hits > 0) ...[
                const SizedBox(width: 6),
                Text('$hits 处匹配', style: TextStyle(fontSize: 11, color: M.sageDark)),
              ],
              const Spacer(),
              if (p.text.trim().isNotEmpty)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _copy(displayPlainText(p.text), '第 ${p.page} $unit'),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.content_copy_rounded, size: 16, color: M.sub),
                  ),
                ),
            ]),
            if (note != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.info_outline_rounded, size: 16, color: M.roseDark),
                const SizedBox(width: 6),
                Expanded(child: Text(note, style: TextStyle(color: M.roseDark, fontSize: 12))),
              ]),
            ],
            if (p.text.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              MathText(p.text.trim(), highlight: q.isEmpty ? null : q, style: const TextStyle(fontSize: 15, height: 1.65)),
            ],
          ]),
        ),
      ]),
    );
  }
}
