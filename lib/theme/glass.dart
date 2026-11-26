import 'package:flutter/services.dart';

import 'package:material_ui/material_ui.dart';

import '../desktop/platform.dart';


export 'rich_text.dart';


/// 莫兰迪配色。浅色 / 深色两套，切换外观时由 [M.apply] 整体替换。
class M {
  static bool dark = false;
  static Color bg = const Color(0xFFECE8E2); // 燕麦底
  static Color mist = const Color(0xFFD5D3CF); // 雾灰
  static Color greyBlue = const Color(0xFFA3B1BD); // 灰蓝
  static Color oat = const Color(0xFFD9CBB4); // 燕麦
  static Color sage = const Color(0xFF8FA68B); // 灰绿（强调色）
  static Color sageDark = const Color(0xFF66805F);
  static Color rose = const Color(0xFFC79B9B); // 豆沙（错误）
  static Color roseDark = const Color(0xFFA86F6F);
  static Color text = const Color(0xFF3E3C39); // 深灰文字
  static Color sub = const Color(0xFF7D7973);
  static Color sheet = const Color(0xFFF4F1EC); // 面板、对话框底色
  static Color glass = Colors.white; // 玻璃面板底色
  static double glassAlpha = 1; // 玻璃不透明度系数
  static Color line = Colors.white; // 玻璃描边
  static Color wordBlue = const Color(0xFF6F8296);

  /// 触感反馈开关（外观设置）。
  static bool haptics = true;

  static void apply(bool isDark) {
    dark = isDark;
    if (!isDark) {
      bg = const Color(0xFFECE8E2);
      mist = const Color(0xFFD5D3CF);
      greyBlue = const Color(0xFFA3B1BD);
      oat = const Color(0xFFD9CBB4);
      sage = const Color(0xFF8FA68B);
      sageDark = const Color(0xFF66805F);
      rose = const Color(0xFFC79B9B);
      roseDark = const Color(0xFFA86F6F);
      text = const Color(0xFF3E3C39);
      sub = const Color(0xFF7D7973);
      sheet = const Color(0xFFF4F1EC);
      glass = Colors.white;
      glassAlpha = 1;
      line = Colors.white;
      wordBlue = const Color(0xFF6F8296);
    } else {
      // 深色莫兰迪：炭灰底，低饱和的灰绿 / 豆沙 / 燕麦
      bg = const Color(0xFF22252A);
      mist = const Color(0xFF3A3D42);
      greyBlue = const Color(0xFF55636F);
      oat = const Color(0xFF6B604F);
      sage = const Color(0xFF7E9579);
      sageDark = const Color(0xFFA9C1A3);
      rose = const Color(0xFF9E7676);
      roseDark = const Color(0xFFD9A7A7);
      text = const Color(0xFFE7E2DA);
      sub = const Color(0xFFA29D95);
      sheet = const Color(0xFF2C3035);
      glass = const Color(0xFF3A3F45);
      glassAlpha = 1.2;
      line = const Color(0xFF545A61);
      wordBlue = const Color(0xFF9DB0C4);
    }
  }
}

