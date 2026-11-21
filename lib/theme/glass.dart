
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:material_ui/material_ui.dart';

import '../services/latex.dart';

/// 莫兰迪配色
class M {
  static const bg = Color(0xFFECE8E2); // 燕麦底
  static const mist = Color(0xFFD5D3CF); // 雾灰
  static const greyBlue = Color(0xFFA3B1BD); // 灰蓝
  static const oat = Color(0xFFD9CBB4); // 燕麦
  static const sage = Color(0xFF8FA68B); // 灰绿（强调色）
  static const sageDark = Color(0xFF66805F);
  static const rose = Color(0xFFC79B9B); // 豆沙（错误）
  static const roseDark = Color(0xFFA86F6F);
  static const text = Color(0xFF3E3C39); // 深灰文字
  static const sub = Color(0xFF7D7973);
}

ThemeData buildTheme({String? fontFamily}) {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    colorScheme: ColorScheme.fromSeed(seedColor: M.sage, surface: M.bg, primary: M.sageDark, error: M.roseDark),
    scaffoldBackgroundColor: Colors.transparent,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: M.text, displayColor: M.text, fontFamily: fontFamily),
    appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent, elevation: 0, foregroundColor: M.text, centerTitle: true, scrolledUnderElevation: 0),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.white.withValues(alpha: 0.45),
      selectedColor: M.sage.withValues(alpha: 0.35),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.8)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: TextStyle(color: M.text, fontFamily: fontFamily),
    ),
    dividerColor: Colors.white.withValues(alpha: 0.6),
  );
}

/// 背景：燕麦底 + 几团大的柔和莫兰迪色块。
/// 性能：色块用径向渐变画出「模糊」效果，不做实时高斯模糊；并用 RepaintBoundary 缓存成一层，
/// 滚动时只合成、不重绘。
class BlobBackground extends StatelessWidget {
  final Widget child;
  const BlobBackground({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      const Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _BlobPainter(), isComplex: true))),
      Positioned.fill(child: child),
    ]);
  }
}

class _BlobPainter extends CustomPainter {
  const _BlobPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = M.bg);
    void blob(Offset c, double r, Color color) {
      final rect = Rect.fromCircle(center: c, radius: r);
      canvas.drawRect(
          rect,
          Paint()
            ..shader = RadialGradient(colors: [
              color,
              color.withValues(alpha: color.a * 0.55),
              color.withValues(alpha: 0),
            ], stops: const [0, 0.45, 1])
                .createShader(rect));
    }

    final w = size.width;
    blob(Offset(w * 0.18, 70), 260, M.greyBlue.withValues(alpha: 0.55));
    blob(Offset(w * 1.0, 420), 250, M.rose.withValues(alpha: 0.38));
    blob(Offset(w * 0.4, size.height - 40), 280, M.sage.withValues(alpha: 0.45));
    blob(Offset(w * 0.55, 230), 200, M.oat.withValues(alpha: 0.5));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 玻璃面板：半透明白 + 斜向渐变高光 + 细白描边 + 柔和阴影。
/// 性能：背景本身已是柔和色块，所以默认不做实时 BackdropFilter 模糊（「仿玻璃」），
/// 滚动时零模糊开销；并包一层 RepaintBoundary，列表滚动时卡片只平移不重绘。
/// 少数固定不动的元素（底部导航、底部面板）才使用真实模糊。
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? tint;
  final double opacity;
  final VoidCallback? onTap;
  const Glass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 22,
    this.tint,
    this.opacity = 0.42,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final base = tint ?? Colors.white;
    final hi = tint == null ? opacity + 0.16 : 0.66;
    final lo = tint == null ? opacity - 0.06 : 0.48;
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [base.withValues(alpha: hi), base.withValues(alpha: lo)],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1),
          boxShadow: [
            BoxShadow(color: const Color(0xFF6B6259).withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 5)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: r,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// 玻璃按钮
class GlassButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? tint;
  final Color? fg;
  final bool expand;
  const GlassButton({super.key, required this.label, this.icon, this.onTap, this.tint, this.fg, this.expand = false});
  @override
  Widget build(BuildContext context) {
    final color = fg ?? (tint != null ? Colors.white : M.text);
    final row = Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
      if (icon != null) ...[Icon(icon, size: 20, color: color), const SizedBox(width: 6)],
      Flexible(child: Text(label, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
    ]);
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Glass(radius: 18, tint: tint, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13), onTap: onTap, child: row),
    );
  }
}

