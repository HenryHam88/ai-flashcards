import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/pipeline.dart' show questionsPerKp;
import '../services/settings.dart' show Settings;
import '../theme/glass.dart';
import '../help/help_articles.dart' show HelpIds;
import 'help_page.dart' show HelpButton;
import 'home_page.dart';
import 'number_input.dart';

/// 生成选项面板：每次生成前弹出。返回选好的 GenOptions，取消返回 null。
/// [preset]：预先填好的选项（例如统计页「针对这些出新题」带上薄弱章节和侧重点）。
Future<GenOptions?> showGenOptionsSheet(BuildContext context, Project project, List<String> chapters, {GenOptions? preset}) {
  return showGlassSheet<GenOptions>(
      context, (ctx, sc) => _GenSheet(project: project, chapters: chapters, controller: sc, preset: preset),
      initial: 0.85, maxSize: 0.95);
}

class _GenSheet extends StatefulWidget {
  final Project project;
  final List<String> chapters;
  final ScrollController controller;
  final GenOptions? preset;
  const _GenSheet({required this.project, required this.chapters, required this.controller, this.preset});
  @override
  State<_GenSheet> createState() => _GenSheetState();
}

class _GenSheetState extends State<_GenSheet> {
  late GenOptions o = widget.preset ??
      (widget.project.defaultOptions != null ? GenOptions.fromJson(widget.project.defaultOptions!) : GenOptions());
  late final custom = TextEditingController(text: o.custom);
  late final from = TextEditingController(text: '${o.pageFrom}');
  late final to = TextEditingController(text: '${o.pageTo}');

  void _apply(Map<String, dynamic> t) {
    setState(() {
      final j = o.toJson()..addAll(t);
      o = GenOptions.fromJson(j);
      custom.text = o.custom;
    });
  }

  GenOptions _collect() => o
    ..custom = custom.text
    ..pageFrom = int.tryParse(from.text) ?? 1
    ..pageTo = int.tryParse(to.text) ?? 30;

