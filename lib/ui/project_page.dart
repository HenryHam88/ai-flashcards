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
import 'chapter_editor_page.dart';
import 'chapter_view_page.dart';
import 'settings_pages.dart' show showExportSheet;
import 'explain_sheet.dart';
import 'feedback_sheet.dart';
import 'auto_count_sheet.dart';
import 'gen_sheet.dart';
import 'help_page.dart' show errorToast;
import 'inbox_page.dart';
import 'home_page.dart';
import 'quiz_page.dart';
import 'review_page.dart';
import 'due_page.dart';
import '../services/study_queue.dart';
import 'wrong_book_page.dart';
import '../services/text_import.dart' show txtWarnBytes;

class ProjectData {
  final Project project;
  final List<PdfDoc> docs;
  final List<Flashcard> cards;
  final List<Question> questions;
  final List<String> chapters;
  final int inbox; // 待审核数量
  final StudyCounts? counts; // 新学 / 待复习
  ProjectData(this.project, this.docs, this.cards, this.questions, this.chapters, {this.inbox = 0, this.counts});
}

class ProjectPage extends StatefulWidget {
  final String projectId;
  final bool autoUpload;
  /// 打开后立即弹出生成面板并预填这些选项（统计页「针对这些出新题」）。
  final GenOptions? genPreset;
  const ProjectPage({super.key, required this.projectId, this.autoUpload = false, this.genPreset});
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
    if (widget.genPreset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final d = await _load();
        if (d != null && mounted) await _generate(d, preset: widget.genPreset);
      });
    }
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
        await s.repo.questions(projectId: pr.id), chapters,
        inbox: (await s.repo.inboxCards(projectId: pr.id)).length + (await s.repo.inboxQuestions(projectId: pr.id)).length,
        counts: await s.studyCounts(projectId: pr.id));
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
      if (mounted) errorToast(context, '$e');
    }
    if (mounted) setState(() => (busy = false, progress = null));
    s.changed();
  }

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'docx', 'doc', 'txt']);
    if (picked.isEmpty) return;
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'pdfs'));
    await dir.create(recursive: true);
    final added = <PdfDoc>[];
    final large = <String>[]; // 超过 10 MB 的 TXT
    for (final f in picked) {
      if (f.path == null) continue;
      final lower = f.name.toLowerCase();
      if (!['.pdf', '.docx', '.doc', '.txt'].any(lower.endsWith)) continue;
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
      if (type == 'txt' && await File(dest).length() > txtWarnBytes) large.add(f.name);
      final d = PdfDoc(id: id, projectId: widget.projectId, name: p.basenameWithoutExtension(f.name), path: dest, pageCount: pages, type: type);
      await s.repo.saveDoc(d);
      added.add(d);
    }
    s.changed();
    if (added.isNotEmpty && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: M.sheet,
          title: const Text('现在解析？'),
          content: Text('已添加 ${added.length} 份资料。会排队依次解析（最多同时 ${s.parseConcurrency} 份），PDF 每批 ${s.settings.ocrBatchPages} 页，Word 整份交给解析模型${added.any((d) => d.isText) ? '，TXT 在手机上直接读取（不联网、不花钱）' : ''}；每份单独显示进度，失败可单独重试。'
              '${added.any((d) => d.isWord) && !Settings.supportsWord(s.settings.ocrProvider) ? '\n\n注意：${ParseService.wordUnsupported}。' : ''}'
              '${large.isEmpty ? '' : '\n\n注意：${large.join('、')} 超过 10 MB，读取和出题会比较慢，建议只保留需要的章节。'}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('稍后')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('开始解析')),
          ],
        ),
      );
      if (go == true) s.enqueueParse(added);
    }
  }

  Future<void> _generate(ProjectData d, {GenOptions? preset}) async {
    final o = await showGenOptionsSheet(context, d.project, d.chapters, preset: preset);
    if (o == null) return;
    final GenerationService gen;
    try {
      gen = await s.generator(projectId: d.project.id);
    } catch (e) {
      if (mounted) errorToast(context, '$e');
      return;
    }
    List<KnowledgePoint>? planned;
    if (o.autoCount) {
      // 自动数量：先列出知识点并估算，用户确认后再生成；规划失败时改为手动设置数量
      GenPlan? plan;
      String? err;
      await _run(() async {
        try {
          plan = await gen.plan(d.project.id, o, _progress);
        } catch (e) {
          err = '$e';
        }
      });
      if (!mounted) return;
      final picked = plan != null
          ? await showAutoCountConfirm(context, plan!)
          : await showFixedCountFallback(context, err ?? '未知错误', o);
      if (picked == null) return;
      o
        ..cardCount = picked.$1
        ..questionCount = picked.$2;
      if (plan != null) {
        planned = plan!.kps;
      } else {
        o.autoCount = false;
      }
    }
    await _run(() async {
      final r = await gen.generate(d.project.id, o, _progress, planned: planned);
      if (!mounted) return;
      // 生成后横幅：可以马上审核这一批（开启「生成后先审核」时内容在待审核里）
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        backgroundColor: M.text.withValues(alpha: 0.92),
        content: Text(r.pending ? '${r.summary}，已放入待审核' : r.summary),
        action: r.cards + r.questions == 0
            ? null
            : SnackBarAction(
                label: '审核这批',
                textColor: M.sage,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => r.pending
                        ? InboxPage(projectId: d.project.id, summary: r.summary)
                        : InboxPage(
                            projectId: d.project.id, cardIds: r.cardIds, questionIds: r.questionIds, summary: r.summary))),
              ),
      ));
    });
  }

  Future<void> _menu(String v, Project pr) async {
    if (v == 'export') {
      await showExportSheet(context, projectId: pr.id, projectName: pr.name);
    } else if (v == 'rename') {
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
          backgroundColor: M.sheet,
          title: const Text('删除项目？'),
          content: Text('「${pr.name}」里的资料、闪卡、题目和错题都会被删除，无法恢复。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('删除', style: TextStyle(color: M.roseDark))),
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

  /// 新学 / 待复习 计数和「学新卡」「复习」「到期」入口（「学习」按钮 = 先复习后新卡）。
  Widget _countsRow(ProjectData d) {
    final c = d.counts!;
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    Widget link(String label, VoidCallback? onTap) => TextButton(
          style: TextButton.styleFrom(
              foregroundColor: M.sageDark,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
      child: Row(children: [
        Expanded(
          child: Text('新学 ${c.newAvailable} · 待复习 ${c.due} · ${c.newProgress}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: M.sub, fontSize: 12)),
        ),
        link('学新卡', c.newAvailable == 0 && !c.newLimitReached ? null : () => open(ReviewPage(projectId: d.project.id, mode: StudyMode.newOnly))),
        link('复习', c.due == 0 ? null : () => open(ReviewPage(projectId: d.project.id, mode: StudyMode.reviewOnly))),
        link('到期', () => open(DueByDayPage(projectId: d.project.id))),
      ]),
    );
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
                  PopupMenuItem(value: 'export', child: Text('导出 / 分享此项目')),
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
                          label: '学习',
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
              if (d.cards.isNotEmpty && d.counts != null) _countsRow(d),
              if (progress != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Glass(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(progress!, style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: frac, color: M.sage, backgroundColor: M.glass.withValues(alpha: 0.5)),
                    ]),
                  ),
                ),
              TabBar(
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
        if (d.inbox > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Glass(
              tint: M.oat.withValues(alpha: 0.9),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => InboxPage(projectId: d.project.id)))
                  .then((_) => s.changed()),
              child: Row(children: [
                const Icon(Icons.inbox_rounded, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                    child: Text('待审核 ${d.inbox} 条：确认后才会加入复习和测验',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ]),
            ),
          ),
        Glass(
          onTap: busy ? null : _upload,
          child: Row(children: [
            Icon(Icons.cloud_upload_outlined),
            SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('上传 PDF / Word / TXT', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                Text('支持 PDF、Word（.docx / .doc）和 TXT，可一次选择多个（在文件选择器里长按可多选）', style: TextStyle(color: M.sub, fontSize: 12)),
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
                    ? Icon(Icons.description_outlined, color: M.wordBlue) // Word：灰蓝
                    : doc.isText
                        ? Icon(Icons.article_outlined, color: M.sageDark) // TXT：灰绿
                        : Icon(Icons.picture_as_pdf_outlined, color: M.roseDark),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(doc.name, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                        doc.isSectioned
                            ? '${doc.isText ? 'TXT' : 'Word'} · ${doc.status}${doc.pageCount > 0 ? ' · ${doc.pageCount} 个小节' : ''}'
                            : '${doc.status} · 已解析 ${doc.parsedPages}/${doc.pageCount} 页',
                        style: TextStyle(color: M.sub, fontSize: 12)),
                    if (doc.note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(doc.note, style: TextStyle(color: M.roseDark, fontSize: 12, height: 1.4)),
                      ),
                  ]),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'parse') {
                      s.enqueueParse([doc]);
                    } else if (v == 'chapters' || v == 'view') {
                      // 章节编辑 / 章节内容里点了「用这章出题」时会带回预填好的生成选项
                      final r = await Navigator.push<GenOptions>(
                          context,
                          MaterialPageRoute(
                              builder: (_) => v == 'view' ? ChapterViewPage(doc: doc) : ChapterEditorPage(doc: doc)));
                      s.changed();
                      if (r != null && mounted) {
                        final nd = await _load();
                        if (nd != null && mounted) await _generate(nd, preset: r);
                      }
                    } else if (v == 'delete') {
                      await s.repo.deleteDoc(doc);
                      s.changed();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'parse',
                        child: Text(doc.isSectioned
                            ? (doc.status == '已解析' ? '重新解析' : '解析')
                            : (doc.parsedPages >= doc.pageCount && doc.pageCount > 0 ? '重新切分章节' : '解析（继续未完成的页）'))),
                    if (doc.parsedPages > 0) const PopupMenuItem(value: 'view', child: Text('查看章节内容')),
                    if (doc.parsedPages > 0) const PopupMenuItem(value: 'chapters', child: Text('编辑章节')),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ]),
            ),
          ),
        if (d.chapters.isNotEmpty) ...[
          const SectionTitle('章节'),
          Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.chapters.join('\n'), style: const TextStyle(height: 1.8)),
              const SizedBox(height: 4),
              Text('想看解析出的原文，在资料右侧菜单选「查看章节内容」；识别得不对，选「编辑章节」可以手动调整、按页数切分或让 AI 重新分章。',
                  style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
            ]),
          ),
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
            LinearProgressIndicator(value: j.state == '排队中' ? 0 : j.frac, minHeight: 4, color: bad ? M.rose : M.sage, backgroundColor: M.glass.withValues(alpha: 0.5)),
            const SizedBox(height: 2),
            Text(j.message, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: color)),
          ]),
        ),
        if (bad)
          IconButton(tooltip: '重试', icon: Icon(Icons.refresh_rounded, color: M.roseDark), onPressed: () => s.enqueueParse([j.doc])),
        if (!j.active)
          IconButton(tooltip: '移除', icon: Icon(Icons.close_rounded, size: 18, color: M.sub), onPressed: () => s.dismissJob(j.doc.id)),
      ]),
    );
  }

  Widget _byChapter<T>(List<T> items, String Function(T) chapter, String Function(T) section, Widget Function(T) tile,
      {Widget Function(String chapter)? quiz}) {
    if (items.isEmpty) {
      return Padding(
          padding: EdgeInsets.all(24), child: Text('还没有内容。上传并解析 PDF、Word 或 TXT 后点「生成」。', style: TextStyle(color: M.sub)));
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
                subtitle: Text('${e.value.length} 项', style: TextStyle(color: M.sub, fontSize: 12)),
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

  /// 长按卡片 / 题目：编辑、反馈、暂停或恢复。
  Future<void> _itemMenu(Object item) async {
    final c = item is Flashcard ? item : null, q = item is Question ? item : null;
    final suspended = c?.suspended ?? q!.suspended;
    final v = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: M.sheet,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('编辑'), onTap: () => Navigator.pop(ctx, 'edit')),
          ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text(c != null ? '这张有问题' : '这道题有问题'),
              onTap: () => Navigator.pop(ctx, 'flag')),
          ListTile(
              leading: Icon(suspended ? Icons.play_circle_outline_rounded : Icons.pause_circle_outline_rounded),
              title: Text(suspended ? '恢复（重新加入复习 / 测验）' : '暂停'),
              onTap: () => Navigator.pop(ctx, 'suspend')),
        ]),
      ),
    );
    if (!mounted || v == null) return;
    if (v == 'edit') {
      await showItemEditor(context, card: c, question: q, save: (it) async {
        if (it is Flashcard) await s.repo.saveCards([it]);
        if (it is Question) await s.repo.saveQuestions([it]);
      });
    } else if (v == 'flag') {
      await showFeedbackSheet(context, card: c, question: q);
    } else {
      if (c != null) await s.repo.saveCards([c..suspended = !suspended]);
      if (q != null) await s.repo.saveQuestions([q..suspended = !suspended]);
    }
    s.changed();
  }

  Widget _cardTile(Flashcard c) => ListTile(
        onLongPress: () => _itemMenu(c),
        enabled: true,
        title: Opacity(
          opacity: c.suspended ? 0.45 : 1,
          child: MathText(c.suspended ? '（已暂停）${c.front}' : c.front,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
        subtitle: Opacity(opacity: c.suspended ? 0.45 : 1, child: MathText(c.back, style: TextStyle(fontSize: 13, color: M.sub))),
        trailing: c.page > 0
            ? TextButton(
                onPressed: () => showSourceSheet(context, docId: c.docId, page: c.page, chapter: c.chapter, section: c.section),
                child: Text(s.repo.isWordDoc(c.docId) ? '原文' : s.repo.isTextDoc(c.docId) ? '第${c.page}节' : 'P${c.page}'))
            : null,
      );

  Widget _questionTile(Question q) => ListTile(
        onLongPress: () => _itemMenu(q),
        leading: Text(q.type, style: TextStyle(color: M.sageDark, fontSize: 12)),
        title: Opacity(
            opacity: q.suspended ? 0.45 : 1,
            child: MathText(q.suspended ? '（已暂停）${q.stem}' : q.stem, style: const TextStyle(fontSize: 14))),
        trailing: q.page > 0
            ? TextButton(
                onPressed: () => showSourceSheet(context, docId: q.docId, page: q.page, chapter: q.chapter, section: q.section),
                child: Text(s.repo.isWordDoc(q.docId) ? '原文' : s.repo.isTextDoc(q.docId) ? '第${q.page}节' : 'P${q.page}'))
            : null,
      );
}
