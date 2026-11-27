import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../help/help_articles.dart' show HelpIds;
import '../services/conn_test.dart';
import '../services/llm.dart';
import '../services/providers.dart';
import '../services/settings.dart';
import '../theme/glass.dart';
import 'ai_widgets.dart';
import 'conn_test_row.dart';
import 'help_page.dart';
import 'me_page.dart' show KeyField, settingsTextField;
import 'settings_pages.dart';

/// 「我的 → AI 模型」：添加服务商、拉取模型、给每个功能选模型。
class LlmSettingsPage extends StatefulWidget {
  const LlmSettingsPage({super.key});
  @override
  State<LlmSettingsPage> createState() => _LlmSettingsPageState();
}

class _LlmSettingsPageState extends State<LlmSettingsPage> {
  final tick = ValueNotifier(0);
  final fetching = <String>{};

  @override
  void dispose() {
    tick.dispose();
    super.dispose();
  }

  void _refresh() {
    tick.value++;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final st = context.read<AppState>().settings;
    return GlassScaffold(
      title: 'AI 模型',
      actions: const [HelpButton(HelpIds.keys)],
      body: ValueListenableBuilder(
        valueListenable: tick,
        builder: (context, _, _) => ListView(padding: const EdgeInsets.all(20), children: [
          Text('先添加服务商、填写密钥，再点「拉取模型」。然后给出题、解释、伴学各自选一个模型。解释和伴学可以跟随出题模型。',
              style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
          const SizedBox(height: 16),
          ...[for (final p in st.providers) ...[_providerCard(st, p), const SizedBox(height: 12)]],
          GlassButton(label: '添加服务商', icon: Icons.add_rounded, expand: true, onTap: () => _addProvider(st)),
          const SizedBox(height: 22),
          _useRow(st, LlmUse.generate, '出题', '生成闪卡和题目、质检、分章、主观题批改。'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final m in ['deepseek-flash', 'deepseek-v4-pro'])
              ActionChip(
                label: Text(m),
                onPressed: () {
                  _useDeepSeek(st, m);
                  _refresh();
                  toast(context, '出题模型已切换为 $m');
                },
              ),
          ]),
          const SizedBox(height: 4),
          Text('日常用 deepseek-flash 更省；难题可以切到 deepseek-v4-pro。', style: TextStyle(color: M.sub, fontSize: 12)),
          const SizedBox(height: 16),
          _useRow(st, LlmUse.explain, 'AI 解释', '闪卡和测验里的「AI 解释」和追问。默认跟随出题模型。'),
          const SizedBox(height: 16),
          _useRow(st, LlmUse.study, 'AI 伴学', '「AI 伴学」、思维导图和笔记里的「让 AI 讲解」。默认跟随出题模型。'),
          const SizedBox(height: 16),
          _webGroup(st),
        ]),
      ),
    );
  }

  Widget _providerCard(Settings st, LlmProvider p) {
    final preset = ProviderPreset.of(p.kind);
    return Glass(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
          IconButton(
            tooltip: '删除服务商',
            onPressed: () async {
              final ok = await showGlassSheet<bool>(
                context,
                (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
                  const Text('删除这个服务商？', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text('密钥会一起从本机去掉。正在用它的功能会改回跟随出题模型。', style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
                  const SizedBox(height: 16),
                  GlassButton(label: '删除', icon: Icons.delete_outline_rounded, expand: true, onTap: () => Navigator.pop(ctx, true)),
                ]),
                initial: 0.4,
              );
              if (ok != true) return;
              st.removeProvider(p.id);
              _refresh();
            },
            icon: Icon(Icons.delete_outline_rounded, color: M.sub),
          ),
        ]),
        if (p.kind == 'custom' || p.baseUrl != preset.baseUrl || preset.baseUrl.isEmpty)
          settingsTextField('接口地址', p.baseUrl, (v) {
            p.baseUrl = v.trim();
            if (p.kind == 'custom') p.kind = ModelCatalog.kindOfUrl(p.baseUrl);
            st.upsertProvider(p);
            _refresh();
          }, hint: preset.baseUrl.isEmpty ? 'https://…/v1' : preset.baseUrl)
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(p.baseUrl, style: TextStyle(color: M.sub, fontSize: 12)),
          ),
        KeyField(
          label: preset.keyOptional ? 'API 密钥（可留空）' : 'API 密钥',
          load: () => st.providerKey(p.id),
          save: (v) => st.setProviderKey(p.id, v),
          hint: preset.keyOptional ? '本地服务通常不用填' : 'sk-...',
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: GlassButton(
              label: fetching.contains(p.id) ? '正在拉取…' : '拉取模型',
              icon: Icons.cloud_download_outlined,
              expand: true,
              onTap: fetching.contains(p.id) ? null : () => _fetch(st, p),
            ),
          ),
          const SizedBox(width: 8),
          GlassButton(label: '手动添加', icon: Icons.edit_outlined, onTap: () => _manualAdd(st, p)),
        ]),
        if (p.models.isNotEmpty) ...[
          const SizedBox(height: 6),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _manageModels(st, p),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(children: [
                Expanded(child: Text('已有 ${p.models.length} 个模型', style: TextStyle(color: M.sub, fontSize: 12))),
                Text('管理、改名、测试', style: TextStyle(color: M.sageDark, fontSize: 12, fontWeight: FontWeight.w600)),
                Icon(Icons.chevron_right_rounded, size: 18, color: M.sageDark),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _useRow(Settings st, LlmUse use, String title, String intro) {
    final follow = use != LlmUse.generate && st.assignment(use).follow;
    final e = st.resolved(use);
    final provider = st.providerById(e.providerId);
    final shown = st.modelLabel(e.providerId, e.model);
    final label = follow ? '跟随出题模型（$shown）' : (e.model.isEmpty ? '还没选模型' : shown);
    final spec = Reasoning.of(e.kind, e.model);
    return Glass(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(intro, style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
        const SizedBox(height: 10),
        Glass(
          radius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          onTap: () async {
            final r = await showModelPicker(context, st, use: use, allowFollow: use != LlmUse.generate);
            if (r == null) return;
            if (r.follow) {
              st.setAssignment(use, const ModelChoice());
            } else {
              st.setAssignment(use, ModelChoice(providerId: r.providerId, modelId: r.modelId));
            }
            _refresh();
          },
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
            Icon(Icons.chevron_right_rounded, color: M.sub),
          ]),
        ),
        if (!follow && provider != null && spec != null) ...[
          const SizedBox(height: 10),
          Text('思考强度', style: TextStyle(color: M.sub, fontSize: 12)),
          const SizedBox(height: 6),
          _reasoningChips(st, use, provider.id, e.model, spec),
        ],
        if (follow && spec != null) ...[
          const SizedBox(height: 8),
          Text('思考强度跟随出题模型的设置。', style: TextStyle(color: M.sub, fontSize: 12)),
        ],
      ]),
    );
  }

  Widget _reasoningChips(Settings st, LlmUse use, String providerId, String model, ReasoningSpec spec) {
    if (providerId.isEmpty) return const SizedBox.shrink();
    final stored = st.reasoningOf(use, providerId: providerId, model: model);
    final current = (stored != null && spec.levels.any((l) => l.id == stored)) ? stored : spec.defaultId;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final l in spec.levels)
        Glass(
          radius: 14,
          tint: current == l.id ? M.sage : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          onTap: () {
            st.setReasoning(use, providerId, model, l.id);
            _refresh();
          },
          child: Text(l.label, style: TextStyle(fontWeight: FontWeight.w600, color: current == l.id ? Colors.white : M.text)),
        ),
    ]);
  }

  Widget _webGroup(Settings st) {
    final reason = st.webUnavailable;
    final on = st.webSearch && reason == null;
    Widget mode(WebMode m) => Expanded(
          child: Glass(
            radius: 14,
            tint: on && st.webMode == m ? M.sage : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            onTap: on
                ? () {
                    st.webMode = m;
                    _refresh();
                  }
                : null,
            child: Column(children: [
              Text(webModeNames[m]!, style: TextStyle(fontWeight: FontWeight.w700, color: on && st.webMode == m ? Colors.white : M.text)),
              const SizedBox(height: 2),
              Text(m == WebMode.deep ? '更准，较慢' : '更快、更省', style: TextStyle(fontSize: 11, color: on && st.webMode == m ? Colors.white : M.sub)),
            ]),
          ),
        );
    final webE = st.resolved(LlmUse.web);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SettingsGroup(title: 'AI 联网', children: [
        SwitchTile(
          icon: Icons.public_rounded,
          title: 'AI 联网搜索',
          subtitle: reason ?? 'AI 解释、伴学、笔记讲解、思维导图和主观题批改会在需要时上网查资料。出闪卡和出题不联网，只依据你的资料。',
          value: on,
          onChanged: (v) {
            if (reason != null) {
              toast(context, reason);
              return;
            }
            st.webSearch = v;
            _refresh();
          },
        ),
      ]),
      const SizedBox(height: 10),
      Opacity(opacity: on ? 1 : 0.5, child: Row(children: [mode(WebMode.deep), const SizedBox(width: 10), mode(WebMode.normal)])),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
            '${webModeNames[WebMode.deep]}：${webModeHints[WebMode.deep]}。\n${webModeNames[WebMode.normal]}：${webModeHints[WebMode.normal]}。\n'
            '搜索和读网页本身不收费，搜到的内容按模型 Token 计费。AI 伴学里每个对话还能单独切换。联网只支持 DeepSeek 的 deepseek-flash。',
            style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
      ),
      const SizedBox(height: 12),
      Glass(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('联网', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('功能本身用的不是 deepseek-flash 时，会先用下面的联网模型搜索整理，再交给它回答。请选择 DeepSeek 的模型。',
              style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
          const SizedBox(height: 10),
          Glass(
            radius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onTap: () async {
              final r = await showModelPicker(context, st, use: LlmUse.web, allowFollow: false, deepSeekWebOnly: true);
              if (r == null || r.follow) return;
              st.setAssignment(LlmUse.web, ModelChoice(providerId: r.providerId, modelId: r.modelId));
              _refresh();
            },
            child: Row(children: [
              Expanded(child: Text(webE.model.isEmpty ? '还没选联网模型' : st.modelLabel(webE.providerId, webE.model), style: const TextStyle(fontWeight: FontWeight.w600))),
              Icon(Icons.chevron_right_rounded, color: M.sub),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Future<void> _addProvider(Settings st) async {
    final preset = await showGlassSheet<ProviderPreset>(
      context,
      (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
        const Text('添加服务商', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('点一下就会填好接口地址，然后只要填写密钥、拉取模型。', style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
        const SizedBox(height: 12),
        for (final p in ProviderPreset.all)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Glass(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              onTap: () => Navigator.pop(ctx, p),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (p.baseUrl.isNotEmpty) Text(p.baseUrl, style: TextStyle(color: M.sub, fontSize: 12)),
                if (p.kind == 'custom') Text('自己填写接口地址', style: TextStyle(color: M.sub, fontSize: 12)),
              ]),
            ),
          ),
      ]),
      initial: 0.7,
    );
    if (preset == null) return;
    st.addPreset(preset);
    _refresh();
  }

  Future<void> _fetch(Settings st, LlmProvider p) async {
    setState(() => fetching.add(p.id));
    try {
      final ids = await ModelCatalog.fetch(p.baseUrl, await st.providerKey(p.id));
      p.models = ids;
      p.modelNames.removeWhere((k, _) => !ids.contains(k));
      st.upsertProvider(p);
      if (mounted) toast(context, '已拉取 ${ids.length} 个模型');
      _refresh();
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      fetching.remove(p.id);
      if (mounted) _refresh();
    }
  }

  Future<void> _manualAdd(Settings st, LlmProvider p) async {
    final r = await showGlassSheet<ModelEditResult>(
      context,
      (ctx, sc) => ModelEditSheet(st: st, provider: p, controller: sc),
      initial: 0.7,
    );
    if (r == null || r.id.isEmpty) return;
    _applyEdit(st, p, r);
  }

  void _applyEdit(Settings st, LlmProvider p, ModelEditResult r) {
    if (r.delete) {
      st.removeModel(p.id, r.id);
    } else {
      final fresh = st.providerById(p.id) ?? p;
      if (!fresh.models.contains(r.id)) fresh.models.add(r.id);
      fresh.setModelName(r.id, r.name);
      st.upsertProvider(fresh);
      p.models = fresh.models;
      p.modelNames = fresh.modelNames;
    }
    _refresh();
  }

  /// 这个服务商的全部模型：点一个可以改名、测试、删除。
  Future<void> _manageModels(Settings st, LlmProvider p) async {
    await showGlassSheet<void>(
      context,
      (ctx, sc) => _ModelListSheet(
        st: st,
        providerId: p.id,
        controller: sc,
        onEdit: (m) async {
          final cur = st.providerById(p.id) ?? p;
          final r = await showGlassSheet<ModelEditResult>(
            ctx,
            (c2, sc2) => ModelEditSheet(st: st, provider: cur, modelId: m, controller: sc2),
            initial: 0.7,
          );
          if (r != null && r.id.isNotEmpty) _applyEdit(st, p, r);
        },
        onAdd: () async {
          final cur = st.providerById(p.id) ?? p;
          final r = await showGlassSheet<ModelEditResult>(
            ctx,
            (c2, sc2) => ModelEditSheet(st: st, provider: cur, controller: sc2),
            initial: 0.7,
          );
          if (r != null && r.id.isNotEmpty) _applyEdit(st, p, r);
        },
      ),
      initial: 0.7,
    );
    _refresh();
  }

  void _useDeepSeek(Settings st, String model) {
    var p = st.providers.cast<LlmProvider?>().firstWhere((x) => x!.isDeepSeek, orElse: () => null);
    p ??= st.addPreset(ProviderPreset.of('deepseek'));
    if (!p.models.contains(model)) {
      p.models.add(model);
      st.upsertProvider(p);
    }
    st.setAssignment(LlmUse.generate, ModelChoice(providerId: p.id, modelId: model));
  }
}

/// 添加 / 编辑模型的结果。
class ModelEditResult {
  final String id;
  final String name;
  final bool delete;
  const ModelEditResult(this.id, this.name, {this.delete = false});
}

/// 添加或编辑一个模型：模型 ID、显示名称，还能点「测试」试一下能不能用。
/// 「测试」按钮实际做的事，测试时可以换成假的。
typedef LlmTester = Future<TestResult> Function({required String baseUrl, required String apiKey, required String model, bool keyOptional});

class ModelEditSheet extends StatefulWidget {
  final Settings st;
  final LlmProvider provider;
  final String? modelId; // 为空表示新添加
  final ScrollController? controller;
  final LlmTester? tester;
  const ModelEditSheet({super.key, required this.st, required this.provider, this.modelId, this.controller, this.tester});
  @override
  State<ModelEditSheet> createState() => _ModelEditSheetState();
}

class _ModelEditSheetState extends State<ModelEditSheet> {
  late final idC = TextEditingController(text: widget.modelId ?? '');
  late final nameC = TextEditingController(text: widget.modelId == null ? '' : (widget.provider.modelNames[widget.modelId!] ?? ''));
  late final changed = Listenable.merge([idC]);
  bool get editing => widget.modelId != null;

  @override
  void dispose() {
    idC.dispose();
    nameC.dispose();
    super.dispose();
  }

  Future<TestResult> _test() async {
    final p = widget.provider;
    final run = widget.tester ?? ConnTest.llm;
    return run(
      baseUrl: p.baseUrl,
      apiKey: await widget.st.providerKey(p.id),
      model: idC.text,
      keyOptional: ProviderPreset.of(p.kind).keyOptional,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.controller,
      padding: EdgeInsets.fromLTRB(20, 8, 20, 30 + MediaQuery.of(context).viewInsets.bottom),
      children: [
        Text(editing ? '编辑模型' : '手动添加模型', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            editing
                ? '${widget.provider.name} 的模型。起个名字后，选模型的地方会显示这个名字。'
                : '有的服务商不支持拉取列表，填一个模型 ID 即可。名字可以不填，不填就显示模型 ID。',
            style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
        const SizedBox(height: 12),
        if (editing)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Glass(
              radius: 14,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Text('模型 ID', style: TextStyle(color: M.sub, fontSize: 13)),
                const SizedBox(width: 12),
                Expanded(child: Text(widget.modelId!, style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: idC,
              autofocus: true,
              decoration: const InputDecoration(labelText: '模型 ID', hintText: '例如 deepseek-flash'),
            ),
          ),
        TextField(
          controller: nameC,
          decoration: const InputDecoration(labelText: '显示名称（可不填）', hintText: '例如 我的 DeepSeek'),
        ),
        const SizedBox(height: 14),
        ConnTestRow(run: _test, reset: changed),
        const SizedBox(height: 16),
        GlassButton(
          label: editing ? '保存' : '添加',
          icon: Icons.check_rounded,
          tint: M.sage,
          expand: true,
          onTap: () {
            final id = idC.text.trim();
            if (id.isEmpty) {
              toast(context, '先填写模型 ID');
              return;
            }
            Navigator.pop(context, ModelEditResult(id, nameC.text.trim()));
          },
        ),
        if (editing) ...[
          const SizedBox(height: 10),
          GlassButton(
            label: '删除这个模型',
            icon: Icons.delete_outline_rounded,
            expand: true,
            onTap: () => Navigator.pop(context, ModelEditResult(widget.modelId!, '', delete: true)),
          ),
        ],
      ],
    );
  }
}

/// 一个服务商的全部模型。
class _ModelListSheet extends StatefulWidget {
  final Settings st;
  final String providerId;
  final ScrollController controller;
  final Future<void> Function(String modelId) onEdit;
  final Future<void> Function() onAdd;
  const _ModelListSheet({required this.st, required this.providerId, required this.controller, required this.onEdit, required this.onAdd});
  @override
  State<_ModelListSheet> createState() => _ModelListSheetState();
}

class _ModelListSheetState extends State<_ModelListSheet> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final p = widget.st.providerById(widget.providerId);
    if (p == null) return const SizedBox();
    final key = q.trim().toLowerCase();
    final list = [
      for (final m in p.models)
        if (key.isEmpty || m.toLowerCase().contains(key) || p.labelOf(m).toLowerCase().contains(key)) m
    ];
    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
      Text('${p.name} 的模型', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text('点一个模型可以起名字、测试能不能用，或者删掉。', style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
      const SizedBox(height: 12),
      if (p.models.length > 8)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(hintText: '搜索模型', prefixIcon: Icon(Icons.search_rounded)),
          ),
        ),
      for (final m in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Glass(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            onTap: () async {
              await widget.onEdit(m);
              if (mounted) setState(() {});
            },
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.labelOf(m), style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (p.labelOf(m) != m) Text(m, style: TextStyle(color: M.sub, fontSize: 12)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: M.sub),
            ]),
          ),
        ),
      if (list.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('没有找到。', style: TextStyle(color: M.sub))),
      const SizedBox(height: 4),
      GlassButton(
        label: '添加模型',
        icon: Icons.add_rounded,
        expand: true,
        onTap: () async {
          await widget.onAdd();
          if (mounted) setState(() {});
        },
      ),
    ]);
  }
}