  Widget _chips(List<String> all, List<String> sel, {bool single = false, void Function(String)? onSingle}) => Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final v in all)
            FilterChip(
              label: Text(v),
              selected: sel.contains(v),
              showCheckmark: false,
              onSelected: (on) => setState(() {
                if (single) {
                  onSingle!(v);
                } else {
                  on ? sel.add(v) : sel.remove(v);
                }
              }),
            ),
        ],
      );

  /// ±5 或点数字直接输入（数字键盘），超出范围自动取边界。
  Widget _counter(String label, int value, void Function(int) set, {int min = 0, int max = maxGenCount, String unit = '', String? title}) =>
      NumberStepper(
          label: label,
          value: value,
          min: min,
          max: max,
          unit: unit,
          dialogTitle: title ?? '$label数量',
          onChanged: (v) => setState(() => set(v)));

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final templates = s.settings.genTemplates;
    const h = TextStyle(fontWeight: FontWeight.w700, fontSize: 15);
    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
      Row(children: [
        const Expanded(child: Text('生成选项', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
        const HelpButton(HelpIds.generate),
      ]),
      const SizedBox(height: 10),
      if (templates.isNotEmpty) ...[
        const Text('模板', style: h),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final e in templates.entries)
            InputChip(
              label: Text(e.key),
              onPressed: () => _apply(e.value),
              onDeleted: () {
                final t = s.settings.genTemplates..remove(e.key);
                s.settings.genTemplates = t;
                setState(() {});
              },
            ),
        ]),
        const SizedBox(height: 12),
      ],
      const Text('范围', style: h),
      const SizedBox(height: 6),
      _chips(['整份资料', '按章节', '按页码'], [
        {'whole': '整份资料', 'chapters': '按章节', 'pages': '按页码'}[o.scope]!
      ], single: true, onSingle: (v) => o.scope = {'整份资料': 'whole', '按章节': 'chapters', '按页码': 'pages'}[v]!),
      if (o.scope == 'chapters') ...[
        const SizedBox(height: 6),
        widget.chapters.isEmpty
            ? Text('还没有识别到章节，请先解析资料', style: TextStyle(color: M.sub))
            : _chips(widget.chapters, o.chapters),
      ],
      if (o.scope == 'pages')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            const Text('第'),
            const SizedBox(width: 6),
            SizedBox(width: 70, child: TextField(controller: from, keyboardType: TextInputType.number)),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('至')),
            SizedBox(width: 70, child: TextField(controller: to, keyboardType: TextInputType.number)),
            const SizedBox(width: 6),
            const Text('页'),
          ]),
        ),
      const SizedBox(height: 12),
      const Text('数量', style: h),
      const SizedBox(height: 6),
      _chips(['固定数量', '自动（按知识点）'], [o.autoCount ? '自动（按知识点）' : '固定数量'],
          single: true, onSingle: (v) => o.autoCount = v != '固定数量'),
      if (!o.autoCount) ...[
        _counter('闪卡', o.cardCount, (v) => o.cardCount = v, unit: '张'),
        _counter('题目', o.questionCount, (v) => o.questionCount = v, unit: '道'),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 12),
          child: Text('点数字可直接输入，各最多 $maxGenCount；数量多时会自动分成多批生成。',
              style: TextStyle(color: M.sub, fontSize: 12)),
        ),
      ] else ...[
        const SizedBox(height: 8),
        Text('先让 AI 列出所选内容里的知识点（定义、定理、公式、例题），再按每个知识点约 1 张闪卡、'
            '${questionsPerKp(o.difficulty)} 道题（随难度：基础 1、中等 2、拔高 3）估算数量。生成前会显示预计数量，确认后才开始。',
            style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilterChip(
              label: const Text('出闪卡'),
              selected: o.autoCards,
              showCheckmark: true,
              onSelected: (v) => setState(() => o.autoCards = v)),
          FilterChip(
              label: const Text('出题目'),
              selected: o.autoQuestions,
              showCheckmark: true,
              onSelected: (v) => setState(() => o.autoQuestions = v)),
        ]),
        _counter('单次上限（闪卡 + 题目）', s.settings.autoCap, (v) => s.settings.autoCap = v,
            min: Settings.minAutoCap, max: Settings.maxAutoCap, title: '单次上限（闪卡 + 题目）'),
      ],
      const Text('题型', style: h),
      const SizedBox(height: 6),
      _chips(QType.all, o.types),
      const SizedBox(height: 12),
      const Text('难度', style: h),
      const SizedBox(height: 6),
      _chips(['基础', '中等', '拔高', '混合'], [o.difficulty], single: true, onSingle: (v) => o.difficulty = v),
      const SizedBox(height: 12),
      const Text('侧重点', style: h),
      const SizedBox(height: 6),
      _chips(['概念定义', '公式定理', '计算应用', '易错点'], o.focus),
      const SizedBox(height: 12),
      const Text('自定义要求', style: h),
      const SizedBox(height: 6),
      TextField(
        controller: custom,
        minLines: 2,
        maxLines: 5,
        decoration: const InputDecoration(hintText: '例如：只出第三章的计算题，仿照课后习题的风格；闪卡背面加一个例子'),
      ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: GlassButton(
            label: '存为模板',
            icon: Icons.bookmark_add_outlined,
            onTap: () async {
              final name = await promptText(context, '模板名称', hint: '例如：期末冲刺');
              if (name == null || name.trim().isEmpty) return;
              final j = _collect().toJson()..removeWhere((k, _) => ['scope', 'chapters', 'pageFrom', 'pageTo'].contains(k));
              s.settings.genTemplates = s.settings.genTemplates..[name.trim()] = j;
              setState(() {});
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GlassButton(
            label: '设为项目默认',
            icon: Icons.star_outline_rounded,
            onTap: () async {
              widget.project.defaultOptions = _collect().toJson();
              await s.repo.saveProject(widget.project);
              if (context.mounted) toast(context, '已设为「${widget.project.name}」的默认设置');
            },
          ),
        ),
      ]),
      const SizedBox(height: 6),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: s.settings.reviewBeforeAdd,
        activeThumbColor: M.sageDark,
        onChanged: (v) => setState(() => s.settings.reviewBeforeAdd = v),
        title: const Text('生成后先审核', style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('先放进「待审核」，确认后才加入复习；关闭时直接加入，生成后也可点「审核这批」',
            style: TextStyle(color: M.sub, fontSize: 12)),
      ),
      const SizedBox(height: 4),
      GlassButton(
        label: '开始生成',
        icon: Icons.auto_awesome_rounded,
        tint: M.sage,
        expand: true,
        onTap: () {
          final r = _collect();
          if (r.autoCount && !r.autoCards && !r.autoQuestions) {
            toast(context, '请至少选择闪卡或题目');
            return;
          }
          if (r.types.isEmpty && (r.autoCount ? r.autoQuestions : r.questionCount > 0)) {
            toast(context, '请至少选择一种题型');
            return;
          }
          Navigator.pop(context, r.copy());
        },
      ),
    ]);
  }
}
