import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../services/cloud_storage.dart' show CloudProvider;
import '../services/concurrency.dart';
import '../services/llm.dart';
import '../services/prompts.dart';
import '../services/settings.dart';
import '../theme/glass.dart';
import '../help/help_articles.dart' show HelpIds;
import 'ai_widgets.dart';
import 'cloud_settings_page.dart';
import 'explain_history_page.dart';
import 'favorites_page.dart';
import 'help_page.dart';
import 'number_input.dart';
import 'settings_pages.dart';
import 'wrong_book_page.dart';

class MePage extends StatelessWidget {
  const MePage({super.key});
  @override
  Widget build(BuildContext context) {
    void go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    final s = context.watch<AppState>();
    final st = s.settings;
    String mode() => const {'light': '浅色', 'dark': '深色', 'system': '跟随系统'}[st.themeMode] ?? '浅色';
    String lim(int v) => v == 0 ? '不限' : '$v';
    return SafeArea(
      bottom: false,
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 110), children: [
        const Text('我的', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        SettingsGroup(title: '学习', children: [
          SettingsTile(icon: Icons.bookmark_border_rounded, title: '错题本', subtitle: '全部项目的错题', onTap: () => go(const WrongBookPage())),
          SettingsTile(
              icon: Icons.star_outline_rounded, title: '收藏', subtitle: '全部项目收藏的知识点、闪卡和题目', onTap: () => go(const FavoritesPage())),
          SettingsTile(
              icon: Icons.history_edu_rounded,
              title: '解释历史',
              subtitle: '所有 AI 解释与追问，可搜索、收藏、继续提问',
              onTap: () => go(const ExplainHistoryPage())),
        ]),
        SettingsGroup(title: '模型配置', children: [
          SettingsTile(icon: Icons.smart_toy_outlined, title: '出题模型', subtitle: st.llmModel, onTap: () => go(const LlmSettingsPage())),
          SettingsTile(
              icon: Icons.document_scanner_outlined,
              title: '文档解析（PDF / Word）',
              subtitle: ocrProviderNames[st.ocrProvider] ?? '',
              onTap: () => go(const OcrSettingsPage())),
          SettingsTile(
              icon: Icons.tune_rounded, title: '高级：提示词', subtitle: '出题、解释、批改用的提示词', onTap: () => go(const PromptSettingsPage())),
        ]),
        SettingsGroup(title: '偏好', children: [
          SettingsTile(
              icon: Icons.school_outlined,
              title: '学习设置',
              subtitle: '新卡 ${lim(st.dailyNewLimit)} / 复习 ${lim(st.dailyReviewLimit)} · 目标记忆率 ${(st.desiredRetention * 100).round()}%',
              onTap: () => go(const LearningSettingsPage())),
          SettingsTile(
              icon: Icons.palette_outlined,
              title: '外观',
              subtitle: '${mode()} · 字号 ${(st.textScale * 100).round()}%',
              onTap: () => go(const AppearancePage())),
          SettingsTile(
              icon: Icons.notifications_none_rounded,
              title: '提醒',
              subtitle: st.reminderOn
                  ? '每天 ${(st.reminderMinutes ~/ 60).toString().padLeft(2, '0')}:${(st.reminderMinutes % 60).toString().padLeft(2, '0')}'
                  : '未开启',
              onTap: () => go(const ReminderPage())),
        ]),
        SettingsGroup(title: '数据', children: [
          SettingsTile(
              icon: Icons.import_export_rounded,
              title: '导出 / 导入数据',
              subtitle: st.autoBackup ? '备份、换手机迁移 · 已开启每周自动备份' : '备份、换手机迁移、分享项目',
              onTap: () => go(const DataPage())),
          SettingsTile(
              icon: Icons.cloud_outlined,
              title: '云端存储',
              subtitle: st.cloudBucket.isEmpty
                  ? '未配置 · 用自己的阿里云 OSS / 腾讯云 COS 存放大文件，省手机空间'
                  : '${CloudProvider.of(st.cloudProvider).name} · ${st.cloudBucket}',
              onTap: () => go(const CloudSettingsPage())),
        ]),
        SettingsGroup(title: '帮助与关于', children: [
          SettingsTile(
              icon: Icons.help_outline_rounded,
              title: '使用帮助',
              subtitle: '快速上手、各功能怎么用、常见问题',
              onTap: () => go(const HelpHomePage())),
          SettingsTile(
              icon: Icons.info_outline_rounded,
              title: '关于闪卡刷题',
              subtitle: s.appVersion.isEmpty ? '更新日志、开源许可、隐私说明' : '版本 ${s.appVersion} · 检查更新、更新日志',
              onTap: () => go(const AboutPage())),
        ]),
        const SizedBox(height: 16),
        Text('所有数据只保存在本机（配置云端存储后，只有你选择释放的大文件会放到你自己的存储桶）；密钥保存在系统安全存储中。',
            textAlign: TextAlign.center, style: TextStyle(color: M.sub, fontSize: 12, height: 1.6)),
      ]),
    );
  }
}