/// 半屏毛玻璃底部面板（不跳转页面，关掉后原页面状态完全保留）。
Future<T?> showGlassSheet<T>(BuildContext context, Widget Function(BuildContext, ScrollController) builder,
    {double initial = 0.55, double maxSize = 0.92}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.12),
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: initial,
      minChildSize: 0.3,
      maxChildSize: maxSize,
      expand: false,
      builder: (ctx, sc) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        // 性能：面板里内容可滚动，实时模糊每帧都要重算，这里改用接近不透明的燕麦白
        child: RepaintBoundary(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF4F1EC).withValues(alpha: 0.95),
              border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.9))),
            ),
            child: Column(children: [
              const SizedBox(height: 8),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: M.sub.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(2))),
              Expanded(child: builder(ctx, sc)),
            ]),
          ),
        ),
      ),
    ),
  );
}

/// 公式混排文本：$...$ 行内公式、$$...$$ 独立公式，均用真正的 TeX 排版引擎渲染。
class MathText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  const MathText(this.text, {super.key, this.style, this.textAlign = TextAlign.start});

  @override
  Widget build(BuildContext context) {
    final st = DefaultTextStyle.of(context).style.merge(style);
    final segs = LatexUtil.split(text);
    final blocks = <Widget>[];
    var spans = <InlineSpan>[];
    void flush() {
      if (spans.isEmpty) return;
      blocks.add(Text.rich(TextSpan(children: spans), style: st, textAlign: textAlign));
      spans = [];
    }

    Widget fallback(String tex) => Text(tex, style: st.copyWith(fontFamily: 'monospace', color: M.roseDark));
    for (final s in segs) {
      if (!s.isMath) {
        // 简单支持 **加粗**（AI 解释常用）
        final parts = s.text.split('**');
        for (var k = 0; k < parts.length; k++) {
          if (parts[k].isEmpty) continue;
          spans.add(TextSpan(
              text: parts[k], style: k.isOdd && parts.length > 2 ? const TextStyle(fontWeight: FontWeight.w700) : null));
        }
      } else if (!s.display) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Math.tex(s.text,
              mathStyle: MathStyle.text,
              textStyle: TextStyle(fontSize: (st.fontSize ?? 15) * 1.05, color: st.color),
              onErrorFallback: (e) => fallback(s.text)),
        ));
      } else {
        flush();
        blocks.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Math.tex(s.text,
                  mathStyle: MathStyle.display,
                  textStyle: TextStyle(fontSize: (st.fontSize ?? 15) * 1.1, color: st.color),
                  onErrorFallback: (e) => fallback(s.text)),
            ),
          ),
        ));
      }
    }
    flush();
    if (segs.every((e) => !e.isMath)) {
      return blocks.isEmpty ? const SizedBox() : blocks.first;
    }
    // 公式排版较重：单独成层，滚动时不重绘
    if (blocks.length == 1) return RepaintBoundary(child: blocks.first);
    return RepaintBoundary(child: Column(
      crossAxisAlignment: textAlign == TextAlign.center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    ));
  }
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    behavior: SnackBarBehavior.floating,
    backgroundColor: M.text.withValues(alpha: 0.88),
  ));
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(children: [
          Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: M.text)),
          const Spacer(),
          ?trailing,
        ]),
      );
}

/// 带模糊背景的页面骨架
class GlassScaffold extends StatelessWidget {
  final String? title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? leading;
  final Widget? titleWidget;
  const GlassScaffold({super.key, this.title, required this.body, this.actions, this.leading, this.titleWidget});
  @override
  Widget build(BuildContext context) => BlobBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: (title == null && titleWidget == null)
              ? null
              : AppBar(
                  title: titleWidget ?? Text(title!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
                  actions: actions,
                  leading: leading),
          body: body,
        ),
      );
}

/// 项目筛选：「全部」+ 每个项目一个玻璃小标签，横向滚动。value 为 null 表示全部。
class ProjectFilterChips extends StatelessWidget {
  final List<(String id, String name)> projects;
  final String? value;
  final ValueChanged<String?> onChanged;
  const ProjectFilterChips({super.key, required this.projects, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    Widget chip(String? id, String label) {
      final sel = value == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Glass(
          radius: 18,
          tint: sel ? M.sage : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          onTap: () => onChanged(id),
          child: Text(label,
              style: TextStyle(color: sel ? Colors.white : M.text, fontSize: 13, fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
        ),
      );
    }

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        children: [chip(null, '全部'), for (final p in projects) chip(p.$1, p.$2)],
      ),
    );
  }
}
