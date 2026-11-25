import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/llm.dart';
import '../services/pdf_export.dart';
import 'pdf_export_sheet.dart' show confirmMissingGlyphs;
import '../theme/glass.dart';
import 'ai_widgets.dart';
import 'explain_sheet.dart' show showSourceSheet;
import 'settings_pages.dart' show fmtSize, saveOrShareFile;

/// 导出笔记 PDF（解析知识点、题目、照片后排版），然后保存或分享。
Future<void> exportNotesPdf(BuildContext context, String title, List<StudyNote> notes) async {
  final s = context.read<AppState>();
  toast(context, '正在生成 PDF…');
  try {
    final docNames = {for (final d in await s.repo.docs(notes.isEmpty ? '' : notes.first.projectId)) d.id: d.name};
    final items = <NoteExport>[];
    for (final n in notes) {
      final photos = <Uint8List>[];
      for (final id in n.photoIds) {
        final f = await s.notePhoto(id);
        if (f != null) photos.add(await f.readAsBytes());
      }
      items.add(NoteExport(n,
          kp: n.kpId.isEmpty ? null : await s.repo.kp(n.kpId),
          questions: [for (final id in n.questionIds) ?await s.repo.question(id)],
          photos: photos,
          docNames: docNames));
    }
    final svc = await s.pdfExporter();
    if (!context.mounted) return;
    if (!await confirmMissingGlyphs(context, svc.missingGlyphs(PdfExportService.noteTexts(title, items)))) return;
    final bytes = await svc.notes(title, items);
    final name = '$title-笔记-${PdfExportService.dateLabel(DateTime.now())}.pdf'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    await s.saveExport(notes.isEmpty ? '' : notes.first.projectId, name, bytes);
    if (context.mounted) await saveOrShareFile(context, bytes, name, title: 'PDF 已生成（${fmtSize(bytes.length)}）', mimeType: 'application/pdf');
  } catch (e) {
    if (context.mounted) toast(context, '导出失败：$e');
  }
}

/// 打开（或新建）一个知识点的笔记。
Future<void> openNoteFor(BuildContext context, {required String projectId, String kpId = '', String title = '', String chapter = '', String ai = '', NoteQuote? quote}) async {
  final s = context.read<AppState>();
  final n = await s.noteFor(projectId: projectId, kpId: kpId, title: title, chapter: chapter);
  if (ai.isNotEmpty) n.ai = n.ai.trim().isEmpty ? ai : '${n.ai}\n\n$ai';
  if (quote != null) n.quotes = [...n.quotes, quote];
  if (ai.isNotEmpty || quote != null) await s.saveNote(n);
  if (context.mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteEditorPage(note: n)));
}

