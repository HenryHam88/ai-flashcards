import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// 本地 PDF 工具：统计页数、按页码拆分、提取文字层（全部放到后台 isolate）。
class PdfTools {
  static Future<int> pageCount(Uint8List bytes) => compute(_pageCount, bytes);
  static int _pageCount(Uint8List bytes) {
    final d = PdfDocument(inputBytes: bytes);
    final n = d.pages.count;
    d.dispose();
    return n;
  }

  /// 拆出 [from, to]（1 起始、闭区间）页，返回新的 PDF 字节。
  static Future<Uint8List> slice(Uint8List bytes, int from, int to) =>
      compute(_slice, (bytes, from, to));
  static Uint8List _slice((Uint8List, int, int) a) {
    final d = PdfDocument(inputBytes: a.$1);
    final total = d.pages.count;
    for (var i = total - 1; i >= 0; i--) {
      if (i < a.$2 - 1 || i > a.$3 - 1) d.pages.removeAt(i);
    }
    final out = Uint8List.fromList(d.saveSync());
    d.dispose();
    // 删页不会删掉别的页的图片等资源：扫描版 PDF 拆出 30 页，文件大小可能还是整本那么大，
    // 每批都上传整本，既慢又容易超过 100 MiB 的单批上限。这时改为只把需要的页复制到新文件里。
    final kept = a.$3 - a.$2 + 1;
    if (out.length > sliceRebuildThreshold && kept < total) {
      try {
        final rebuilt = _rebuild(a.$1, a.$2, a.$3);
        if (rebuilt != null && rebuilt.length < out.length * 0.8) return rebuilt;
      } catch (_) {}
    }
    return out;
  }

  /// 超过这个大小才尝试重建（小文件没必要，也避免改动页面内容）。
  static const sliceRebuildThreshold = 8 * 1024 * 1024;

  /// 把 [from, to] 页作为模板画到新文件里，只带走这些页用到的资源。
  /// 带旋转的页面保持用原来的方式（返回 null）。
  static Uint8List? _rebuild(Uint8List bytes, int from, int to) {
    final src = PdfDocument(inputBytes: bytes);
    try {
      for (var i = from - 1; i <= to - 1 && i < src.pages.count; i++) {
        if (src.pages[i].rotation != PdfPageRotateAngle.rotateAngle0) return null;
      }
      final out = PdfDocument();
      out.pageSettings.margins.all = 0;
      for (var i = from - 1; i <= to - 1 && i < src.pages.count; i++) {
        final sp = src.pages[i];
        out.pageSettings.size = sp.size;
        out.pages.add().graphics.drawPdfTemplate(sp.createTemplate(), Offset.zero);
      }
      final r = Uint8List.fromList(out.saveSync());
      out.dispose();
      return r;
    } finally {
      src.dispose();
    }
  }

  /// PDF 书签（目录大纲）：返回 (标题, 页码 1 起始, 层级 0 起始)。没有书签时为空。
  static Future<List<(String, int, int)>> outline(Uint8List bytes) => compute(_outline, bytes);
  static List<(String, int, int)> _outline(Uint8List bytes) {
    final d = PdfDocument(inputBytes: bytes);
    final out = <(String, int, int)>[];
    void walk(PdfBookmarkBase b, int level) {
      for (var i = 0; i < b.count; i++) {
        final m = b[i];
        final page = m.destination?.page ?? m.namedDestination?.destination?.page;
        if (page != null) {
          final idx = d.pages.indexOf(page);
          if (idx >= 0 && m.title.trim().isNotEmpty) out.add((m.title.trim(), idx + 1, level));
        }
        if (level < 3) walk(m, level + 1);
      }
    }

    walk(d.bookmarks, 0);
    d.dispose();
    return out;
  }

  /// 本地提取 [from,to] 页的文字层（扫描版 PDF 会是空的）。
  static Future<List<String>> extractText(Uint8List bytes, int from, int to) =>
      compute(_extract, (bytes, from, to));
  static List<String> _extract((Uint8List, int, int) a) {
    final d = PdfDocument(inputBytes: a.$1);
    final ex = PdfTextExtractor(d);
    final out = <String>[];
    for (var i = a.$2 - 1; i <= a.$3 - 1 && i < d.pages.count; i++) {
      out.add(ex.extractText(startPageIndex: i, endPageIndex: i));
    }
    d.dispose();
    return out;
  }
}

/// 把总页数切成若干批次（每批 [batch] 页）。
List<(int, int)> pageBatches(int total, int batch) {
  final out = <(int, int)>[];
  for (var s = 1; s <= total; s += batch) {
    out.add((s, (s + batch - 1).clamp(1, total)));
  }
  return out;
}
