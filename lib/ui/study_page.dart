import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/attachments.dart';
import '../services/llm.dart';
import '../services/study.dart';
import '../theme/glass.dart';
import 'ai_widgets.dart';
import 'chapter_reparse.dart' show showChapterKps;
import 'mindmap_view.dart';
import 'notes_page.dart' show openNoteFor, pickKnowledgePoint;
import 'number_input.dart';
import 'settings_pages.dart' show fmtSize;

String charsLabel(int n) => n >= 10000 ? '约 ${(n / 10000).toStringAsFixed(1)} 万字' : '约 $n 字';

/// 学习板块：用这个项目已经解析好的资料学懂概念。每章可以按需生成思维导图，底部是可收起的 AI 伴学。
class StudyPage extends StatefulWidget {
  final String projectId;
  const StudyPage({super.key, required this.projectId});
  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> {
  List<StudyChapter>? chapters;
  final generating = <String>{};
  StudyChat? chat;
  List<MaterialRef> scope = [];
  String scopeText = '';

  @override
  void initState() {
    super.initState();
    _load(first: true);
  }

  Future<void> _load({bool first = false}) async {
    final s = context.read<AppState>();
    final l = await s.study.chapters(widget.projectId);
    if (first) {
      final chats = await s.repo.studyChats(widget.projectId);
      chat = chats.firstOrNull;
      scope = chat?.scope ?? [];
    }
    final label = scope.isEmpty ? '' : await s.study.scopeLabel(widget.projectId, scope);
    if (mounted) setState(() => (chapters = l, scopeText = label));
  }

  String _key(StudyChapter c) => ChapterMindMap.idFor(c.doc.id, c.title);

  Future<void> _generate(StudyChapter c) async {
    final s = context.read<AppState>();
    setState(() => generating.add(_key(c)));
    try {
      final m = await s.generateMindMap(c);
      await _load();
      if (mounted) _openMap(m);
    } catch (e) {
      if (mounted) toast(context, '生成失败：$e');
    }
    if (mounted) setState(() => generating.remove(_key(c)));
  }

  Future<void> _openMap(ChapterMindMap m) async {
    final c = chapters?.where((e) => _key(e) == m.id).firstOrNull;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MindMapPage(
            map: m,
            onAsk: (q) {
              if (c != null) _openChat(scopeOverride: [c.ref], ask: q);
            })));
    _load();
  }

  Future<void> _openChat({List<MaterialRef>? scopeOverride, String? ask}) async {
    if (scopeOverride != null) {
      final same = scope.length == scopeOverride.length &&
          [for (var i = 0; i < scope.length; i++) scope[i].docId == scopeOverride[i].docId && scope[i].chapter == scopeOverride[i].chapter].every((e) => e);
      // 换了资料范围就开一个新对话，旧对话保留在「历史对话」里
      if (!same && (chat?.messages.isNotEmpty ?? false)) chat = null;
      scope = scopeOverride;
      chat?.scope = scopeOverride;
      await _load();
    }
    if (!mounted) return;
    await showGlassSheet(
      context,
      (ctx, sc) => StudyChatSheet(
        projectId: widget.projectId,
        chapters: chapters ?? [],
        chat: chat,
        scope: scope,
        ask: ask,
        controller: sc,
        onChanged: (c, sco) {
          chat = c;
          scope = sco;
        },
      ),
      initial: 0.88,
    );
    _load();
  }

  Widget _chapterCard(StudyChapter c) {
    final s = context.read<AppState>();
    final busy = generating.contains(_key(c));
    final unit = c.doc.isSectioned ? '节' : '页';
    final meta = [
      c.range.end > c.range.start ? '第 ${c.range.start}–${c.range.end} $unit' : '第 ${c.range.start} $unit',
      if (c.kpCount > 0) '${c.kpCount} 个知识点',
      charsLabel(c.chars),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Glass(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(c.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            if (c.map != null) ...[
              Icon(Icons.account_tree_outlined, size: 16, color: M.sageDark),
              const SizedBox(width: 4),
              Text('${c.map!.root.count - 1} 个节点', style: TextStyle(color: M.sageDark, fontSize: 12)),
            ],
          ]),
          const SizedBox(height: 2),
          Text(meta, style: TextStyle(color: M.sub, fontSize: 12)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: c.map != null
                  ? GlassButton(label: '查看导图', icon: Icons.account_tree_outlined, tint: M.sage, expand: true, onTap: () => _openMap(c.map!))
                  : GlassButton(
                      label: busy ? '正在生成…' : '生成思维导图',
                      icon: Icons.auto_awesome_outlined,
                      tint: M.sage,
                      expand: true,
                      onTap: busy ? null : () => _generate(c)),
            ),
            const SizedBox(width: 8),
            GlassButton(label: '问 AI', icon: Icons.forum_outlined, onTap: () => _openChat(scopeOverride: [c.ref])),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: M.sub),
              onSelected: (v) async {
                if (v == 'kps') await showChapterKps(context, c.doc, c.range);
                if (v == 'draw') {
                  final m = emptyMindMap(c);
                  await s.repo.saveMindMap(m);
                  await _load();
                  if (mounted) _openMap(m);
                }
                if (v == 'regen' && mounted) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: M.sheet,
                      title: const Text('重新生成导图'),
                      content: Text(c.map?.edited == true ? '会覆盖你手动修改过的导图，确定吗？' : '用 AI 重新整理这一章的导图？'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重新生成')),
                      ],
                    ),
                  );
                  if (ok == true) await _generate(c);
                }
                if (v == 'delete') {
                  await s.repo.deleteMindMap(c.map!.id);
                  await _load();
                }
                _load();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'kps', child: Text('查看知识点')),
                if (c.map == null) const PopupMenuItem(value: 'draw', child: Text('自己画导图')),
                if (c.map != null) const PopupMenuItem(value: 'regen', child: Text('重新生成导图')),
                if (c.map != null) const PopupMenuItem(value: 'delete', child: Text('删除导图')),
              ],
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _chatBar() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Glass(
            radius: 22,
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            onTap: () => _openChat(),
            child: Row(children: [
              Icon(Icons.auto_awesome_rounded, color: M.sageDark, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(chat?.messages.isNotEmpty == true ? 'AI 伴学 · ${chat!.title}' : 'AI 伴学',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(scope.isEmpty ? '选好章节或页码，让 AI 结合教材原文讲' : '已选：$scopeText',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: M.sub, fontSize: 12)),
                ]),
              ),
              Icon(Icons.keyboard_arrow_up_rounded, color: M.sub),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l = chapters;
    final docs = <String>{for (final c in l ?? <StudyChapter>[]) c.doc.id};
    return GlassScaffold(
      title: '学习板块',
      body: Column(children: [
        Expanded(
          child: l == null
              ? const SizedBox()
              : ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 16), children: [
                  Text('闪卡和题目是检验记忆的；这里用已经解析好的教材把概念真正学懂。每章可以单独生成思维导图，不会自动生成。',
                      style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
                  const SizedBox(height: 10),
                  if (l.isEmpty)
                    Glass(
                      child: Text('还没有解析好的资料。先在项目页「资料」里上传 PDF 并解析，解析好以后这里的每一章都可以生成思维导图、和 AI 一起学习。',
                          style: TextStyle(color: M.sub, height: 1.5)),
                    ),
                  for (var i = 0; i < l.length; i++) ...[
                    if (docs.length > 1 && (i == 0 || l[i - 1].doc.id != l[i].doc.id)) SectionTitle(l[i].doc.name),
                    _chapterCard(l[i]),
                  ],
                ]),
        ),
        _chatBar(),
      ]),
    );
  }
}

