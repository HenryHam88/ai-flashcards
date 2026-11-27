import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/ocr.dart';
import 'package:ai_flashcards/services/pdf_tools.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

/// 随机噪点的 PNG（压不小），模拟扫描版 PDF 每页一张大图。
Uint8List noisePng(int w, int h, Random r) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    raw.add(List.generate(w * 3, (_) => r.nextInt(256)));
  }
  final out = BytesBuilder();
  void chunk(String t, List<int> d) {
    out.add((ByteData(4)..setUint32(0, d.length)).buffer.asUint8List());
    final td = [...t.codeUnits, ...d];
    out.add(td);
    var c = 0xffffffff;
    for (final b in td) {
      c ^= b;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (c >> 1) ^ 0xedb88320 : c >> 1;
      }
    }
    out.add((ByteData(4)..setUint32(0, c ^ 0xffffffff)).buffer.asUint8List());
  }

  out.add([137, 80, 78, 71, 13, 10, 26, 10]);
  chunk('IHDR', (ByteData(13)..setUint32(0, w)..setUint32(4, h)..setUint8(8, 8)..setUint8(9, 2)).buffer.asUint8List());
  chunk('IDAT', zlib.encode(raw.toBytes()));
  chunk('IEND', []);
  return out.toBytes();
}

Future<Uint8List> scanPdf(int pages) async {
  final r = Random(7);
  final d = sf.PdfDocument();
  d.pageSettings.margins.all = 0;
  for (var i = 0; i < pages; i++) {
    d.pages.add().graphics.drawImage(sf.PdfBitmap(noisePng(500, 400, r)), const Rect.fromLTWH(0, 0, 500, 400));
  }
  final b = Uint8List.fromList(await d.save());
  d.dispose();
  return b;
}

class AlwaysFail implements PdfParser {
  @override
  Future<OcrResult> parse(Uint8List pdfBytes, String fileName, int pageCount) async =>
      throw OcrException('OCR 请求失败（400）：file too large');
}

void main() {
  test('扫描版 PDF 拆出的一批只含这几页的图片，不再是整本大小', () async {
    final bytes = await scanPdf(40); // 约 24 MB
    expect(bytes.length, greaterThan(PdfTools.sliceRebuildThreshold));
    final part = await PdfTools.slice(bytes, 11, 20);
    expect(await PdfTools.pageCount(part), 10);
    expect(part.length, lessThan(bytes.length * 0.4));
    expect(part.length, greaterThan(bytes.length * 0.15)); // 图片确实带上了
    final last = await PdfTools.slice(bytes, 31, 40);
    expect(await PdfTools.pageCount(last), 10);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('小文件的拆分方式不变，页数正确', () async {
    final d = sf.PdfDocument();
    for (var i = 0; i < 12; i++) {
      d.pages.add().graphics.drawString('第$i页', sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 14),
          bounds: const Rect.fromLTWH(10, 10, 100, 20));
    }
    final bytes = Uint8List.fromList(await d.save());
    d.dispose();
    final part = await PdfTools.slice(bytes, 3, 5);
    expect(await PdfTools.pageCount(part), 3);
  });

  test('某一批最终失败时，进度信息里带上失败原因', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository(MemoryDocStore());
    final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    settings.ocrProvider = OcrProvider.deepseek;
    settings.ocrBatchPages = 5;
    final pdf = sf.PdfDocument();
    for (var i = 0; i < 3; i++) {
      pdf.pages.add();
    }
    final dir = await Directory.systemTemp.createTemp('slice');
    final f = File('${dir.path}/a.pdf')..writeAsBytesSync(await pdf.save());
    pdf.dispose();
    final doc = PdfDoc(id: 'd', projectId: 'p', name: '资料', path: f.path);
    final msgs = <String>[];
    final failed = await ParseService(repo, settings, parserOverride: AlwaysFail()).parseDoc(doc, (m, _) => msgs.add(m));
    expect(failed, 1);
    expect(msgs.last, contains('1 批失败'));
    expect(msgs.last, contains('第 1–3 页'));
    expect(msgs.last, contains('file too large'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
