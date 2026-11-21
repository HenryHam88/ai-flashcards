import 'dart:ui';

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
      labelStyle: const TextStyle(color: M.text),
    ),
    dividerColor: Colors.white.withValues(alpha: 0.6),
  );
}

/// 背景：燕麦底 + 几团大的模糊莫兰迪色块，让毛玻璃有东西可「透」。
class BlobBackground extends StatelessWidget {
  final Widget child;
  const BlobBackground({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    Widget blob(Color c, double size) =>
        Container(width: size, height: size, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
    return Container(
      color: M.bg,
      child: Stack(children: [
        Positioned.fill(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
            child: Stack(children: [
              Positioned(top: -60, left: -80, child: blob(M.greyBlue.withValues(alpha: 0.55), 300)),
              Positioned(top: 260, right: -110, child: blob(M.rose.withValues(alpha: 0.40), 280)),
              Positioned(bottom: -80, left: 10, child: blob(M.sage.withValues(alpha: 0.45), 300)),
              Positioned(top: 120, left: 120, child: blob(M.oat.withValues(alpha: 0.6), 220)),
            ]),
          ),
        ),
        Positioned.fill(child: child),
      ]),
    );
  }
}

/// 毛玻璃面板：半透明白 + 背景模糊 + 细白描边 + 柔和阴影。
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
    return Container(
      decoration: BoxDecoration(borderRadius: r, boxShadow: [
        BoxShadow(color: const Color(0xFF6B6259).withValues(alpha: 0.10), blurRadius: 24, offset: const Offset(0, 8)),
      ]),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: r,
              child: Container(
                padding: padding,
                decoration: BoxDecoration(
                  borderRadius: r,
                  color: (tint ?? Colors.white).withValues(alpha: tint == null ? opacity : 0.55),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.75), width: 1),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      (tint ?? Colors.white).withValues(alpha: tint == null ? opacity + 0.12 : 0.62),
                      (tint ?? Colors.white).withValues(alpha: tint == null ? opacity - 0.1 : 0.45),
                    ],
                  ),
                ),
                child: child,
              ),
            ),
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
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF4F1EC).withValues(alpha: 0.82),
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
        spans.add(TextSpan(text: s.text));
      } else if (!s.display) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Math.tex(s.text,
              mathStyle: MathStyle.text,
              textStyle: st.copyWith(fontSize: (st.fontSize ?? 15) * 1.05),
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
                  textStyle: st.copyWith(fontSize: (st.fontSize ?? 15) * 1.1),
                  onErrorFallback: (e) => fallback(s.text)),
            ),
          ),
        ));
      }
    }
    flush();
    if (blocks.length == 1) return blocks.first;
    return Column(
      crossAxisAlignment: textAlign == TextAlign.center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
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