/// AI 伴学面板：选资料范围、快捷提问、对话（自动保存，可切换历史对话）。
class StudyChatSheet extends StatefulWidget {
  final String projectId;
  final List<StudyChapter> chapters;
  final StudyChat? chat;
  final List<MaterialRef> scope;
  final String? ask;
  final ScrollController? controller;
  final void Function(StudyChat? chat, List<MaterialRef> scope) onChanged;
  const StudyChatSheet(
      {super.key, required this.projectId, required this.chapters, this.chat, required this.scope, this.ask, this.controller, required this.onChanged});
  @override
  State<StudyChatSheet> createState() => _StudyChatSheetState();
}

class _StudyChatSheetState extends State<StudyChatSheet> {
  late StudyChat? chat = widget.chat;
  late List<MaterialRef> scope = widget.scope;
  final input = TextEditingController();
  bool busy = false;
  String? pending; // 正在等回答的问题
  StudyMaterial? material;
  String scopeText = '';
  final run = AiRun();
  // 还没有对话时选的联网方式（建对话时带上）
  bool? webOn;
  String? webMode;
  String? attachStatus; // 正在读取附件时的提示

  StudyChat _ensureChat() {
    final c = chat ?? StudyChat(id: newId(), projectId: widget.projectId, scope: scope, web: webOn, webMode: webMode);
    if (chat == null) setState(() => chat = c);
    return c;
  }

