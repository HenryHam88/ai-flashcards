import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class OcrException implements Exception {
  final String message;
  OcrException(this.message);
  @override
  String toString() => message;
}

class OcrPage {
  final int index; // 批次内序号（0 起）
  final String text;
  final String finishReason;
  const OcrPage(this.index, this.text, [this.finishReason = '']);
}

class OcrResult {
  final int pageCount;
  final List<OcrPage> pages;
  const OcrResult(this.pageCount, this.pages);
}

/// OCR 输出清理工具。
class OcrText {
  // 同时兼容全角 ｜ 和半角 |
  static const _bar = r'[｜|]';
  static final _refBox = RegExp('<${_bar}ref$_bar>([\\s\\S]*?)<$_bar/ref$_bar>\\s*'
      '<$_bar(?:box|det)$_bar>[\\s\\S]*?<$_bar/(?:box|det)$_bar>');
  static final _strayTag = RegExp('<$_bar/?(?:ref|box|det|grounding|image)$_bar>');
  static final _strayCoords = RegExp(r'\[\[\s*\d+(?:\s*,\s*\d+){3}\s*\]\]');

  /// 去掉 <｜ref｜>…<｜/ref｜><｜box｜>[[..]]<｜/box｜> 等定位标记。
  /// ref 里若是版面类型（text/title/image 等）整体删除；插图留下「[插图]」占位。
  static String clean(String s) {
    var r = s.replaceAllMapped(_refBox, (m) {
      final label = m[1]!.trim().toLowerCase();
      if (label == 'image' || label == 'figure') return '[插图]\n';
      return '';
    });
    r = r.replaceAll(_strayTag, '').replaceAll(_strayCoords, '');
    r = r.replaceAll(RegExp(r'[ \t]+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return r.trim();
  }

  /// 解析 DeepSeek OCR 响应：可能带前导换行，然后是 JSON。
  static OcrResult parseDeepSeek(String body) {
    final start = body.indexOf('{');
    if (start < 0) throw OcrException('OCR 响应不是 JSON');
    final j = jsonDecode(body.substring(start)) as Map<String, dynamic>;
    if (j['error'] != null) throw OcrException('OCR 错误：${j['error']}');
    final pages = ((j['pages'] as List?) ?? []).map((p) {
      final m = (p as Map).cast<String, dynamic>();
      return OcrPage((m['index'] as num?)?.toInt() ?? 0, clean((m['text'] ?? '').toString()),
          (m['finish_reason'] ?? '').toString());
    }).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return OcrResult((j['page_count'] as num?)?.toInt() ?? pages.length, pages);
  }
}

abstract class PdfParser {
  /// 解析一个批次的 PDF（已在本地拆好），返回该批次每页文字。
  Future<OcrResult> parse(Uint8List pdfBytes, String fileName, int pageCount);
}

class DeepSeekOcr implements PdfParser {
  static const maxBytes = 100 * 1024 * 1024;
  static const maxPages = 1000;
  final String baseUrl;
  final String apiKey;
  final String purpose; // text_recognition | rich_layout_recognition
  final http.Client client;
  DeepSeekOcr({required this.baseUrl, required this.apiKey, required this.purpose, http.Client? client})
      : client = client ?? http.Client();

  @override
  Future<OcrResult> parse(Uint8List pdfBytes, String fileName, int pageCount) async {
    if (apiKey.isEmpty) throw OcrException('还没有填写 DeepSeek 密钥');
    if (pdfBytes.length > maxBytes) throw OcrException('单批文件超过 100 MiB');
    if (pageCount > maxPages) throw OcrException('单批超过 1000 页');
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/v1')) b = b.substring(0, b.length - 3);
    final req = http.MultipartRequest('POST', Uri.parse('$b/v1/tools/ocr'))
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['purpose'] = purpose
      ..files.add(http.MultipartFile.fromBytes('file', pdfBytes, filename: fileName));
    try {
      final streamed = await client.send(req).timeout(const Duration(seconds: 180));
      final body = await streamed.stream.bytesToString(utf8).timeout(const Duration(seconds: 180));
      if (streamed.statusCode == 401) throw OcrException('DeepSeek 密钥无效（401）');
      if (streamed.statusCode != 200) throw OcrException('OCR 请求失败（${streamed.statusCode}）：$body');
      return OcrText.parseDeepSeek(body);
    } on TimeoutException {
      throw OcrException('OCR 超时（180 秒），可在设置里调小每批页数');
    }
  }
}

/// Kimi 文件解析：上传 purpose=file-extract，再取回内容。整批返回一段文字，按页数平均无法精确，
/// 因此把整批文字记在批次首页，并标注页码范围。
class KimiFileExtract implements PdfParser {
  final String baseUrl;
  final String apiKey;
  final http.Client client;
  KimiFileExtract({required this.baseUrl, required this.apiKey, http.Client? client})
      : client = client ?? http.Client();

  @override
  Future<OcrResult> parse(Uint8List pdfBytes, String fileName, int pageCount) async {
    if (apiKey.isEmpty) throw OcrException('还没有填写 Kimi 密钥');
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    final up = http.MultipartRequest('POST', Uri.parse('$b/files'))
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['purpose'] = 'file-extract'
      ..files.add(http.MultipartFile.fromBytes('file', pdfBytes, filename: fileName));
    final r = await http.Response.fromStream(await client.send(up).timeout(const Duration(seconds: 180)));
    if (r.statusCode != 200) throw OcrException('Kimi 上传失败（${r.statusCode}）：${utf8.decode(r.bodyBytes)}');
    final id = jsonDecode(utf8.decode(r.bodyBytes))['id'];
    final c = await client.get(Uri.parse('$b/files/$id/content'), headers: {'Authorization': 'Bearer $apiKey'});
    // 用完即删，避免占用 Kimi 的文件配额
    unawaited(client.delete(Uri.parse('$b/files/$id'), headers: {'Authorization': 'Bearer $apiKey'}).catchError((_) => http.Response('', 200)));
    if (c.statusCode != 200) throw OcrException('Kimi 取回内容失败（${c.statusCode}）');
    final raw = utf8.decode(c.bodyBytes);
    String text;
    try {
      text = (jsonDecode(raw)['content'] ?? raw).toString();
    } catch (_) {
      text = raw;
    }
    // 尝试按换页符拆页
    final parts = text.split('\f');
    if (parts.length == pageCount) {
      return OcrResult(pageCount, [for (var i = 0; i < parts.length; i++) OcrPage(i, parts[i].trim())]);
    }
    return OcrResult(pageCount, [for (var i = 0; i < pageCount; i++) OcrPage(i, i == 0 ? text.trim() : '')]);
  }
}
