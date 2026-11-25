import 'dart:async';

import 'package:flutter/services.dart';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../services/llm.dart';
import '../theme/glass.dart';

/// 一次 AI 回答的进行状态：边生成边显示、搜索进度、随时停止。
class AiRun extends ChangeNotifier {
  String text = '';
  String status = '';
  AiCancel? _token;
  Timer? _timer;
  bool get running => _token != null;

  /// 开始一次回答，返回传给 AppState 的回调。
  AiIo start() {
    _token = AiCancel();
    text = '';
    status = '';
    notifyListeners();
    return AiIo(
      cancel: _token,
      onDelta: (t) {
        text = t;
        status = '';
        _schedule();
      },
      onStatus: (st) {
        status = st;
        _schedule();
      },
    );
  }

  // 每 80 ms 最多刷新一次，避免长回答时每个字都重排公式
  void _schedule() {
    if (_timer != null) return;
    _timer = Timer(const Duration(milliseconds: 80), () {
      _timer = null;
      notifyListeners();
    });
  }

  void stop() => _token?.cancel();

  void finish() {
    _timer?.cancel();
    _timer = null;
    _token = null;
    text = '';
    status = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _token?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}

/// 正在生成的回答：已收到的正文 + 状态（正在搜索 / 正在阅读…）+「停止」。
class AiRunView extends StatelessWidget {
  final AiRun run;
  final String idle; // 还没收到正文时的提示
  const AiRunView({super.key, required this.run, this.idle = '正在生成…'});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: run,
      builder: (context, _) {
        if (!run.running) return const SizedBox();
        final status = run.status.isNotEmpty ? run.status : (run.text.isEmpty ? idle : '正在输出…');
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (run.text.isNotEmpty) MathText(stripMetaPreamble(run.text), selectable: true, style: const TextStyle(fontSize: 15, height: 1.6)),
          Row(children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: M.sage)),
            const SizedBox(width: 8),
            Expanded(child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: M.sub, fontSize: 12))),
            TextButton.icon(
              onPressed: run.stop,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('停止'),
              style: TextButton.styleFrom(foregroundColor: M.roseDark),
            ),
          ]),
        ]);
      },
    );
  }
}

/// 回答引用的网页，点一下用浏览器打开。
class WebSourcesView extends StatefulWidget {
  final List<WebSource> sources;
  const WebSourcesView(this.sources, {super.key});
  @override
  State<WebSourcesView> createState() => _WebSourcesViewState();
}

class _WebSourcesViewState extends State<WebSourcesView> {
  bool all = false;
  static const fold = 4;

  @override
  Widget build(BuildContext context) {
    final l = widget.sources;
    if (l.isEmpty) return const SizedBox();
    final shown = all ? l : l.take(fold).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('参考网页 · ${l.length}', style: TextStyle(color: M.sub, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final x in shown)
            Glass(
              radius: 12,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              onTap: () => launchUrl(Uri.parse(x.url), mode: LaunchMode.externalApplication),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.public_rounded, size: 14, color: M.sageDark),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(x.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                ),
              ]),
            ),
          if (l.length > fold)
            Glass(
              radius: 12,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              onTap: () => setState(() => all = !all),
              child: Text(all ? '收起' : '还有 ${l.length - fold} 个', style: TextStyle(fontSize: 12, color: M.sageDark)),
            ),
        ]),
      ]),
    );
  }
}

/// 存在对话记录里的引用来源。
List<WebSource> sourcesOf(Map<String, String> m) => WebSource.decode(m['sources']);

/// 还没收到正文时的提示：说明是否在联网。
String aiIdleText(AppState s, {WebMode? web}) => switch (web ?? s.settings.web()) {
      WebMode.deep => '正在深度搜索并思考…',
      WebMode.normal => '正在联网查找…',
      WebMode.off => '正在生成…',
    };

/// 伴学对话实际使用的联网方式。
WebMode chatWebMode(AppState s, bool? on, String? mode) =>
    s.settings.web(chatOn: on, chatMode: mode == null ? null : (mode == 'normal' ? WebMode.normal : WebMode.deep));

/// 联网方式说明（设置页和伴学里共用）。
const webModeHints = {
  WebMode.deep: '边思考边搜索、打开网页核对，回答更准，等得久一些，用的 Token 也更多',
  WebMode.normal: '需要时搜索一下再回答，更快、更省',
  WebMode.off: '不联网，只依据你的资料和模型自己的知识',
};

String webLabel(WebMode m) => m == WebMode.off ? '不联网' : webModeNames[m]!;

