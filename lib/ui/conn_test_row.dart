import 'package:material_ui/material_ui.dart';

import '../services/conn_test.dart';
import '../theme/glass.dart';

/// 「测试」按钮：点一下发一个很小的请求，下面写成功，或者具体原因。
/// [reset] 通知时清掉上一次的结果（输入框改了，结果就不算数了）。
class ConnTestRow extends StatefulWidget {
  final Future<TestResult> Function() run;
  final String label;
  final Listenable? reset;
  const ConnTestRow({super.key, required this.run, this.label = '测试', this.reset});
  @override
  State<ConnTestRow> createState() => _ConnTestRowState();
}

class _ConnTestRowState extends State<ConnTestRow> {
  bool running = false;
  TestResult? result;

  @override
  void initState() {
    super.initState();
    widget.reset?.addListener(_clear);
  }

  @override
  void dispose() {
    widget.reset?.removeListener(_clear);
    super.dispose();
  }

  void _clear() {
    if (result != null && !running && mounted) setState(() => result = null);
  }

  Future<void> _go() async {
    setState(() {
      running = true;
      result = null;
    });
    TestResult r;
    try {
      r = await widget.run();
    } catch (e) {
      r = TestResult.fail('测试失败：$e');
    }
    if (!mounted) return;
    setState(() {
      running = false;
      result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GlassButton(
        label: running ? '正在测试…' : widget.label,
        icon: Icons.network_check_rounded,
        expand: true,
        onTap: running ? null : _go,
      ),
      if (r != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(r.ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded, size: 18, color: r.ok ? M.sageDark : M.roseDark),
            const SizedBox(width: 6),
            Expanded(
              child: Text(r.message, style: TextStyle(fontSize: 13, height: 1.5, color: r.ok ? M.sageDark : M.roseDark)),
            ),
          ]),
        ),
    ]);
  }
}
