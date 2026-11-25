import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/kb_export.dart';
import '../theme/glass.dart';
import 'settings_pages.dart' show SettingsGroup, SwitchTile, fmtSize, saveOrShareFile;

/// 导出到 Obsidian / Notion：选内容和范围，打包成 Markdown 压缩包后保存或分享。
Future<void> showKbExportSheet(BuildContext context) =>
    showGlassSheet(context, (ctx, sc) => KbExportSheet(controller: sc), initial: 0.9);

class KbExportSheet extends StatefulWidget {
  final ScrollController? controller;
  const KbExportSheet({super.key, this.controller});
  @override
  State<KbExportSheet> createState() => _KbExportSheetState();
}

class _KbExportSheetState extends State<KbExportSheet> {
  bool notes = true, chats = true, explains = true, favorites = true, wrong = true, busy = false;
  String? projectId;
  List<(String, String)> projects = [];
  KbCounts? counts;
  String? error;

  @override
  void initState() {
    super.initState();
    () async {
      final s = context.read<AppState>();
      final ps = await s.repo.projects();
      if (mounted) setState(() => projects = [for (final p in ps) (p.id, p.name)]);
      await _count();
    }();
  }

  Future<void> _count() async {
    final c = await context.read<AppState>().kbExporter().counts(projectId: projectId);
    if (mounted) setState(() => counts = c);
  }

  KbExportOptions get _options =>
      KbExportOptions(notes: notes, studyChats: chats, explains: explains, favorites: favorites, wrong: wrong, projectId: projectId);

  int get _total {
    final c = counts;
    if (c == null) return 0;
    return (notes ? c.notes : 0) + (chats ? c.studyChats : 0) + (explains ? c.explains : 0) + (favorites ? c.favorites : 0) + (wrong ? c.wrong : 0);
  }

  Future<void> _go() async {
    setState(() => (busy = true, error = null));
    try {
      final r = await context.read<AppState>().kbExporter().export(_options);
      if (!mounted) return;
      // 面板关掉后它自己的 context 就失效了，后面的「保存 / 分享」改用一直存在的导航器
      final outer = Navigator.of(context).context;
      Navigator.pop(context);
      if (!outer.mounted) return;
      final skipped = r.missingFiles > 0 ? '\n有 ${r.missingFiles} 个照片或附件不在本机，已跳过' : '';
      await saveOrShareFile(outer, r.bytes, r.fileName, title: '压缩包已生成（${fmtSize(r.bytes.length)}）$skipped', mimeType: 'application/zip');
    } catch (e) {
      if (mounted) setState(() => (busy = false, error = '导出失败：$e'));
    }
  }

  String _n(int? v) => counts == null ? '计算中…' : '$v 条';

  @override
  Widget build(BuildContext context) {
    final c = counts;
    Widget pad(Widget w) => Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: w);
    void toggle(void Function() f) {
      if (busy) return;
      setState(f);
    }

    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(0, 8, 0, 30), children: [
      pad(const Text('导出到 Obsidian / Notion', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
      const SizedBox(height: 6),
      pad(Text('打包成一个压缩包，每条内容一个 Markdown 文件，按「类型 / 项目」分文件夹；公式、照片和附件都会带上。里面有一份「使用说明」，写了怎么导入。',
          style: TextStyle(color: M.sub, fontSize: 13, height: 1.5))),
      const SizedBox(height: 14),
      pad(Text('范围', style: TextStyle(color: M.sub, fontSize: 13))),
      const SizedBox(height: 4),
      ProjectFilterChips(
        projects: projects,
        value: projectId,
        onChanged: (v) {
          if (busy) return;
          setState(() => (projectId = v, counts = null));
          _count();
        },
      ),
      const SizedBox(height: 4),
      pad(SettingsGroup(title: '导出哪些内容', children: [
        SwitchTile(
            icon: Icons.edit_note_rounded,
            title: '笔记',
            subtitle: _n(c?.notes),
            value: notes,
            onChanged: (v) => toggle(() => notes = v)),
        SwitchTile(
            icon: Icons.forum_outlined,
            title: 'AI 伴学',
            subtitle: _n(c?.studyChats),
            value: chats,
            onChanged: (v) => toggle(() => chats = v)),
        SwitchTile(
            icon: Icons.history_edu_rounded,
            title: 'AI 解释',
            subtitle: _n(c?.explains),
            value: explains,
            onChanged: (v) => toggle(() => explains = v)),
        SwitchTile(
            icon: Icons.star_outline_rounded,
            title: '收藏',
            subtitle: _n(c?.favorites),
            value: favorites,
            onChanged: (v) => toggle(() => favorites = v)),
        SwitchTile(
            icon: Icons.bookmark_border_rounded,
            title: '错题',
            subtitle: c == null ? '计算中…' : '${c.wrong} 条 · 另附表格，可导入 Notion 数据库',
            value: wrong,
            onChanged: (v) => toggle(() => wrong = v)),
      ])),
      if (error != null) ...[
        const SizedBox(height: 10),
        pad(Text(error!, style: TextStyle(color: M.roseDark, fontSize: 13))),
      ],
      if (busy) ...[
        const SizedBox(height: 12),
        pad(const Text('正在打包…', style: TextStyle(fontSize: 13))),
        const SizedBox(height: 6),
        pad(LinearProgressIndicator(color: M.sage, backgroundColor: M.glass.withValues(alpha: 0.5))),
      ],
      const SizedBox(height: 14),
      pad(GlassButton(
        label: busy ? '正在打包…' : (c != null && _total == 0 ? '没有可导出的内容' : '导出'),
        icon: Icons.upload_file_rounded,
        tint: M.sage,
        expand: true,
        onTap: busy || c == null || _total == 0 || !_options.any ? null : _go,
      )),
      const SizedBox(height: 10),
      pad(Text('Obsidian：解压后放进笔记库。Notion：电脑上「设置 → 导入」选这个压缩包。',
          textAlign: TextAlign.center, style: TextStyle(color: M.sub, fontSize: 12, height: 1.5))),
    ]);
  }
}
