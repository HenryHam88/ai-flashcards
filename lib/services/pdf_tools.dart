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
    for (var i = d.pages.count - 1; i >= 0; i--) {
      if (i < a.$2 - 1 || i > a.$3 - 1) d.pages.removeAt(i);
    }
    final out = Uint8List.fromList(d.saveSync());
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