  Future<void> _addBytes(String name, Uint8List bytes) async {
    final s = context.read<AppState>();
    final c = _ensureChat();
    setState(() => attachStatus = '正在读取「$name」…');
    try {
      await s.addChatAttachment(c, name, bytes, onStatus: (st) {
        if (mounted) setState(() => attachStatus = st);
      });
      _notify();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    if (mounted) setState(() => attachStatus = null);
  }

  Future<void> _pickFiles() async {
    final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: [...AttachmentService.docExts, ...AttachmentService.imageExts]);
    if (r.isEmpty || !mounted) return;
    for (final f in r) {
      if (f.path == null) continue;
      final file = File(f.path!);
      final err = AttachmentService.check(f.name, await file.length(), (chat?.attachments.length ?? 0));
      if (!mounted) return;
      if (err != null) {
        toast(context, err);
        continue;
      }
      await _addBytes(f.name, await file.readAsBytes());
      if (!mounted) return;
    }
  }

  Future<void> _pickImage(ImageSource src) async {
    try {
      // 和笔记照片一样压缩：长边不超过 1600，JPEG 质量 80
      final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
      if (x == null || !mounted) return;
      final name = x.name.contains('.') ? x.name : '${x.name}.jpg';
      await _addBytes(name, await x.readAsBytes());
    } catch (e) {
      if (mounted) toast(context, '添加图片失败：$e');
    }
  }