/// 笔记：按章节分组，可搜索；每条笔记挂在一个知识点下。
class NotesPage extends StatefulWidget {
  final String projectId;
  const NotesPage({super.key, required this.projectId});
  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return FutureBuilder<(List<StudyNote>, String)>(
      key: ValueKey(s.version),
      future: () async {
        final l = (await s.repo.notes(projectId: widget.projectId))..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return (l, (await s.repo.project(widget.projectId))?.name ?? '笔记');
      }(),
      builder: (context, snap) {
        final all = snap.data?.$1;
        final q = query.trim().toLowerCase();
        final list = all == null
            ? <StudyNote>[]
            : all
                .where((n) =>
                    q.isEmpty ||
                    [n.title, n.own, n.ai, n.chapter, ...n.quotes.map((e) => e.text)].any((t) => t.toLowerCase().contains(q)))
                .toList();
        // 按章节分组，章节按最近修改排序
        final groups = <String, List<StudyNote>>{};
        for (final n in list) {
          groups.putIfAbsent(n.chapter.isEmpty ? '未分章' : n.chapter, () => []).add(n);
        }
        return GlassScaffold(
          title: '笔记',
          actions: [
            if (all != null && all.isNotEmpty)
              IconButton(
                  tooltip: '导出 PDF',
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  onPressed: () => exportNotesPdf(context, snap.data!.$2, [for (final g in groups.values) ...g])),
          ],
          body: all == null
              ? const SizedBox()
              : ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 40), children: [
                  GlassButton(
                    label: '新建笔记',
                    icon: Icons.edit_note_rounded,
                    tint: M.sage,
                    expand: true,
                    onTap: () async {
                      final kp = await pickKnowledgePoint(context, widget.projectId);
                      if (kp == null || !context.mounted) return;
                      await openNoteFor(context, projectId: widget.projectId, kpId: kp.id, title: kp.title, chapter: kp.chapter);
                    },
                  ),
                  if (all.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    TextField(
                      onChanged: (v) => setState(() => query = v),
                      decoration: const InputDecoration(hintText: '搜索笔记、讲解和引用', prefixIcon: Icon(Icons.search_rounded)),
                    ),
                  ],
                  if (all.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('还没有笔记。点「新建笔记」选一个知识点开始写；也可以在学习板块的导图节点、AI 伴学的回答里点「写笔记」「存为笔记」。',
                          style: TextStyle(color: M.sub, height: 1.6)),
                    ),
                  for (final e in groups.entries) ...[
                    SectionTitle(e.key),
                    for (final n in e.value) Padding(padding: const EdgeInsets.only(bottom: 10), child: NoteTile(note: n)),
                  ],
                ]),
        );
      },
    );
  }
}

class NoteTile extends StatelessWidget {
  final StudyNote note;
  const NoteTile({super.key, required this.note});

  @override
  Widget build(BuildContext context) {
    final n = note;
    final body = n.own.trim().isNotEmpty ? n.own : n.ai;
    final meta = [
      if (n.photoIds.isNotEmpty) '${n.photoIds.length} 张照片',
      if (n.questionIds.isNotEmpty) '${n.questionIds.length} 道题',
      if (n.quotes.isNotEmpty) '${n.quotes.length} 段原文',
      '${n.updatedAt.month}月${n.updatedAt.day}日',
    ].join(' · ');
    return Glass(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteEditorPage(note: n))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MathText(n.title.isEmpty ? '（无标题）' : n.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        if (body.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(body.replaceAll(RegExp(r'\$+|\*\*'), '').replaceAll(RegExp(r'\s+'), ' '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
        ],
        if (n.photoIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final id in n.photoIds.take(5)) Padding(padding: const EdgeInsets.only(right: 6), child: PhotoThumb(id: id, size: 56)),
            ]),
          ),
        ],
        const SizedBox(height: 6),
        Text(meta, style: TextStyle(color: M.sub, fontSize: 12)),
      ]),
    );
  }
}

/// 照片缩略图：按显示尺寸解码，放到云端的照片点开时再下载。
class PhotoThumb extends StatelessWidget {
  final String id;
  final double size;
  final VoidCallback? onTap;
  const PhotoThumb({super.key, required this.id, this.size = 88, this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: size,
          height: size,
          child: FutureBuilder<File?>(
            future: () async {
              final m = await s.repo.mediaAsset(id);
              if (m == null) return null;
              final f = File(m.localPath);
              return f.existsSync() ? f : null; // 列表里不自动下载，避免耗流量
            }(),
            builder: (context, snap) {
              final f = snap.data;
              if (f == null) {
                return Container(
                  color: M.glass.withValues(alpha: 0.6),
                  child: Icon(snap.connectionState == ConnectionState.done ? Icons.cloud_outlined : Icons.photo_outlined, color: M.sub, size: 20),
                );
              }
              final px = (size * MediaQuery.of(context).devicePixelRatio).round();
              return Image.file(f, fit: BoxFit.cover, cacheWidth: px);
            },
          ),
        ),
      ),
    );
  }
}