/// 伴学对话的联网选择：null = 跟随全局。
class ChatWebChoice {
  final bool? on;
  final String? mode;
  const ChatWebChoice(this.on, this.mode);
}

/// 伴学顶部的联网小标签：显示当前方式，点开可以单独为这个对话切换。
class WebModeChip extends StatelessWidget {
  final AppState state;
  final bool? on;
  final String? mode;
  final ValueChanged<ChatWebChoice> onChanged;
  final bool enabled;
  const WebModeChip({super.key, required this.state, required this.on, required this.mode, required this.onChanged, this.enabled = true});

  WebMode get current => chatWebMode(state, on, mode);

  @override
  Widget build(BuildContext context) {
    final m = current;
    final off = m == WebMode.off;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Glass(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        onTap: enabled ? () => _pick(context) : null,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(off ? Icons.public_off_rounded : Icons.public_rounded, size: 14, color: off ? M.sub : M.sageDark),
          const SizedBox(width: 4),
          Text(webLabel(m), style: TextStyle(fontSize: 12, color: off ? M.sub : M.sageDark, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final st = state.settings;
    final reason = st.webUnavailable;
    final global = st.webSearch ? st.webMode : WebMode.off;
    final follow = on == null && mode == null;
    Widget tile(BuildContext ctx, String title, String sub, bool selected, ChatWebChoice v) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Opacity(
            opacity: reason == null ? 1 : 0.5,
            child: Glass(
              padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
              onTap: reason == null ? () => Navigator.pop(ctx, v) : null,
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(sub, style: TextStyle(color: M.sub, fontSize: 12)),
                  ]),
                ),
                if (selected) Icon(Icons.check_rounded, color: M.sageDark),
              ]),
            ),
          ),
        );
    final r = await showGlassSheet<ChatWebChoice>(
      context,
      (ctx, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
        const Text('这个对话的联网方式', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(reason ?? '只影响当前对话。全局设置在「我的 → AI 模型」。回答始终以你选的资料为准，网上内容只作补充。',
            style: TextStyle(color: reason == null ? M.sub : M.roseDark, fontSize: 13, height: 1.5)),
        const SizedBox(height: 12),
        tile(ctx, '跟随全局设置（${webLabel(global)}）', '和其他 AI 功能保持一致', follow, const ChatWebChoice(null, null)),
        tile(ctx, '深度搜索', webModeHints[WebMode.deep]!, !follow && on != false && mode != 'normal', const ChatWebChoice(true, 'deep')),
        tile(ctx, '联网搜索', webModeHints[WebMode.normal]!, !follow && on != false && mode == 'normal', const ChatWebChoice(true, 'normal')),
        tile(ctx, '不联网', webModeHints[WebMode.off]!, !follow && on == false, const ChatWebChoice(false, null)),
      ]),
      initial: 0.6,
    );
    if (r != null) onChanged(r);
  }
}

/// 复制到剪贴板并提示「已复制」。
Future<void> copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, '已复制');
}

/// 消息下方的小「复制」按钮，样式与伴学里已有的一致。
class CopyAction extends StatelessWidget {
  final String text;
  const CopyAction(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return TextButton.icon(
      onPressed: () => copyText(context, text),
      icon: const Icon(Icons.copy_rounded, size: 16),
      label: const Text('复制'),
      style: TextButton.styleFrom(foregroundColor: M.sub, visualDensity: VisualDensity.compact),
    );
  }
}

/// 一条对话或 AI 回答：文字可长按选中，下方有「复制」（复制原文，含 Markdown / LaTeX 源码）。
class ChatMessageView extends StatelessWidget {
  final String text;
  final bool user;
  final List<WebSource> sources;
  final List<Widget> actions;
  const ChatMessageView({
    super.key,
    required this.text,
    this.user = false,
    this.sources = const [],
    this.actions = const [],
  });

  String get copySource => user ? text : stripMetaPreamble(text);

  @override
  Widget build(BuildContext context) {
    if (user) {
      return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Align(
          alignment: Alignment.centerRight,
          child: Glass(
            tint: M.greyBlue,
            radius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SelectionArea(child: Text(text, style: const TextStyle(color: Colors.white))),
          ),
        ),
        CopyAction(copySource),
      ]);
    }
    final body = stripMetaPreamble(text);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      MathText(body, selectable: true, style: const TextStyle(fontSize: 15, height: 1.6)),
      WebSourcesView(sources),
      Row(children: [CopyAction(copySource), ...actions]),
    ]);
  }
}