  void _attachMenu() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: M.sheet,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('选择文件'),
                subtitle: Text('PDF、Word、TXT 或图片，单个不超过 ${AttachmentService.maxBytes ~/ 1024 ~/ 1024} MB'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickFiles();
                }),
            ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('拍照'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                }),
            ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                }),
            const SizedBox(height: 8),
          ]),
        ),
      );

  Widget _attachments() {
    final l = chat?.attachments ?? const <ChatAttachment>[];
    if (l.isEmpty && attachStatus == null) return const SizedBox();
    final s = context.read<AppState>();
    final docs = [for (final a in l.where((a) => !a.isImage)) (name: a.name, text: a.text, truncated: a.truncated)];
    final (_, cut) = AttachmentService.promptBlock(docs);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final a in l)
            Glass(
              radius: 12,
              padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                    switch (a.kind) {
                      'image' => Icons.image_outlined,
                      'pdf' => Icons.picture_as_pdf_outlined,
                      _ => Icons.description_outlined,
                    },
                    size: 14,
                    color: M.sageDark),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 4),
                Text(a.isImage ? fmtSize(a.size) : charsLabel(a.chars), style: TextStyle(color: M.sub, fontSize: 11)),
                InkWell(
                  onTap: busy
                      ? null
                      : () async {
                          await s.removeChatAttachment(chat!, a.id);
                          if (mounted) setState(() {});
                          _notify();
                        },
                  child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.close_rounded, size: 14, color: M.sub)),
                ),
              ]),
            ),
        ]),
        if (attachStatus != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: M.sage)),
              const SizedBox(width: 8),
              Expanded(child: Text(attachStatus!, style: TextStyle(color: M.sub, fontSize: 12))),
            ]),
          )
        else if (cut)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('附件文字较多，每次只发送前 ${AttachmentService.textBudget} 字，后面的内容 AI 看不到。可以删掉不需要的附件或拆开发。',
                style: TextStyle(color: M.roseDark, fontSize: 12, height: 1.4)),
          ),
      ]),
    );
  }

  @override
  void dispose() {
    run.dispose();
    input.dispose();
    super.dispose();
  }

  static const quick = ['通俗讲讲这部分的核心脉络', '推导一下关键公式', '举个典型例题并讲解', '有哪些容易混淆的概念？'];

  @override
  void initState() {
    super.initState();
    _measure();
    if (widget.ask != null) WidgetsBinding.instance.addPostFrameCallback((_) => _send(widget.ask!));
  }

  Future<void> _measure() async {
    final s = context.read<AppState>();
    final m = await s.study.material(widget.projectId, scope);
    final label = await s.study.scopeLabel(widget.projectId, scope);
    if (mounted) setState(() => (material = m, scopeText = label));
  }

  void _notify() => widget.onChanged(chat, scope);

  Future<void> _send(String q) async {
    q = q.trim();
    if (q.isEmpty || busy) return;
    final s = context.read<AppState>();
    final c = _ensureChat();
    c.scope = scope;
    setState(() => (busy = true, pending = q));
    input.clear();
    try {
      final r = await s.studyAsk(c, q, io: run.start());
      if (mounted) setState(() => chat = r);
    } on LlmCancelled {
      if (mounted) toast(context, '已停止');
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    run.finish();
    _notify();
    if (mounted) setState(() => (busy = false, pending = null));
  }

  Future<void> _pickScope() async {
    final r = await showGlassSheet<List<MaterialRef>>(context, (ctx, sc) => MaterialPickerSheet(chapters: widget.chapters, initial: scope, controller: sc),
        initial: 0.75);
    if (r == null || !mounted) return;
    setState(() => scope = r);
    chat?.scope = r;
    if (chat != null && chat!.messages.isNotEmpty) await context.read<AppState>().repo.saveStudyChat(chat!);
    _notify();
    _measure();
  }

  Future<void> _history() async {
    final s = context.read<AppState>();
    final chats = await s.repo.studyChats(widget.projectId);
    if (!mounted) return;
    final picked = await showGlassSheet<StudyChat>(
      context,
      (ctx, sc) => StatefulBuilder(
        builder: (ctx, setSheet) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
          const Text('历史对话', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          if (chats.isEmpty) Text('还没有对话。', style: TextStyle(color: M.sub)),
          for (final c in chats)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                onTap: () => Navigator.pop(ctx, c),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.title.isEmpty ? '新对话' : c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${c.messages.length ~/ 2} 轮 · ${c.updatedAt.month}月${c.updatedAt.day}日', style: TextStyle(color: M.sub, fontSize: 12)),
                    ]),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline_rounded, color: M.sub, size: 20),
                    onPressed: () async {
                      await s.deleteStudyChat(c);
                      setSheet(() => chats.remove(c));
                      if (chat?.id == c.id) {
                        setState(() => chat = null);
                        _notify();
                      }
                    },
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => (chat = picked, scope = picked.scope));
    _notify();
    _measure();
  }

  @override
  Widget build(BuildContext context) {
    final msgs = chat?.messages ?? [];
    final m = material;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
        child: Row(children: [
          Icon(Icons.auto_awesome_rounded, color: M.sageDark, size: 20),
          const SizedBox(width: 8),
          const Text('AI 伴学', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          WebModeChip(
            state: context.read<AppState>(),
            on: chat?.web ?? webOn,
            mode: chat?.webMode ?? webMode,
            enabled: !busy,
            onChanged: (v) async {
              setState(() {
                webOn = v.on;
                webMode = v.mode;
                chat?.web = v.on;
                chat?.webMode = v.mode;
              });
              if (chat != null && chat!.messages.isNotEmpty) await context.read<AppState>().repo.saveStudyChat(chat!);
            },
          ),
          const Spacer(),
          IconButton(tooltip: '历史对话', onPressed: busy ? null : _history, icon: Icon(Icons.history_rounded, color: M.sub)),
          IconButton(
              tooltip: '新对话',
              onPressed: busy
                  ? null
                  : () {
                      setState(() => chat = null);
                      _notify();
                    },
              icon: Icon(Icons.add_comment_outlined, color: M.sub)),
          IconButton(tooltip: '收起', onPressed: () => Navigator.pop(context), icon: Icon(Icons.keyboard_arrow_down_rounded, color: M.sub)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Glass(
          radius: 14,
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
          onTap: busy ? null : _pickScope,
          child: Row(children: [
            Icon(Icons.menu_book_outlined, size: 16, color: M.sageDark),
            const SizedBox(width: 8),
            Expanded(
              child: Text(scope.isEmpty ? '选择资料范围（章节或页码）' : scopeText,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            if (m != null && scope.isNotEmpty) Text(charsLabel(m.chars), style: TextStyle(color: M.sub, fontSize: 12)),
            const SizedBox(width: 4),
            Icon(Icons.edit_outlined, size: 16, color: M.sub),
          ]),
        ),
      ),
      if (m != null && m.truncated)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
          child: Text(
              '所选范围共${charsLabel(m.chars)}，超过上限，AI 只能看到前 ${m.used} 字（约 ${m.percent}%，到第 ${m.lastPage} ${m.unit}为止）。'
              '后面的内容它看不到，建议在上面缩小到具体章节或页码。',
              style: TextStyle(color: M.roseDark, fontSize: 12, height: 1.4)),
        ),
      _attachments(),
      Expanded(
        child: ListView(controller: widget.controller, padding: const EdgeInsets.symmetric(horizontal: 20), children: [
          if (msgs.isEmpty && pending == null) ...[
            const SizedBox(height: 6),
            Text(scope.isEmpty ? '先选好要学的章节或页码，AI 会以这部分教材原文为依据讲解。' : '可以直接问，也可以点下面的问题开始：',
                style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final q in quick)
                Glass(
                  radius: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  onTap: busy ? null : () => _send(q),
                  child: Text(q, style: const TextStyle(fontSize: 13)),
                ),
            ]),
          ],
          for (final x in msgs)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: x['role'] == 'user'
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: Glass(
                          tint: M.greyBlue,
                          radius: 16,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Text(x['content']!, style: const TextStyle(color: Colors.white))))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      MathText(stripMetaPreamble(x['content']!), style: const TextStyle(fontSize: 15, height: 1.6)),
                      WebSourcesView(sourcesOf(x)),
                      Row(children: [
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: x['content']!));
                            toast(context, '已复制');
                          },
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('复制'),
                          style: TextButton.styleFrom(foregroundColor: M.sub),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final kp = await pickKnowledgePoint(context, widget.projectId);
                            if (kp == null || !context.mounted) return;
                            await openNoteFor(context,
                                projectId: widget.projectId, kpId: kp.id, title: kp.title, chapter: kp.chapter, ai: stripMetaPreamble(x['content']!));
                          },
                          icon: const Icon(Icons.edit_note_rounded, size: 18),
                          label: const Text('存为笔记'),
                          style: TextButton.styleFrom(foregroundColor: M.sageDark),
                        ),
                      ]),
                    ]),
            ),
          if (pending != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Align(
                  alignment: Alignment.centerRight,
                  child: Glass(
                      tint: M.greyBlue,
                      radius: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(pending!, style: const TextStyle(color: Colors.white)))),
            ),
          if (busy)
            Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AiRunView(run: run, idle: aiIdleText(context.read<AppState>(), web: chatWebMode(context.read<AppState>(), chat?.web, chat?.webMode)))),
          const SizedBox(height: 16),
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, 4, 16, 10 + MediaQuery.of(context).viewInsets.bottom),
          child: Row(children: [
            IconButton(
                tooltip: '添加附件',
                onPressed: busy || attachStatus != null ? null : _attachMenu,
                icon: Icon(Icons.attach_file_rounded, color: M.sub)),
            Expanded(
                child: TextField(
                    controller: input,
                    onSubmitted: _send,
                    decoration: const InputDecoration(hintText: '问问这部分内容，比如「为什么要这样定义」'))),
            const SizedBox(width: 8),
            IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: M.sage), onPressed: busy || attachStatus != null ? null : () => _send(input.text), icon: const Icon(Icons.send_rounded)),
          ]),
        ),
      ),
    ]);
  }
}

