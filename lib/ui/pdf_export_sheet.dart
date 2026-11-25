import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/pdf_export.dart';
import '../theme/glass.dart';
import 'settings_pages.dart' show SettingsGroup, SwitchTile, fmtSize, saveOrShareFile;

/// 导出错题 PDF：选择答案位置、是否包含解析和上次作答。
Future<void> showWrongExportSheet(BuildContext context, {required String title, required String projectId, required List<ExportItem> items}) =>
    showGlassSheet(context, (ctx, sc) => WrongExportSheet(title: title, projectId: projectId, items: items, controller: sc), initial: 0.62);

class WrongExportSheet extends StatefulWidget {
  final String title;
  final String projectId;
  final List<ExportItem> items;
  final ScrollController? controller;
  const WrongExportSheet({super.key, required this.title, required this.projectId, required this.items, this.controller});
  @override
  State<WrongExportSheet> createState() => _WrongExportSheetState();
}

class _WrongExportSheetState extends State<WrongExportSheet> {
  AnswerLayout layout = AnswerLayout.inline;
  bool explanation = true;
  bool lastAnswer = true;
  bool busy = false;
  String? error;

  Future<void> _go() async {
    final s = context.read<AppState>();
    setState(() => (busy = true, error = null));
    try {
      final svc = await s.pdfExporter();
      final miss = svc.missingGlyphs(PdfExportService.wrongTexts(widget.title, widget.items));
      if (!mounted) return;
      if (!await confirmMissingGlyphs(context, miss)) {
        if (mounted) setState(() => busy = false);
        return;
      }
      final bytes = await svc.wrongQuestions(
          widget.title, widget.items, PdfExportOptions(layout: layout, explanation: explanation, lastAnswer: lastAnswer));
      final name = '${widget.title}-错题集-${PdfExportService.dateLabel(DateTime.now())}.pdf'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      await s.saveExport(widget.projectId, name, bytes);
      if (!mounted) return;
      Navigator.pop(context);
      await saveOrShareFile(context, bytes, name, title: 'PDF 已生成（${fmtSize(bytes.length)}）', mimeType: 'application/pdf');
    } catch (e) {
      if (mounted) setState(() => (busy = false, error = '导出失败：$e'));
    }
  }

  Widget _choice(String label, String sub, AnswerLayout v) => Expanded(
        child: Glass(
          radius: 18,
          tint: layout == v ? M.sage : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onTap: busy ? null : () => setState(() => layout = v),
          child: Column(children: [
            Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: layout == v ? Colors.white : M.text)),
            const SizedBox(height: 2),
            Text(sub, style: TextStyle(fontSize: 11, color: layout == v ? Colors.white : M.sub)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;
    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
      const Text('导出错题 PDF', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text('共 $n 题，按章节分组。公式按应用里的样式排版，可以打印出来重做。', style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
      const SizedBox(height: 14),
      Text('答案位置', style: TextStyle(color: M.sub, fontSize: 13)),
      const SizedBox(height: 8),
      Row(children: [
        _choice('每题后面', '看完马上对答案', AnswerLayout.inline),
        const SizedBox(width: 10),
        _choice('全部放在最后', '先做一遍再对答案', AnswerLayout.end),
      ]),
      const SizedBox(height: 14),
      SettingsGroup(children: [
        SwitchTile(
            icon: Icons.lightbulb_outline_rounded,
            title: '包含解析',
            value: explanation,
            onChanged: busy ? (_) {} : (v) => setState(() => explanation = v)),
        SwitchTile(
            icon: Icons.history_rounded,
            title: '包含上次作答',
            subtitle: '用红字标出你上次选的答案',
            value: lastAnswer,
            onChanged: busy ? (_) {} : (v) => setState(() => lastAnswer = v)),
      ]),
      if (error != null) ...[
        const SizedBox(height: 10),
        Text(error!, style: TextStyle(color: M.roseDark, fontSize: 13)),
      ],
      if (busy) ...[
        const SizedBox(height: 12),
        Text('正在排版…', style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 6),
        LinearProgressIndicator(color: M.sage, backgroundColor: M.glass.withValues(alpha: 0.5)),
      ],
      const SizedBox(height: 14),
      GlassButton(
        label: busy ? '正在生成…' : '生成 PDF',
        icon: Icons.picture_as_pdf_outlined,
        tint: M.sage,
        expand: true,
        onTap: busy || n == 0 ? null : _go,
      ),
    ]);
  }
}

/// 导出 PDF 前：有字体里没有的字时提醒（会显示成空白或方框），用户确认后再导出。没有缺字时直接返回 true。
Future<bool> confirmMissingGlyphs(BuildContext context, List<String> missing) async {
  if (missing.isEmpty) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: M.sheet,
      title: const Text('有些字导出后可能显示不出来'),
      content: Text('PDF 字体里没有这 ${missing.length >= 30 ? '30 多' : missing.length} 个字：\n${missing.join(' ')}\n\n'
          '导出后它们会显示为空白或方框，公式不受影响。仍要导出吗？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍然导出')),
      ],
    ),
  );
  return ok == true;
}
