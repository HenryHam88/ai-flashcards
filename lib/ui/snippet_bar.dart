import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/glass.dart';

/// 一个项目的常用提示词 + 当前选中的几条。AI 解释和 AI 伴学各自持有一个。
class SnippetPicker extends ChangeNotifier {
  final AppState state;
  final String projectId;
  SnippetPicker(this.state, this.projectId);

  List<PromptSnippet> all = [];
  final selected = <String>{};
  String projectName = '';

  /// 选中的提示词（保持添加时的顺序）。
  List<PromptSnippet> get picked => [for (final x in all) if (selected.contains(x.id)) x];
  bool get hasPicked => selected.isNotEmpty;

  /// 把选中的提示词接到问题后面；没选就原样返回。
  String compose(String question) => PromptSnippet.compose(question, picked);

  Future<void> load() async {
    final p = await state.repo.project(projectId);
    all = p?.snippets ?? [];
    projectName = p?.name ?? '';
    selected.removeWhere((id) => !all.any((x) => x.id == id));
    notifyListeners();
  }

  void toggle(String id) {
    selected.contains(id) ? selected.remove(id) : selected.add(id);
    notifyListeners();
  }

  void clearSelection() {
    if (selected.isEmpty) return;
    selected.clear();
    notifyListeners();
  }

  Future<void> save(List<PromptSnippet> list) async {
    final p = await state.repo.project(projectId);
    if (p == null) return;
    p.snippets = list;
    await state.repo.saveProject(p);
    all = list;
    selected.removeWhere((id) => !all.any((x) => x.id == id));
    notifyListeners();
  }

  Future<void> upsert(PromptSnippet s) async {
    final list = [...all];
    final i = list.indexWhere((x) => x.id == s.id);
    i < 0 ? list.add(s) : list[i] = s;
    await save(list);
  }

  Future<void> remove(String id) => save([for (final x in all) if (x.id != id) x]);
}

/// 输入框上方的一排提示词按钮：点一下选中（再点取消），选中的会跟着这次提问一起发给 AI。
class SnippetBar extends StatelessWidget {
  final SnippetPicker picker;
  final bool enabled;
  const SnippetBar({super.key, required this.picker, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: picker,
      builder: (context, _) {
        Widget chip(String label, {IconData? icon, bool on = false, VoidCallback? onTap, Key? key}) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Glass(
                key: key,
                radius: 14,
                tint: on ? M.sage : null,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                onTap: enabled ? onTap : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[Icon(icon, size: 15, color: on ? Colors.white : M.sageDark), const SizedBox(width: 4)],
                    Flexible(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? Colors.white : M.text)),
                    ),
                  ]),
                ),
              ),
            );
        return SizedBox(
          height: 34,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final x in picker.all)
              chip(x.label,
                  key: ValueKey('snippet_${x.id}'),
                  icon: picker.selected.contains(x.id) ? Icons.check_rounded : null,
                  on: picker.selected.contains(x.id),
                  onTap: () => picker.toggle(x.id)),
            chip(picker.all.isEmpty ? '常用提示词' : '管理',
                key: const ValueKey('snippet_manage'),
                icon: picker.all.isEmpty ? Icons.add_rounded : Icons.tune_rounded,
                onTap: () => showSnippetManager(context, picker)),
          ]),
        );
      },
    );
  }
}

class _SnippetEdit {
  final PromptSnippet? snippet;
  final bool delete;
  const _SnippetEdit(this.snippet, {this.delete = false});
}

/// 管理这个项目的提示词：添加、改、删，可以有很多条。
Future<void> showSnippetManager(BuildContext context, SnippetPicker picker) async {
  await picker.load();
  if (!context.mounted) return;
  await showGlassSheet<void>(
    context,
    (ctx, sc) => ListenableBuilder(
      listenable: picker,
      builder: (ctx, _) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
        const Text('常用提示词', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            '只在${picker.projectName.isEmpty ? '这个项目' : '「${picker.projectName}」'}里用。在 AI 解释和 AI 伴学里点一下，就会跟着问题一起发给 AI；不点就和平时一样，也可以照常自己输入。',
            style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
        const SizedBox(height: 12),
        if (picker.all.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('还没有。比如「按考研数学的角度讲，多举例子」「只讲结论，不要推导」。', style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
          ),
        for (final x in picker.all)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Glass(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              onTap: () => _editSnippet(ctx, picker, x),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (x.name.trim().isNotEmpty) Text(x.name.trim(), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(x.text.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: M.sub, fontSize: 13, height: 1.4)),
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, color: M.sub),
              ]),
            ),
          ),
        GlassButton(label: '添加提示词', icon: Icons.add_rounded, expand: true, onTap: () => _editSnippet(ctx, picker, null)),
      ]),
    ),
    initial: 0.7,
  );
}

Future<void> _editSnippet(BuildContext context, SnippetPicker picker, PromptSnippet? cur) async {
  final r = await showGlassSheet<_SnippetEdit>(
    context,
    (ctx, sc) => _SnippetEditSheet(cur: cur, controller: sc),
    initial: 0.65,
  );
  if (r == null) return;
  if (r.delete && cur != null) {
    await picker.remove(cur.id);
  } else if (r.snippet != null) {
    await picker.upsert(r.snippet!);
  }
}

class _SnippetEditSheet extends StatefulWidget {
  final PromptSnippet? cur;
  final ScrollController controller;
  const _SnippetEditSheet({required this.cur, required this.controller});
  @override
  State<_SnippetEditSheet> createState() => _SnippetEditSheetState();
}

class _SnippetEditSheetState extends State<_SnippetEditSheet> {
  late final nameC = TextEditingController(text: widget.cur?.name ?? '');
  late final textC = TextEditingController(text: widget.cur?.text ?? '');

  @override
  void dispose() {
    nameC.dispose();
    textC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.cur;
    return ListView(
      controller: widget.controller,
      padding: EdgeInsets.fromLTRB(20, 8, 20, 30 + MediaQuery.of(context).viewInsets.bottom),
      children: [
        Text(cur == null ? '添加提示词' : '编辑提示词', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        TextField(controller: nameC, decoration: const InputDecoration(labelText: '名称（可不填）', hintText: '例如 考研视角')),
        const SizedBox(height: 12),
        TextField(
          controller: textC,
          autofocus: cur == null,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(labelText: '内容', hintText: '例如 按考研数学的角度讲，多举例子'),
        ),
        const SizedBox(height: 16),
        GlassButton(
          label: '保存',
          icon: Icons.check_rounded,
          tint: M.sage,
          expand: true,
          onTap: () {
            if (textC.text.trim().isEmpty) {
              toast(context, '先写内容');
              return;
            }
            Navigator.pop(context, _SnippetEdit(PromptSnippet(id: cur?.id ?? newId(), name: nameC.text.trim(), text: textC.text.trim())));
          },
        ),
        if (cur != null) ...[
          const SizedBox(height: 10),
          GlassButton(label: '删除', icon: Icons.delete_outline_rounded, expand: true, onTap: () => Navigator.pop(context, const _SnippetEdit(null, delete: true))),
        ],
      ],
    );
  }
}

/// 项目页菜单里的入口：不用打开 AI 解释也能管理提示词。
Future<void> openSnippetManager(BuildContext context, String projectId) {
  final picker = SnippetPicker(context.read<AppState>(), projectId);
  return showSnippetManager(context, picker).whenComplete(picker.dispose);
}