/// 选择资料范围：按章节多选，选中的章节可以再缩小到某几页。
class MaterialPickerSheet extends StatefulWidget {
  final List<StudyChapter> chapters;
  final List<MaterialRef> initial;
  final ScrollController? controller;
  const MaterialPickerSheet({super.key, required this.chapters, required this.initial, this.controller});
  @override
  State<MaterialPickerSheet> createState() => _MaterialPickerSheetState();
}

class _MaterialPickerSheetState extends State<MaterialPickerSheet> {
  late final picked = <String, MaterialRef>{for (final r in widget.initial) '${r.docId}|${r.chapter}': r};

  String _k(StudyChapter c) => '${c.doc.id}|${c.title}';

  int _estimate() {
    var n = 0;
    for (final c in widget.chapters) {
      final r = picked[_k(c)];
      if (r == null) continue;
      final total = (c.range.end - c.range.start + 1).clamp(1, 1 << 30);
      final sel = r.pageFrom > 0 ? (r.pageTo - r.pageFrom + 1).clamp(1, total) : total;
      n += c.chars * sel ~/ total;
    }
    return n;
  }

  Future<void> _pages(StudyChapter c) async {
    final r = picked[_k(c)] ?? c.ref;
    final from = await promptNumber(context, title: '从第几页', value: r.pageFrom, min: c.range.start, max: c.range.end, unit: '页');
    if (from == null || !mounted) return;
    final to = await promptNumber(context, title: '到第几页', value: r.pageTo < from ? from : r.pageTo, min: from, max: c.range.end, unit: '页');
    if (to == null) return;
    setState(() => picked[_k(c)] = MaterialRef(docId: c.doc.id, chapter: c.title, pageFrom: from, pageTo: to));
  }