ThemeData buildTheme({String? fontFamily, bool reduceMotion = false}) {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    colorScheme: ColorScheme.fromSeed(
        seedColor: M.sage, brightness: M.dark ? Brightness.dark : Brightness.light, surface: M.bg, primary: M.sageDark, error: M.roseDark),
    scaffoldBackgroundColor: Colors.transparent,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: M.text, displayColor: M.text, fontFamily: fontFamily),
    appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent, elevation: 0, foregroundColor: M.text, centerTitle: true, scrolledUnderElevation: 0),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: M.glass.withValues(alpha: M.dark ? 0.55 : 0.5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: M.glass.withValues(alpha: M.dark ? 0.6 : 0.45),
      selectedColor: M.sage.withValues(alpha: 0.35),
      side: BorderSide(color: M.line.withValues(alpha: 0.8)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: TextStyle(color: M.text, fontFamily: fontFamily),
    ),
    dividerColor: M.line.withValues(alpha: 0.6),
    dialogTheme: DialogThemeData(backgroundColor: M.sheet, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
    popupMenuTheme: PopupMenuThemeData(color: M.sheet, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    snackBarTheme: SnackBarThemeData(backgroundColor: M.text, contentTextStyle: TextStyle(color: M.bg, fontFamily: fontFamily)),
    // 统一的页面切换动画；「减弱动画」时直接切换
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      for (final p in TargetPlatform.values)
        p: reduceMotion ? const _NoTransition() : const FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      child;
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
    final base = tint ?? M.glass;
    final k = tint == null ? M.glassAlpha : 1.0;
    final hi = ((tint == null ? opacity + 0.16 : 0.66) * k).clamp(0.0, 1.0);
    final lo = ((tint == null ? opacity - 0.06 : 0.48) * k).clamp(0.0, 1.0);
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [base.withValues(alpha: hi), base.withValues(alpha: lo)],
          ),
          border: Border.all(color: M.line.withValues(alpha: M.dark ? 0.6 : 0.8), width: 1),
          boxShadow: [
            BoxShadow(color: const Color(0xFF6B6259).withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 5)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap == null ? null : () {
              tapFeedback();
              onTap!();
            },
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
///
/// 桌面版改成居中对话框；[side] 为 true 时改成右侧栏（AI 解释、原文、伴学这类边看边用的内容）。
Future<T?> showGlassSheet<T>(BuildContext context, Widget Function(BuildContext, ScrollController) builder,
    {double initial = 0.55, double maxSize = 0.92, bool side = false}) {
  if (Desk.active) return showDesktopPanel<T>(context, builder, side: side, initial: initial);
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
              color: M.sheet, // 不透明：避免底层文字透出
              border: Border(top: BorderSide(color: M.line.withValues(alpha: 0.9))),
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

/// 只有几个选项的小菜单：手机从底部弹出，桌面显示成居中的小对话框。
Future<T?> showMenuSheet<T>(BuildContext context, WidgetBuilder builder) {
  if (!Desk.active) return showModalBottomSheet<T>(context: context, backgroundColor: M.sheet, builder: builder);
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    builder: (ctx) => Dialog(
      backgroundColor: M.sheet,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: builder(ctx)),
      ),
    ),
  );
}

/// 桌面版的面板：居中对话框，或从右侧滑出的侧栏。内容和手机面板完全一样。
Future<T?> showDesktopPanel<T>(BuildContext context, Widget Function(BuildContext, ScrollController) builder,
    {bool side = false, double initial = 0.55}) {
  if (side) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black.withValues(alpha: 0.12),
      transitionDuration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 220),
      pageBuilder: (ctx, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: 480,
            height: double.infinity,
            child: _DesktopPanel(builder: builder),
          ),
        ),
      ),
      transitionBuilder: (ctx, a, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0.25, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: FadeTransition(opacity: a, child: child),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    builder: (ctx) {
      final h = MediaQuery.of(ctx).size.height;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 640,
            height: (h * (initial < 0.6 ? 0.6 : initial)).clamp(320.0, h - 48),
            child: _DesktopPanel(builder: builder),
          ),
        ),
      );
    },
  );
}

class _DesktopPanel extends StatefulWidget {
  final Widget Function(BuildContext, ScrollController) builder;
  const _DesktopPanel({required this.builder});
  @override
  State<_DesktopPanel> createState() => _DesktopPanelState();
}

class _DesktopPanelState extends State<_DesktopPanel> {
  final sc = ScrollController();
  @override
  void dispose() {
    sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
        color: M.sheet,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24), side: BorderSide(color: M.line.withValues(alpha: 0.9))),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 6, 0),
              child: IconButton(
                tooltip: '关闭（Esc）',
                icon: Icon(Icons.close_rounded, color: M.sub, size: 20),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          Expanded(child: widget.builder(context, sc)),
        ]),
      );
}

/// 轻触反馈：所有玻璃卡片 / 按钮共用，可在设置里关闭。
void tapFeedback() {
  if (M.haptics) HapticFeedback.selectionClick();
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
          Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: M.text)),
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
  /// 桌面上内容的最大宽度。
  final double deskMax;
  const GlassScaffold(
      {super.key, this.title, required this.body, this.actions, this.leading, this.titleWidget, this.deskMax = 1000});
  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      appBar: (title == null && titleWidget == null)
          ? null
          : AppBar(
              title: titleWidget ?? Text(title!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
              centerTitle: Desk.active ? false : null,
              actions: actions,
              leading: leading),
      body: body,
    );
    // 桌面：内容限制在合适的宽度里居中，不被拉成通栏
    return BlobBackground(child: Desk.active ? DeskWidth(max: deskMax, child: scaffold) : scaffold);
  }
}

/// 桌面主区的内容宽度：居中，最宽 [max]。
class DeskWidth extends StatelessWidget {
  final Widget child;
  final double max;
  const DeskWidth({super.key, required this.child, this.max = 1000});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: max), child: child),
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
