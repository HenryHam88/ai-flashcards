import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/pdf_tools.dart';
import '../services/pipeline.dart';
import '../services/settings.dart';
import '../theme/glass.dart';
import 'explain_sheet.dart';
import 'gen_sheet.dart';
import 'home_page.dart';
import 'quiz_page.dart';
import 'review_page.dart';
import 'wrong_book_page.dart';

class ProjectData {
  final Project project;
  final List<PdfDoc> docs;
  final List<Flashcard> cards;
  final List<Question> questions;
  final List<String> chapters;
  ProjectData(this.project, this.docs, this.cards, this.questions, this.chapters);
}

class ProjectPage extends StatefulWidget {
  final String projectId;
  final bool autoUpload;
  const ProjectPage({super.key, required this.projectId, this.autoUpload = false});
  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  String? progress;
  double frac = 0;
  bool busy = false;

  AppState get s => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    if (widget.autoUpload) WidgetsBinding.instance.addPostFrameCallback((_) => _upload());
  }

  Future<ProjectData?> _load() async {
    final pr = await s.repo.project(widget.projectId);
    if (pr == null) return null;
    final chunks = await s.repo.chunks(pr.id);
    final chapters = <String>[];
    for (final c in chunks) {
      if (!chapters.contains(c.chapter)) chapters.add(c.chapter);
    }
    return ProjectData(pr, await s.repo.docs(pr.id), await s.repo.cards(projectId: pr.id),
        await s.repo.questions(projectId: pr.id), chapters);
  }

  void _progress(String m, double f) {
    if (mounted) setState(() => (progress = m, frac = f));
  }

  Future<void> _run(Future<void> Function() job) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    if (mounted) setState(() => (busy = false, progress = null));
    s.changed();
  }

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'docx', 'doc']);
    if (picked.isEmpty) return;
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'pdfs'));
    await dir.create(recursive: true);
    final added = <PdfDoc>[];
    for (final f in picked) {
      if (f.path == null) continue;
      final lower = f.name.toLowerCase();
      if (!['.pdf', '.docx', '.doc'].any(lower.endsWith)) continue;
      final type = PdfDoc.typeOf(f.name);
      final id = newId();
      final dest = p.join(dir.path, '$id.$type');
      await File(f.path!).copy(dest);
      var pages = 0;
      if (type == 'pdf') {
        try {
          pages = await PdfTools.pageCount(await File(dest).readAsBytes());
        } catch (_) {}
      }
      final d = PdfDoc(id: id, projectId: widget.projectId, name: p.basenameWithoutExtension(f.name), path: dest, pageCount: pages, type: type);
      await s.repo.saveDoc(d);
      added.add(d);
    }
    s.changed();
    if (added.isNotEmpty && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFFF4F1EC),
          title: const Text('现在解析？'),
          content: Text('已添加 ${added.length} 份资料。会排队依次解析（最多同时 ${AppState.parseConcurrency} 份），PDF 每批 ${s.settings.ocrBatchPages} 页，Word 整份交给解析模型；每份单独显示进度，失败可单独重试。'
              '${added.any((d) => d.isWord) && !Settings.supportsWord(s.settings.ocrProvider) ? '\n\n注意：${ParseService.wordUnsupported}。' : ''}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('稍后')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始解析')),
          ],
        ),
      );
      if (go == true) s.enqueueParse(added);
    }
  }

  Future<void> _generate(ProjectData d) async {
    final o = await showGenOptionsSheet(context, d.project, d.chapters);
    if (o == null) return;
    await _run(() async {
      final r = await (await s.generator()).generate(d.project.id, o, _progress);
      if (mounted) toast(context, '生成完成：${r.cards} 张闪卡，${r.questions} 道题（${r.kps} 个知识点）');
    });
  }

  Future<void> _menu(String v, Project pr) async {
    if (v == 'rename') {
      final n = await promptText(context, '重命名项目', initial: pr.name);
      if (n != null && n.trim().isNotEmpty) {
        pr.name = n.trim();
        await s.repo.saveProject(pr);
        s.changed();
      }
    } else if (v == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFFF4F1EC),
          title: const Text('删除项目？'),
          content: Text('「${pr.name}」里的资料、闪卡、题目和错题都会被删除，无法恢复。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: M.roseDark))),
          ],
        ),
      );
      if (ok == true) {
        for (final d in await s.repo.docs(pr.id)) {
          try {
            await File(d.path).delete();
          } catch (_) {}
        }
        await s.repo.deleteProject(pr.id);
        s.changed();
        if (mounted) Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    return FutureBuilder<ProjectData?>(
      key: ValueKey(st.version),
      future: _load(),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const GlassScaffold(title: '', body: SizedBox());
        return DefaultTabController(
          length: 4,
          child: GlassScaffold(
            title: d.project.name,
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) => _menu(v, d.project),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'delete', child: Text('删除项目')),
                ],
              ),
            ],
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(children: [
                  Expanded(child: GlassButton(label: '生成', icon: Icons.auto_awesome_rounded, tint: M.sage, onTap: busy ? null : () => _generate(d))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: GlassButton(
                          label: '复习',
                          icon: Icons.style_outlined,
                          onTap: d.cards.isEmpty
                              ? null
                              : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReviewPage(projectId: d.project.id))))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: GlassButton(
                          label: '测验',
                          icon: Icons.quiz_outlined,
                          onTap: d.questions.isEmpty
                              ? null
                              : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuizPage(projectId: d.project.id))))),
                ]),
              ),
              if (progress != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Glass(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(progress!, style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: frac, color: M.sage, backgroundColor: Colors.white54),
                    ]),
                  ),
                ),
              const TabBar(
                labelColor: M.sageDark,
                unselectedLabelColor: M.sub,
                indicatorColor: M.sage,
                dividerColor: Colors.transparent,
                tabs: [Tab(text: '资料'), Tab(text: '闪卡'), Tab(text: '题目'), Tab(text: '错题')],
              ),
              Expanded(
                child: TabBarView(children: [
                  _docsTab(d),
                  _byChapter(d.cards, (c) => c.chapter, (c) => c.section, _cardTile),
                  _byChapter(d.questions, (q) => q.chapter, (q) => q.section, _questionTile, quiz: (ch) => QuizPage(projectId: d.project.id, chapter: ch)),
                  WrongList(projectId: d.project.id),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _docsTab(ProjectData d) => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
        Glass(
          onTap: busy ? null : _upload,
          child: const Row(children: [
            Icon(Icons.cloud_upload_outlined),
            SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('上传 PDF / Word', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                Text('支持 PDF 和 Word（.docx / .doc），可一次选择多个（在文件选择器里长按可多选）', style: TextStyle(color: M.sub, fontSize: 12)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        ValueListenableBuilder<Map<String, ParseJob>>(
          valueListenable: s.jobs,
          builder: (context, jobs, _) {
            final mine = jobs.values.where((j) => j.doc.projectId == d.project.id).toList();
            if (mine.isEmpty) return const SizedBox();
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('解析队列（${mine.where((j) => j.active).length} 份进行中）', style: const TextStyle(fontWeight: FontWeight.w700)),
                  for (final j in mine) _jobRow(j),
                ]),
              ),
            );
          },
        ),
        for (final doc in d.docs)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Glass(
              padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
              child: Row(children: [
                doc.isWord
                    ? const Icon(Icons.description_outlined, color: Color(0xFF6F8296)) // Word：灰蓝
                    : const Icon(Icons.picture_as_pdf_outlined, color: M.roseDark),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(doc.name, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                        doc.isWord
                            ? 'Word · ${doc.status}${doc.pageCount > 0 ? ' · ${doc.pageCount} 个小节' : ''}'
                            : '${doc.status} · 已解析 ${doc.parsedPages}/${doc.pageCount} 页',
                        style: const TextStyle(color: M.sub, fontSize: 12)),
                    if (doc.note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(doc.note, style: const TextStyle(color: M.roseDark, fontSize: 12, height: 1.4)),
                      ),
                  ]),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'parse') {
                      s.enqueueParse([doc]);
                    } else if (v == 'delete') {
                      await s.repo.deleteDoc(doc);
                      s.changed();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'parse',
                        child: Text(doc.isWord
                            ? (doc.status == '已解析' ? '重新解析' : '解析')
                            : (doc.parsedPages >= doc.pageCount && doc.pageCount > 0 ? '重新切分章节' : '解析（继续未完成的页）'))),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ]),
            ),
          ),
        if (d.chapters.isNotEmpty) ...[
          const SectionTitle('识别到的章节'),
          Glass(child: Text(d.chapters.join('\n'), style: const TextStyle(height: 1.8))),
        ],
      ]);

  Widget _jobRow(ParseJob j) {
    final bad = j.state == '失败' || j.state == '部分失败';
    final color = bad ? M.roseDark : (j.state == '完成' ? M.sageDark : M.sub);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(j.doc.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              Text(j.state, style: TextStyle(fontSize: 12, color: color)),
            ]),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: j.state == '排队中' ? 0 : j.frac, minHeight: 4, color: bad ? M.rose : M.sage, backgroundColor: Colors.white54),
            const SizedBox(height: 2),
            Text(j.message, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: color)),
          ]),
        ),
        if (bad)
          IconButton(tooltip: '重试', icon: const Icon(Icons.refresh_rounded, color: M.roseDark), onPressed: () => s.enqueueParse([j.doc])),
        if (!j.active)
          IconButton(tooltip: '移除', icon: const Icon(Icons.close_rounded, size: 18, color: M.sub), onPressed: () => s.dismissJob(j.doc.id)),
      ]),
    );
  }

  Widget _byChapter<T>(List<T> items, String Function(T) chapter, String Function(T) section, Widget Function(T) tile,
      {Widget Function(String chapter)? quiz}) {
    if (items.isEmpty) {
      return const Padding(
          padding: EdgeInsets.all(24), child: Text('还没有内容。上传并解析 PDF 或 Word 后点「生成」。', style: TextStyle(color: M.sub)));
    }
    final groups = <String, List<T>>{};
    for (final i in items) {
      groups.putIfAbsent(chapter(i).isEmpty ? '未分章' : chapter(i), () => []).add(i);
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
      for (final e in groups.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Glass(
            padding: EdgeInsets.zero,
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${e.value.length} 项', style: const TextStyle(color: M.sub, fontSize: 12)),
                trailing: quiz == null
                    ? null
                    : TextButton(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => quiz(e.key))),
                        child: const Text('做本章')),
                children: [for (final i in e.value) tile(i)],
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _cardTile(Flashcard c) => ListTile(
        title: MathText(c.front, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: MathText(c.back, style: const TextStyle(fontSize: 13, color: M.sub)),
        trailing: c.page > 0
            ? TextButton(
                onPressed: () => showSourceSheet(context, docId: c.docId, page: c.page, chapter: c.chapter, section: c.section),
                child: Text(s.repo.isWordDoc(c.docId) ? '原文' : 'P${c.page}'))
            : null,
      );

  Widget _questionTile(Question q) => ListTile(
        leading: Text(q.type, style: const TextStyle(color: M.sageDark, fontSize: 12)),
        title: MathText(q.stem, style: const TextStyle(fontSize: 14)),
        trailing: q.page > 0
            ? TextButton(
                onPressed: () => showSourceSheet(context, docId: q.docId, page: q.page, chapter: q.chapter, section: q.section),
                child: Text(s.repo.isWordDoc(q.docId) ? '原文' : 'P${q.page}'))
            : null,
      );
}