  @override
  Widget build(BuildContext context) {
    final est = _estimate();
    final docs = <String>{for (final c in widget.chapters) c.doc.id};
    return Column(children: [
      Expanded(
        child: ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 12), children: [
          const Text('选择资料范围', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('AI 只看你选的这部分原文（直接用已解析的文字，不会重新解析）。勾选后点「页码」可以只选其中几页。',
              style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
          const SizedBox(height: 6),
          if (widget.chapters.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('还没有解析好的资料。', style: TextStyle(color: M.sub))),
          for (final (i, c) in widget.chapters.indexed) ...[
            if (docs.length > 1 && (i == 0 || widget.chapters[i - 1].doc.id != c.doc.id)) SectionTitle(c.doc.name),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
                onTap: () => setState(() => picked.containsKey(_k(c)) ? picked.remove(_k(c)) : picked[_k(c)] = c.ref),
                child: Row(children: [
                  Checkbox(
                      value: picked.containsKey(_k(c)),
                      activeColor: M.sageDark,
                      onChanged: (v) => setState(() => v == true ? picked[_k(c)] = c.ref : picked.remove(_k(c)))),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                          picked[_k(c)] != null && (picked[_k(c)]!.pageFrom != c.range.start || picked[_k(c)]!.pageTo != c.range.end)
                              ? '只选第 ${picked[_k(c)]!.pageFrom}–${picked[_k(c)]!.pageTo} 页'
                              : '第 ${c.range.start}–${c.range.end} 页 · ${charsLabel(c.chars)}',
                          style: TextStyle(color: M.sub, fontSize: 12)),
                    ]),
                  ),
                  if (picked.containsKey(_k(c)) && !c.doc.isSectioned)
                    TextButton(onPressed: () => _pages(c), style: TextButton.styleFrom(foregroundColor: M.sageDark), child: const Text('页码')),
                ]),
              ),
            ),
          ],
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Column(children: [
            if (picked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                    est > StudyService.budget ? '已选${charsLabel(est)}，超过 2.4 万字时只发送前一部分，建议缩小范围' : '已选${charsLabel(est)}，可以直接发给 AI',
                    style: TextStyle(color: est > StudyService.budget ? M.roseDark : M.sub, fontSize: 12)),
              ),
            GlassButton(
              label: picked.isEmpty ? '确定' : '确定（已选 ${picked.length} 项）',
              icon: Icons.check_rounded,
              tint: M.sage,
              expand: true,
              onTap: () => Navigator.pop(context, [
                for (final c in widget.chapters)
                  if (picked[_k(c)] != null) picked[_k(c)]!,
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}