class KeyField extends StatefulWidget {
  final String label;
  final Future<String> Function() load;
  final Future<void> Function(String) save;
  final String hint;
  const KeyField({super.key, required this.label, required this.load, required this.save, this.hint = 'sk-...'});
  @override
  State<KeyField> createState() => KeyFieldState();
}

class KeyFieldState extends State<KeyField> {
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
            hintText: widget.hint,
            suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => obscure = !obscure)),
          ),
        ),
      );
}

Widget settingsTextField(String label, String value, void Function(String) onChanged, {String? hint}) => Padding(
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
  final tick = ValueNotifier(0); // 接口地址 / 模型变了，联网是否可用要跟着变

  @override
  void dispose() {
    tick.dispose();
    super.dispose();
  }

  Widget _webGroup(Settings st) => ValueListenableBuilder(
        valueListenable: tick,
        builder: (context, _, _) {
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
                          tick.value++;
                        }
                      : null,
                  child: Column(children: [
                    Text(webModeNames[m]!, style: TextStyle(fontWeight: FontWeight.w700, color: on && st.webMode == m ? Colors.white : M.text)),
                    const SizedBox(height: 2),
                    Text(m == WebMode.deep ? '更准，较慢' : '更快、更省',
                        style: TextStyle(fontSize: 11, color: on && st.webMode == m ? Colors.white : M.sub)),
                  ]),
                ),
              );
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
                  tick.value++;
                },
              ),
            ]),
            const SizedBox(height: 10),
            Opacity(
              opacity: on ? 1 : 0.5,
              child: Row(children: [mode(WebMode.deep), const SizedBox(width: 10), mode(WebMode.normal)]),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                  '${webModeNames[WebMode.deep]}：${webModeHints[WebMode.deep]}。\n${webModeNames[WebMode.normal]}：${webModeHints[WebMode.normal]}。\n'
                  '搜索和读网页本身不收费，搜到的内容按模型 Token 计费。AI 伴学里每个对话还能单独切换。',
                  style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
            ),
            const SizedBox(height: 12),
            Glass(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('联网模型', style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                    st.webNative
                        ? '出题模型是 ${st.llmModel}，可以直接联网。换成其他模型时，会先用下面的联网模型通过 DeepSeek 搜索整理，再交给出题模型回答。'
                        : st.webRelay
                            ? '出题模型「${st.llmModel}」不能直接联网：会先用联网模型通过 DeepSeek 搜索整理，再把结果交给它回答（多一次调用，按联网模型的 Token 计费）。'
                            : '联网只支持 DeepSeek 的 deepseek-flash，请把联网模型改为 deepseek-flash。',
                    style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
                const SizedBox(height: 12),
                settingsTextField('联网模型名称', st.webModel, (v) {
                  st.webModel = v;
                  tick.value++;
                }, hint: 'deepseek-flash'),
                KeyField(label: '联网 API 密钥（DeepSeek）', load: st.webKeyRaw, save: st.setWebKey, hint: '留空则用出题模型或 DeepSeek OCR 的密钥'),
                Text('接口固定为 ${Settings.webBaseUrl}。', style: TextStyle(color: M.sub, fontSize: 12)),
              ]),
            ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final st = s.settings;
    return GlassScaffold(
      title: '出题模型',
      actions: const [HelpButton(HelpIds.keys)],
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('兼容 OpenAI 格式的服务都能用（DeepSeek、通义千问、Kimi 等）。', style: TextStyle(color: M.sub, fontSize: 13)),
            const SizedBox(height: 12),
            settingsTextField('接口地址', st.llmBaseUrl, (v) {
              st.llmBaseUrl = v;
              tick.value++;
            }, hint: 'https://api.deepseek.com'),
            KeyField(label: 'API 密钥', load: st.llmKey, save: st.setLlmKey),
            settingsTextField('模型名称', st.llmModel, (v) {
              st.llmModel = v;
              tick.value++;
            }, hint: 'deepseek-flash'),
            Wrap(spacing: 8, children: [
              for (final m in ['deepseek-flash', 'deepseek-v4-pro'])
                ActionChip(
                    label: Text(m),
                    onPressed: () {
                      st.llmModel = m;
                      tick.value++;
                      setState(() {});
                      toast(context, '已切换为 $m（重新进入页面可见）');
                    }),
            ]),
            const SizedBox(height: 8),
            Text('提示：日常用 deepseek-flash 便宜；难题可切到 deepseek-v4-pro。', style: TextStyle(color: M.sub, fontSize: 12)),
            const SizedBox(height: 12),
            settingsTextField('上下文长度（千 token）', st.llmContextK == 0 ? '' : '${st.llmContextK}', (v) => st.llmContextK = int.tryParse(v.trim()) ?? 0,
                hint: '留空 = 自动（DeepSeek 1000，其他 128）'),
            Text('AI 伴学按这个长度决定附件能发多少字。用其他服务时可按它的说明填写。', style: TextStyle(color: M.sub, fontSize: 12)),
          ]),
        ),
        _webGroup(st),
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
      title: '文档解析（PDF / Word）',
      actions: const [HelpButton(HelpIds.upload)],
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
            const SizedBox(height: 10),
            const Text('支持的格式', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            for (final p in OcrProvider.values)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(children: [
                  Icon(Settings.supportsWord(p) ? Icons.check_circle_outline : Icons.remove_circle_outline,
                      size: 15, color: Settings.supportsWord(p) ? M.sageDark : M.roseDark),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('${ocrProviderNames[p]}：${Settings.providerFormats[p]}',
                        style: TextStyle(fontSize: 12, color: st.ocrProvider == p ? M.text : M.sub,
                            fontWeight: st.ocrProvider == p ? FontWeight.w600 : FontWeight.w400)),
                  ),
                ]),
              ),
            const SizedBox(height: 4),
            Text('Word（.docx 和旧版 .doc）会整份交给所选模型解析，不在手机上本地解析。TXT 不受这里的设置影响，总是在手机上直接读取。',
                style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
          ]),
        ),
        const SizedBox(height: 12),
        if (st.ocrProvider == OcrProvider.deepseek)
          Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('DeepSeek OCR', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('扫描版也能识别，公式会保留为 LaTeX，支持 PDF 和 Word。每批最多 1000 页、100 MiB，需在 180 秒内完成，所以 PDF 会在本地分批上传；Word 整份上传（文字模式下没有图片的 Word 直接抽取文字）。',
                  style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                for (final m in [(Settings.ocrText, '纯文字教材'), (Settings.ocrRich, '带图表/版面')])
                  FilterChip(
                    label: Text(m.$2),
                    selected: st.ocrModes.contains(m.$1),
                    onSelected: (on) {
                      final l = [...st.ocrModes];
                      on ? l.add(m.$1) : l.remove(m.$1);
                      if (l.isEmpty) {
                        toast(context, '至少保留一种模式');
                        return;
                      }
                      setState(() => st.ocrModes = l);
                    },
                  ),
              ]),
              const SizedBox(height: 8),
              Text(
                st.ocrMixed
                    ? '已开启混合模式：解析前先在手机上逐页检查，文字很少的页（扫描页、整页插图）或带「图 1.2」这类图注的页用版面模式，其余页用文字模式；每页只上传一次，结果按原页码合并。'
                    : (st.ocrModes.first == Settings.ocrRich
                        ? '全部页面用版面模式，保留图表和插图位置。'
                        : '全部页面用文字模式，适合纯文字教材。两个都选可开启混合模式。'),
                style: TextStyle(color: M.sageDark, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 12),
              settingsTextField('接口地址', st.ocrBaseUrl, (v) => st.ocrBaseUrl = v),
              KeyField(label: 'OCR 密钥（留空则使用出题模型的密钥）', load: st.ocrKeyRaw, save: st.setOcrKey),
            ]),
          ),
        if (st.ocrProvider == OcrProvider.kimi)
          Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Kimi 文件解析', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('上传后由 Kimi 抽取文字（目前免费），支持 PDF 和 Word。PDF 每批的文字会记在该批首页；Word 按标题切成小节。', style: TextStyle(color: M.sub, fontSize: 12)),
              const SizedBox(height: 12),
              settingsTextField('接口地址', st.kimiBaseUrl, (v) => st.kimiBaseUrl = v),
              KeyField(label: 'Kimi API 密钥', load: st.kimiKey, save: st.setKimiKey),
            ]),
          ),
        if (st.ocrProvider == OcrProvider.local)
          Glass(
              child: Text('直接读取 PDF 自带的文字层，不花钱、不联网；扫描版 PDF 没有文字层，读不出内容，公式也可能变成普通字符。不支持 Word：上传的 Word 会提示切换到 DeepSeek OCR 或 Kimi。',
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
        const SizedBox(height: 12),
        const ConcurrencyCard(),
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
        Text('可直接修改发给 AI 的完整提示词。{{...}} 是占位符，会被自动替换，请保留。',
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

/// 「并发数」：同时发出的联网请求上限（OCR 分批、知识点分析、出题分批共用）。
class ConcurrencyCard extends StatefulWidget {
  const ConcurrencyCard({super.key});
  static const docUrl = 'https://api-docs.deepseek.com/zh-cn/quick_start/rate_limit';
  @override
  State<ConcurrencyCard> createState() => _ConcurrencyCardState();
}

class _ConcurrencyCardState extends State<ConcurrencyCard> {
  @override
  Widget build(BuildContext context) {
    final st = context.read<AppState>().settings;
    return Glass(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        NumberStepper(
          label: '并发数',
          value: st.concurrency,
          min: minConcurrency,
          max: maxConcurrency,
          step: 1,
          dialogTitle: '并发数（$minConcurrency–$maxConcurrency）',
          hint: 'deepseek-flash 每账号最多 2500 并发，deepseek-v4-pro 最多 500。',
          onChanged: (v) => setState(() => st.concurrency = v),
        ),
        Text(
            '同时发出的请求数：PDF 分批解析、知识点分析和出题分批共用，多份资料同时解析也共用这一个上限。'
            '默认 $defaultConcurrency；设为 1 时逐批依次处理（与旧版相同）。点数字可直接输入。',
            style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
        const SizedBox(height: 6),
        Text(
            'DeepSeek 官方文档：每个账号的并发上限 deepseek-flash 为 2500、deepseek-v4-pro 为 500，'
            '超出会返回 429（请求过多），应用会自动退避后重试。其他服务商请按其限制设置。',
            style: TextStyle(color: M.sageDark, fontSize: 12, height: 1.5)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            onPressed: () => launchUrl(Uri.parse(ConcurrencyCard.docUrl), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('查看 DeepSeek 限速说明'),
          ),
        ),
      ]),
    );
  }
}