/// 选择知识点（按章节分组，可搜索）。
Future<KnowledgePoint?> pickKnowledgePoint(BuildContext context, String projectId) async {
  final kps = await context.read<AppState>().repo.kps(projectId);
  if (!context.mounted) return null;
  var q = '';
  return showGlassSheet<KnowledgePoint>(
    context,
    (ctx, sc) => StatefulBuilder(builder: (ctx, set) {
      final l = kps.where((k) => q.isEmpty || k.title.contains(q) || k.content.contains(q) || k.chapter.contains(q)).toList();
      String? last;
      return ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
        const Text('选择知识点', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('笔记会挂在这个知识点下面，之后从学习板块、收藏里都能找到。', style: TextStyle(color: M.sub, fontSize: 13)),
        const SizedBox(height: 10),
        TextField(onChanged: (v) => set(() => q = v.trim()), decoration: const InputDecoration(hintText: '搜索知识点', prefixIcon: Icon(Icons.search_rounded))),
        if (kps.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text('这个项目还没有分析知识点。生成闪卡或在章节菜单里「查看知识点」时会自动分析。', style: TextStyle(color: M.sub, height: 1.5))),
        for (final k in l) ...[
          if (k.chapter != last && (last = k.chapter).isNotEmpty) SectionTitle(k.chapter),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Glass(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              onTap: () => Navigator.pop(ctx, k),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                MathText(k.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                if (k.content.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  MathText(k.content, style: TextStyle(fontSize: 12, color: M.sub, height: 1.5)),
                ],
              ]),
            ),
          ),
        ],
      ]);
    }),
    initial: 0.8,
  );
}

