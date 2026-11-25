import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/latex_text.dart' show repairTex;
import '../services/pdf_export.dart';

/// 用 flutter_math_fork 在屏幕外把公式画成 PNG（和应用里看到的排版一致），给 PDF 导出用。
class FlutterMathRasterizer implements MathRasterizer {
  final double pixelRatio;
  final String? fontFamily;
  final _cache = <String, RasterMath?>{};
  FlutterMathRasterizer({this.pixelRatio = 4, this.fontFamily});

  @override
  Future<RasterMath?> render(String tex, {required bool display, required double fontSize}) async {
    final key = '$display|$fontSize|$tex';
    if (_cache.containsKey(key)) return _cache[key];
    var failed = false;
    Widget build(String src, Widget Function(FlutterMathException) onError) => Math.tex(
          src,
          mathStyle: display ? MathStyle.display : MathStyle.text,
          textStyle: TextStyle(fontSize: fontSize, color: const Color(0xFF3E3C39), fontFamily: fontFamily),
          onErrorFallback: onError,
        );
    final w = build(tex, (e) {
      final fixed = repairTex(tex);
      if (fixed == tex) {
        failed = true;
        return const SizedBox();
      }
      return build(fixed, (_) {
        failed = true;
        return const SizedBox();
      });
    });
    final r = await renderWidgetToPng(w, pixelRatio: pixelRatio);
    final out = failed || r == null || r.width < 0.5 ? null : r;
    _cache[key] = out;
    return out;
  }
}

/// 屏幕外渲染一个小部件，返回 PNG 和尺寸、基线（逻辑像素）。
Future<RasterMath?> renderWidgetToPng(Widget widget, {double pixelRatio = 4, double maxWidth = 2000}) async {
  final boundary = RenderRepaintBoundary();
  final probe = _Probe();
  final view = ui.PlatformDispatcher.instance.implicitView ?? ui.PlatformDispatcher.instance.views.first;
  final renderView = RenderView(
    view: view,
    child: RenderPositionedBox(alignment: Alignment.topLeft, child: boundary),
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 4000),
      physicalConstraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 4000),
      devicePixelRatio: 1,
    ),
  );
  final pipeline = PipelineOwner()..rootNode = renderView;
  renderView.prepareInitialFrame();
  final buildOwner = BuildOwner(focusManager: FocusManager());
  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
          textDirection: TextDirection.ltr,
          child: Material(type: MaterialType.transparency, child: _BaselineProbe(probe, child: widget))),
    ),
  ).attachToRenderTree(buildOwner);
  buildOwner.buildScope(root);
  buildOwner.finalizeTree();
  pipeline.flushLayout();
  pipeline.flushCompositingBits();
  pipeline.flushPaint();
  final size = boundary.size;
  if (size.isEmpty) return null;
  final base = probe.baseline ?? size.height * 0.8;
  final img = await boundary.toImage(pixelRatio: pixelRatio);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  if (data == null) return null;
  return RasterMath(data.buffer.asUint8List(), size.width, size.height, base);
}

class _Probe {
  double? baseline;
}

/// 在布局时读出子部件的基线（布局结束后不能再查询）。
class _BaselineProbe extends SingleChildRenderObjectWidget {
  final _Probe probe;
  const _BaselineProbe(this.probe, {super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBaselineProbe(probe);
}

class _RenderBaselineProbe extends RenderProxyBox {
  final _Probe probe;
  _RenderBaselineProbe(this.probe);
  @override
  void performLayout() {
    super.performLayout();
    probe.baseline = child?.getDistanceToBaseline(TextBaseline.alphabetic);
  }
}
