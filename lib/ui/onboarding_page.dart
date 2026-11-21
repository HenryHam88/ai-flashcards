import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme/glass.dart';
import 'me_page.dart';

/// 首次启动引导：三页，随时可跳过。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final pc = PageController();
  int page = 0;

  void _done() {
    final s = context.read<AppState>();
    s.settings.onboarded = true;
    s.changed(); // MaterialApp 重建后进入主页
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _Slide(
        hero: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: Image.asset('assets/logo.png', width: 120, height: 120,
              errorBuilder: (_, _, _) => Icon(Icons.style_rounded, size: 100, color: M.sageDark)),
        ),
        title: '欢迎使用闪卡刷题',
        body: '把课本、讲义、复习资料（PDF / Word）\n交给 AI，自动变成闪卡和练习题。',
      ),
      _Slide(
        hero: Column(children: [
          for (final (i, t, d) in [
            (Icons.upload_file_rounded, '上传资料', 'PDF、Word，公式和表格都能识别'),
            (Icons.auto_awesome_rounded, 'AI 提炼知识点', '按章节生成闪卡与选择 / 填空 / 简答题'),
            (Icons.event_repeat_rounded, '科学复习', 'FSRS 记忆算法安排每天该复习什么'),
            (Icons.bookmark_border_rounded, '错题回炉', '做错自动进错题本，随时重做'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  Icon(i, color: M.sageDark),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(d, style: TextStyle(color: M.sub, fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
            ),
        ]),
        title: '怎么用',
        body: '',
      ),
      _Slide(
        hero: Icon(Icons.key_rounded, size: 84, color: M.sageDark),
        title: '准备一个 API 密钥',
        body: '出题和解释需要一个兼容 OpenAI 格式的大模型接口（如 DeepSeek）。密钥只保存在本机的系统安全存储中。',
        extra: Padding(
          padding: const EdgeInsets.only(top: 18),
          child: GlassButton(
            label: '现在去填写',
            icon: Icons.smart_toy_outlined,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LlmSettingsPage())),
          ),
        ),
      ),
    ];
    final last = page == pages.length - 1;
    return BlobBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _done, child: Text('跳过', style: TextStyle(color: M.sub))),
            ),
            Expanded(
              child: PageView(
                controller: pc,
                onPageChanged: (i) => setState(() => page = i),
                children: pages,
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < pages.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == page ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: i == page ? M.sageDark : M.sub.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(4)),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: GlassButton(
                label: last ? '开始使用' : '下一步',
                tint: M.sage,
                expand: true,
                onTap: last
                    ? _done
                    : () => pc.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Slide extends StatelessWidget {
  final Widget hero;
  final String title;
  final String body;
  final Widget? extra;
  const _Slide({required this.hero, required this.title, required this.body, this.extra});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(children: [
          const SizedBox(height: 40),
          if (body.isEmpty) ...[
            // 列表型页面：标题在上
            Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 24),
            hero,
          ] else ...[
            hero,
            const SizedBox(height: 28),
            Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          ],
          if (body.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(body, textAlign: TextAlign.center, style: TextStyle(color: M.sub, fontSize: 15, height: 1.7)),
          ],
          ?extra,
        ]),
      );
}