/// 笔记编辑：照片、我的理解、AI 讲解、相关题目、引用原文，改动自动保存。
class NoteEditorPage extends StatefulWidget {
  final StudyNote note;
  const NoteEditorPage({super.key, required this.note});
  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final StudyNote n = widget.note;
  late final title = TextEditingController(text: n.title);
  late final own = TextEditingController(text: n.own);
  KnowledgePoint? kp;
  List<Question> questions = [];
  Map<String, PdfDoc> docs = {};
  bool aiBusy = false;
  final aiRun = AiRun();
  bool dirty = false;
  late final AppState s = context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final k = n.kpId.isEmpty ? null : await s.repo.kp(n.kpId);
    final qs = [for (final id in n.questionIds) ?await s.repo.question(id)];
    final d = {for (final x in await s.repo.docs(n.projectId)) x.id: x};
    if (mounted) setState(() => (kp = k, questions = qs, docs = d));
  }

  Future<void> _save() async {
    n
      ..title = title.text.trim()
      ..own = own.text;
    if (n.isEmpty && n.title.isEmpty) return;
    dirty = false;
    await s.saveNote(n);
  }

  @override
  void dispose() {
    if (dirty) _save();
    title.dispose();
    own.dispose();
    aiRun.dispose();
    super.dispose();
  }

  Future<void> _addPhoto(ImageSource src) async {
    try {
      // 由系统相机 / 相册压缩：长边不超过 1600，JPEG 质量 80（一张通常 200–400 KB）
      final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
      if (x == null) return;
      n
        ..title = title.text.trim()
        ..own = own.text;
      await s.addNotePhoto(n, await x.readAsBytes());
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) toast(context, '添加照片失败：$e');
    }
  }

  void _photoMenu() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: M.sheet,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('拍照'),
                onTap: () {
                  Navigator.pop(ctx);
                  _addPhoto(ImageSource.camera);
                }),
            ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                onTap: () {
                  Navigator.pop(ctx);
                  _addPhoto(ImageSource.gallery);
                }),
            const SizedBox(height: 8),
          ]),
        ),
      );

  Future<void> _openPhoto(String id) async {
    final f = await s.notePhoto(id);
    if (!mounted) return;
    if (f == null) {
      toast(context, '照片已放到云端，请先在「我的 → 云端存储」里配置后再查看');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => GlassScaffold(
        title: '照片',
        actions: [
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              Navigator.pop(ctx);
              await s.removeNotePhoto(n, id);
              if (mounted) setState(() {});
            },
          ),
        ],
        body: InteractiveViewer(maxScale: 5, child: Center(child: Image.file(f))),
      ),
    ));
  }

  Future<void> _ai() async {
    setState(() => aiBusy = true);
    try {
      n
        ..title = title.text.trim()
        ..own = own.text;
      final a = await s.noteExplain(n, io: aiRun.start());
      n
        ..ai = a.content
        ..aiSources = a.sources.isEmpty ? '' : WebSource.encode(a.sources);
      await s.saveNote(n);
    } on LlmCancelled {
      if (mounted) toast(context, '已停止');
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    aiRun.finish();
    if (mounted) setState(() => aiBusy = false);
  }

  Future<void> _addQuestions() async {
    final all = await s.repo.questions(projectId: n.projectId);
    if (!mounted) return;
    // 同一知识点的题排在前面
    all.sort((a, b) => (b.kpId == n.kpId ? 1 : 0).compareTo(a.kpId == n.kpId ? 1 : 0));
    final picked = {...n.questionIds};
    final r = await showGlassSheet<Set<String>>(
      context,
      (ctx, sc) => StatefulBuilder(
        builder: (ctx, set) => Column(children: [
          Expanded(
            child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 12), children: [
              const Text('相关题目', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('同一知识点的题目排在前面。', style: TextStyle(color: M.sub, fontSize: 13)),
              const SizedBox(height: 6),
              if (all.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('这个项目还没有题目。', style: TextStyle(color: M.sub))),
              for (final q in all)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Glass(
                    padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
                    onTap: () => set(() => picked.contains(q.id) ? picked.remove(q.id) : picked.add(q.id)),
                    child: Row(children: [
                      Checkbox(
                          value: picked.contains(q.id),
                          activeColor: M.sageDark,
                          onChanged: (v) => set(() => v == true ? picked.add(q.id) : picked.remove(q.id))),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${q.type}题${q.kpId == n.kpId && n.kpId.isNotEmpty ? ' · 本知识点' : ''}', style: TextStyle(color: M.sub, fontSize: 11)),
                          MathText(q.stem, style: const TextStyle(fontSize: 13)),
                        ]),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: GlassButton(label: '确定（已选 ${picked.length} 道）', icon: Icons.check_rounded, tint: M.sage, expand: true, onTap: () => Navigator.pop(ctx, picked)),
            ),
          ),
        ]),
      ),
      initial: 0.8,
    );
    if (r == null) return;
    n.questionIds = [for (final q in all) if (r.contains(q.id)) q.id];
    await s.saveNote(n);
    await _load();
  }

  /// 引用原文：选一页，点选其中的段落。
  Future<void> _addQuote() async {
    final docList = docs.values.where((d) => d.parsedPages > 0 || d.status == '已解析').toList();
    if (docList.isEmpty) {
      toast(context, '还没有解析好的资料');
      return;
    }
    final doc = kp != null ? (docs[kp!.docId] ?? docList.first) : docList.first;
    final page = await promptPage(context, doc, kp?.page ?? 1);
    if (page == null || !mounted) return;
    final pt = await s.repo.page(doc.id, page);
    if (!mounted) return;
    if (pt == null || pt.text.trim().isEmpty) {
      toast(context, '第 $page 页没有解析出文字');
      return;
    }
    final paras = pt.text.split(RegExp(r'\n\s*\n|\n(?=\*\*|#|\d+[\.、])')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final picked = <int>{};
    final r = await showGlassSheet<List<String>>(
      context,
      (ctx, sc) => StatefulBuilder(
        builder: (ctx, set) => Column(children: [
          Expanded(
            child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 12), children: [
              Text('引用原文 · 第 $page 页', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('点选要引用的段落，会连同页码一起存进笔记。', style: TextStyle(color: M.sub, fontSize: 13)),
              for (var i = 0; i < paras.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Glass(
                    tint: picked.contains(i) ? M.sage : null,
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    onTap: () => set(() => picked.contains(i) ? picked.remove(i) : picked.add(i)),
                    child: MathText(paras[i], style: TextStyle(fontSize: 13, height: 1.5, color: picked.contains(i) ? Colors.white : M.text)),
                  ),
                ),
            ]),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: GlassButton(
                  label: picked.isEmpty ? '选择段落' : '引用 ${picked.length} 段',
                  icon: Icons.format_quote_rounded,
                  tint: M.sage,
                  expand: true,
                  onTap: picked.isEmpty ? null : () => Navigator.pop(ctx, [for (var i = 0; i < paras.length; i++) if (picked.contains(i)) paras[i]])),
            ),
          ),
        ]),
      ),
      initial: 0.8,
    );
    if (r == null || r.isEmpty) return;
    n.quotes = [...n.quotes, NoteQuote(docId: doc.id, page: page, text: r.join('\n\n'))];
    await s.saveNote(n);
    if (mounted) setState(() {});
  }

  Future<int?> promptPage(BuildContext context, PdfDoc d, int initial) async {
    final pages = await s.repo.pages(n.projectId, docId: d.id);
    if (pages.isEmpty || !context.mounted) return null;
    final lo = pages.first.page, hi = pages.last.page;
    return showDialog<int>(
      context: context,
      builder: (ctx) {
        final ctl = TextEditingController(text: '${initial.clamp(lo, hi)}');
        return AlertDialog(
          backgroundColor: M.sheet,
          title: const Text('引用哪一页'),
          content: TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: '《${d.name}》页码', helperText: '可选 $lo–$hi')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, (int.tryParse(ctl.text.trim()) ?? initial).clamp(lo, hi)), child: const Text('确定')),
          ],
        );
      },
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: M.sheet,
        title: const Text('删除笔记'),
        content: Text(n.photoIds.isEmpty ? '删除这条笔记？' : '删除这条笔记和其中的 ${n.photoIds.length} 张照片？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('删除', style: TextStyle(color: M.roseDark))),
        ],
      ),
    );
    if (ok != true) return;
    dirty = false;
    await s.deleteNoteEverywhere(n);
    if (mounted) Navigator.pop(context);
  }

  Widget _head(String t, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
        child: Row(children: [
          Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: M.text)),
          const Spacer(),
          ?trailing,
        ]),
      );

  Widget _addButton(String label, IconData icon, VoidCallback onTap) =>
      TextButton.icon(onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label), style: TextButton.styleFrom(foregroundColor: M.sageDark));

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, _) {
        if (dirty) _save();
        dirty = false;
      },
      child: GlassScaffold(
        title: '笔记',
        actions: [
          IconButton(
              tooltip: '导出 PDF',
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () async {
                await _save();
                if (context.mounted) await exportNotesPdf(context, n.title.isEmpty ? '笔记' : n.title, [n]);
              }),
          IconButton(tooltip: '删除', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
        ],
        body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 40), children: [
          TextField(
            controller: title,
            onChanged: (_) => dirty = true,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(hintText: '标题'),
          ),
          const SizedBox(height: 10),
          Glass(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            onTap: () async {
              final k = await pickKnowledgePoint(context, n.projectId);
              if (k == null) return;
              n
                ..kpId = k.id
                ..chapter = k.chapter;
              if (title.text.trim().isEmpty) title.text = k.title;
              await _save();
              await _load();
            },
            child: Row(children: [
              Icon(Icons.lightbulb_outline_rounded, size: 18, color: M.sageDark),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(kp == null ? '关联知识点' : '知识点${kp!.page > 0 ? ' · ${s.sourceLabel(kp!.docId, kp!.page, kp!.chapter, kp!.section)}' : ''}',
                      style: TextStyle(color: M.sub, fontSize: 12)),
                  if (kp != null) MathText(kp!.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (kp != null && kp!.content.isNotEmpty) MathText(kp!.content, style: TextStyle(fontSize: 13, color: M.sub, height: 1.5)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: M.sub),
            ]),
          ),
          _head('照片', trailing: _addButton('添加', Icons.add_a_photo_outlined, _photoMenu)),
          if (n.photoIds.isEmpty)
            Text('拍下课本、板书或手写推导，照片会压缩后保存。', style: TextStyle(color: M.sub, fontSize: 13))
          else
            Wrap(spacing: 8, runSpacing: 8, children: [for (final id in n.photoIds) PhotoThumb(id: id, onTap: () => _openPhoto(id))]),
          _head('我的理解'),
          Glass(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            child: TextField(
              controller: own,
              minLines: 4,
              maxLines: null,
              onChanged: (_) => setState(() => dirty = true),
              decoration: const InputDecoration(
                  hintText: r'用自己的话讲一遍，公式用 $...$', filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none),
            ),
          ),
          if (own.text.contains(r'$')) ...[
            const SizedBox(height: 8),
            Text('预览', style: TextStyle(color: M.sub, fontSize: 12)),
            const SizedBox(height: 4),
            MathText(own.text, style: const TextStyle(fontSize: 14, height: 1.6)),
          ],
          _head('AI 讲解',
              trailing: n.ai.isEmpty
                  ? null
                  : PopupMenuButton<String>(
                      icon: Icon(Icons.more_horiz_rounded, color: M.sub),
                      onSelected: (v) async {
                        if (v == 'regen') await _ai();
                        if (v == 'clear') {
                          n
                            ..ai = ''
                            ..aiSources = '';
                          await s.saveNote(n);
                          setState(() {});
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'regen', child: Text('重新生成')),
                        PopupMenuItem(value: 'clear', child: Text('清除')),
                      ],
                    )),
          if (aiBusy)
            Glass(child: AiRunView(run: aiRun, idle: aiIdleText(s)))
          else if (n.ai.isEmpty)
            GlassButton(label: '让 AI 讲解这个知识点', icon: Icons.auto_awesome_rounded, expand: true, onTap: _ai)
          else
            Glass(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MathText(n.ai, style: const TextStyle(fontSize: 14, height: 1.6)),
              WebSourcesView(WebSource.decode(n.aiSources)),
            ])),
          _head('相关题目', trailing: _addButton('选择', Icons.playlist_add_rounded, _addQuestions)),
          if (questions.isEmpty) Text('把这个知识点的典型题、错题挂在这里，复习时一起看。', style: TextStyle(color: M.sub, fontSize: 13)),
          for (final q in questions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${q.type}题', style: TextStyle(color: M.sub, fontSize: 11)),
                  MathText(q.stem, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  for (var i = 0; i < q.options.length; i++) MathText('${String.fromCharCode(65 + i)}. ${q.options[i]}', style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('答案：${q.answer}', style: TextStyle(color: M.sageDark, fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          _head('引用原文', trailing: _addButton('引用', Icons.format_quote_rounded, _addQuote)),
          if (n.quotes.isEmpty) Text('从已解析的教材里选几段原文，带页码保存，随时点开看上下文。', style: TextStyle(color: M.sub, fontSize: 13)),
          for (final (i, q) in n.quotes.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
                onTap: () => showSourceSheet(context, docId: q.docId, page: q.page),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.only(left: 10),
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(border: Border(left: BorderSide(color: M.sage, width: 3))),
                    child: MathText(q.text, style: TextStyle(fontSize: 13, height: 1.5, color: M.sub)),
                  ),
                  Row(children: [
                    Expanded(
                      child: Text('《${docs[q.docId]?.name ?? '资料'}》${s.sourceLabel(q.docId, q.page, '')}', style: TextStyle(color: M.sageDark, fontSize: 12)),
                    ),
                    IconButton(
                      tooltip: '移除',
                      icon: Icon(Icons.close_rounded, size: 18, color: M.sub),
                      onPressed: () async {
                        n.quotes = [...n.quotes]..removeAt(i);
                        await s.saveNote(n);
                        setState(() {});
                      },
                    ),
                  ]),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
