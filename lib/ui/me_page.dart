import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/prompts.dart';
import '../services/settings.dart';
import '../theme/glass.dart';
import 'wrong_book_page.dart';

class MePage extends StatelessWidget {
  const MePage({super.key});
  @override
  Widget build(BuildContext context) {
    void go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    Widget item(IconData i, String t, String sub, Widget page) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Glass(
            onTap: () => go(page),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Icon(i, color: M.text),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  Text(sub, style: const TextStyle(color: M.sub, fontSize: 12)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: M.sub),
            ]),
          ),
        );
    return SafeArea(
      bottom: false,
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 110), children: [
        const Text('我的', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        item(Icons.smart_toy_outlined, '出题模型', '接口地址、API 密钥、模型名称', const LlmSettingsPage()),
        item(Icons.document_scanner_outlined, 'PDF 解析', 'DeepSeek OCR / Kimi / 本地提取', const OcrSettingsPage()),
        item(Icons.bookmark_border_rounded, '错题本', '全部项目的错题', const WrongBookPage()),
        item(Icons.tune_rounded, '高级：提示词', '查看和修改出题、解释、批改用的提示词', const PromptSettingsPage()),
        const SizedBox(height: 8),
        const Glass(
          child: Text('所有数据（资料、解析结果、卡片、错题）只保存在本机；API 密钥保存在系统安全存储中，不会上传到任何地方。',
              style: TextStyle(color: M.sub, fontSize: 13, height: 1.6)),
        ),
      ]),
    );
  }
}

class _KeyField extends StatefulWidget {
  final String label;
  final Future<String> Function() load;
  final Future<void> Function(String) save;
  const _KeyField({required this.label, required this.load, required this.save});
  @override
  State<_KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<_KeyField> {
  final c = TextEditingController();
  bool obscure = true;
  @override
  void initState() {
    super.initState();
    widget.load().then((v) => mounted ? setState(() => c.text = v) : null);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: obscure,
          onChanged: widget.save,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: 'sk-...',
            suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => obscure = !obscure)),
          ),
        ),
      );
}

Widget _textField(String label, String value, void Function(String) onChanged, {String? hint}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
          initialValue: value, onChanged: onChanged, decoration: InputDecoration(labelText: label, hintText: hint)),
    );

class LlmSettingsPage extends StatefulWidget {
  const LlmSettingsPage({super.key});
  @override
  State<LlmSettingsPage> createState() => _LlmSettingsPageState();
}

class _LlmSettingsPageState extends State<LlmSettingsPage> {
  String? testResult;
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final st = s.settings;
    return GlassScaffold(
      title: '出题模型',
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('兼容 OpenAI 格式的服务都能用（DeepSeek、通义千问、Kimi 等）。', style: TextStyle(color: M.sub, fontSize: 13)),
            const SizedBox(height: 12),
            _textField('接口地址', st.llmBaseUrl, (v) => st.llmBaseUrl = v, hint: 'https://api.deepseek.com'),
            _KeyField(label: 'API 密钥', load: st.llmKey, save: st.setLlmKey),
            _textField('模型名称', st.llmModel, (v) => st.llmModel = v, hint: 'deepseek-flash'),
            Wrap(spacing: 8, children: [
              for (final m in ['deepseek-flash', 'deepseek-v4-pro'])
                ActionChip(
                    label: Text(m),
                    onPressed: () {
                      st.llmModel = m;
                      setState(() {});
                      toast(context, '已切换为 $m（重新进入页面可见）');
                    }),
            ]),
            const SizedBox(height: 8),
            const Text('提示：日常用 deepseek-flash 便宜；难题可切到 deepseek-v4-pro。', style: TextStyle(color: M.sub, fontSize: 12)),
          ]),
        ),
        const SizedBox(height: 14),
        GlassButton(
          label: '测试连接',
          icon: Icons.wifi_tethering_rounded,
          expand: true,
          onTap: () async {
            setState(() => testResult = '测试中…');
            try {
              final r = await (await s.llm()).chatJson('请输出 json：{"ok":true}');
              setState(() => testResult = '连接成功：$r');
            } catch (e) {
              setState(() => testResult = '失败：$e');
            }
          },
        ),
        if (testResult != null) Padding(padding: const EdgeInsets.all(8), child: Text(testResult!)),
      ]),
    );
  }
}