class ModelPick {
  final bool follow;
  final String? providerId;
  final String? modelId;
  const ModelPick({this.follow = false, this.providerId, this.modelId});
}

/// 选一个已拉取（或手动添加）的模型。按服务商分组。
Future<ModelPick?> showModelPicker(BuildContext context, Settings st,
    {required LlmUse use, bool allowFollow = false, bool deepSeekWebOnly = false}) {
  bool ok(LlmProvider p, String m) {
    if (!deepSeekWebOnly) return true;
    return p.isDeepSeek && LlmClient.webModels.contains(m);
  }

  final groups = <LlmProvider, List<String>>{
    for (final p in st.providers)
      if (p.models.where((m) => ok(p, m)).isNotEmpty) p: [for (final m in p.models) if (ok(p, m)) m],
  };
  return showGlassSheet<ModelPick>(
    context,
    (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
      Text(allowFollow ? '选择模型' : (deepSeekWebOnly ? '选择联网模型' : '选择模型'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(
          groups.isEmpty
              ? (deepSeekWebOnly ? '请先添加 DeepSeek，并拉取或手动添加 deepseek-flash。' : '请先在上面的服务商里拉取或手动添加模型。')
              : '只显示已经拉取或手动添加过的模型。',
          style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
      const SizedBox(height: 12),
      if (allowFollow)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Glass(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            onTap: () => Navigator.pop(ctx, const ModelPick(follow: true)),
            child: const Text('跟随出题模型', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
      for (final e in groups.entries) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
          child: Text(e.key.name, style: TextStyle(color: M.sub, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
        for (final m in e.value)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Glass(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              onTap: () => Navigator.pop(ctx, ModelPick(providerId: e.key.id, modelId: m)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.key.labelOf(m), style: const TextStyle(fontWeight: FontWeight.w600)),
                if (e.key.labelOf(m) != m) Text(m, style: TextStyle(color: M.sub, fontSize: 12)),
              ]),
            ),
          ),
      ],
    ]),
    initial: 0.65,
  );
}


/// 伴学顶部的模型小标签：样式跟联网标签一样，只影响当前对话。
class ChatModelChip extends StatelessWidget {
  final AppState state;
  final String? providerId;
  final String? modelId;
  final bool enabled;
  final ValueChanged<ModelPick> onChanged;
  const ChatModelChip(
      {super.key, required this.state, required this.providerId, required this.modelId, required this.onChanged, this.enabled = true});

  LlmEndpoint get current =>
      state.settings.resolved(LlmUse.study, overrideProvider: providerId, overrideModel: modelId);

  String get label {
    final m = current.model;
    if (m.isEmpty) return '模型';
    final named = state.settings.modelLabel(current.providerId, m);
    if (named != m) return named.length <= 18 ? named : '${named.substring(0, 16)}…';
    return m.length <= 18 ? m : '…${m.substring(m.length - 16)}';
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Glass(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        onTap: enabled ? () => _pick(context) : null,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.smart_toy_outlined, size: 14, color: M.sageDark),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: M.sageDark, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final r = await showModelPicker(context, state.settings, use: LlmUse.study, allowFollow: true);
    if (r != null) onChanged(r);
  }
}