class OcrSettingsPage extends StatefulWidget {
  const OcrSettingsPage({super.key});
  @override
  State<OcrSettingsPage> createState() => _OcrSettingsPageState();
}

class _OcrSettingsPageState extends State<OcrSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final st = context.read<AppState>().settings;
    return GlassScaffold(
      title: 'PDF 解析',
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('解析方式', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final p in OcrProvider.values)
                ChoiceChip(
                  label: Text(ocrProviderNames[p]!),
                  selected: st.ocrProvider == p,
                  onSelected: (_) => setState(() => st.ocrProvider = p),
                ),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        if (st.ocrProvider == OcrProvider.deepseek)
          Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('DeepSeek OCR', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('扫描版也能识别，公式会保留为 LaTeX。每批最多 1000 页、100 MiB，需在 180 秒内完成，所以会在本地分批上传。',
                  style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                for (final m in [('text_recognition', '纯文字教材'), ('rich_layout_recognition', '带图表/版面')])
                  ChoiceChip(
                      label: Text(m.$2),
                      selected: st.ocrMode == m.$1,
                      onSelected: (_) => setState(() => st.ocrMode = m.$1)),
              ]),
              const SizedBox(height: 12),
              _textField('接口地址', st.ocrBaseUrl, (v) => st.ocrBaseUrl = v),
              _KeyField(label: 'OCR 密钥（留空则使用出题模型的密钥）', load: st.ocrKeyRaw, save: st.setOcrKey),
            ]),
          ),
        if (st.ocrProvider == OcrProvider.kimi)
          Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Kimi 文件解析', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('上传后由 Kimi 抽取文字（目前免费）。每批的文字会记在该批首页。', style: TextStyle(color: M.sub, fontSize: 12)),
              const SizedBox(height: 12),
              _textField('接口地址', st.kimiBaseUrl, (v) => st.kimiBaseUrl = v),
              _KeyField(label: 'Kimi API 密钥', load: st.kimiKey, save: st.setKimiKey),
            ]),
          ),
        if (st.ocrProvider == OcrProvider.local)
          const Glass(
              child: Text('直接读取 PDF 自带的文字层，不花钱、不联网；扫描版 PDF 没有文字层，读不出内容，公式也可能变成普通字符。',
                  style: TextStyle(color: M.sub, height: 1.5))),
        const SizedBox(height: 12),
        Glass(
          child: Row(children: [
            const Expanded(child: Text('每批页数')),
            IconButton(
                onPressed: () => setState(() => st.ocrBatchPages = (st.ocrBatchPages - 10).clamp(10, 200)),
                icon: const Icon(Icons.remove_circle_outline)),
            Text('${st.ocrBatchPages}', style: const TextStyle(fontWeight: FontWeight.w700)),
            IconButton(
                onPressed: () => setState(() => st.ocrBatchPages = (st.ocrBatchPages + 10).clamp(10, 200)),
                icon: const Icon(Icons.add_circle_outline)),
          ]),
        ),
      ]),
    );
  }
}

class PromptSettingsPage extends StatefulWidget {
  const PromptSettingsPage({super.key});
  @override
  State<PromptSettingsPage> createState() => _PromptSettingsPageState();
}

class _PromptSettingsPageState extends State<PromptSettingsPage> {
  int gen = 0;
  @override
  Widget build(BuildContext context) {
    final st = context.read<AppState>().settings;
    return GlassScaffold(
      title: '高级：提示词',
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('可直接修改发给 AI 的完整提示词。{{...}} 是占位符，会被自动替换，请保留。',
            style: TextStyle(color: M.sub, fontSize: 13)),
        const SizedBox(height: 12),
        for (final e in Prompts.names.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Glass(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(e.value, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(
                      onPressed: () => setState(() {
                            st.resetPrompt(e.key);
                            gen++;
                          }),
                      child: const Text('恢复默认')),
                ]),
                TextFormField(
                  key: ValueKey('${e.key}_$gen'),
                  initialValue: st.prompt(e.key),
                  minLines: 4,
                  maxLines: 14,
                  style: const TextStyle(fontSize: 12, height: 1.4),
                  onChanged: (v) => st.setPrompt(e.key, v),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}
