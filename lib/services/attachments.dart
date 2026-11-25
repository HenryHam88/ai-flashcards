import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models.dart';
import 'latex.dart';
import 'ocr.dart';
import 'pdf_tools.dart';
import 'pipeline.dart';
import 'settings.dart';
import 'text_import.dart';

class AttachmentException implements Exception {
  final String message;
  AttachmentException(this.message);
  @override
  String toString() => message;
}

/// 伴学附件：只抽文字给 AI 看，不加入项目资料、不分章、不出题。
/// 解析方式沿用「文档解析」设置；能在手机上免费读的（TXT、.docx、有文字层的 PDF）先在本地读。
class AttachmentService {
  static const maxFiles = 5; // 每个对话最多几个附件
  static const maxBytes = 20 * 1024 * 1024; // 单个文件上限
  static const maxImageBytes = 8 * 1024 * 1024; // 单张图片上限（拍照 / 相册会先压缩）
  static const storeChars = 20000; // 随对话保存的预览字数；更长的全文另存为 `<附件id>_text.txt`
  // 发给 AI 的附件字数不设固定上限，按模型上下文长度动态计算（见 [plan]）。
  static const charsPerToken = 1.0; // 中文保守按 1 字 ≈ 1 token 估算
  static const replyReserve = 32000; // 给回答（含思考过程）预留的 token
  static const webReserve = 64000; // 联网时给搜索到的网页内容预留的 token
  static const imageTokens = 2000; // 每张图片按这么多 token 估算
  static const safety = 0.10; // 安全余量：上下文的 10%
  static const ocrPages = 20; // 扫描版 PDF 最多识别前几页

  static const docExts = ['pdf', 'docx', 'doc', 'txt'];
  static const imageExts = ['jpg', 'jpeg', 'png', 'webp', 'gif'];

  final Settings settings;
  final ParseService parser;
  AttachmentService(this.settings, this.parser);

  static String ext(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  /// pdf / word / txt / image；不支持时返回 null。
  static String? kindOf(String name) {
    final e = ext(name);
    if (e == 'pdf') return 'pdf';
    if (e == 'docx' || e == 'doc') return 'word';
    if (e == 'txt') return 'txt';
    if (imageExts.contains(e)) return 'image';
    return null;
  }

  static String mimeOf(String name) => switch (ext(name)) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => 'image/jpeg',
      };

  /// 发送前检查：格式、大小、数量。返回不能添加的原因，可以添加时返回 null。
  static String? check(String name, int size, int existing) {
    final kind = kindOf(name);
    if (kind == null) return '「$name」的格式不支持。可以发 PDF、Word、TXT 或图片（JPG / PNG / WebP）。';
    if (existing >= maxFiles) return '一个对话最多 $maxFiles 个附件，可以先删掉不需要的。';
    if (kind == 'image' && size > maxImageBytes) return '「$name」超过 ${maxImageBytes ~/ 1024 ~/ 1024} MB，请用「拍照」或「从相册选择」，会自动压缩。';
    if (size > maxBytes) return '「$name」超过 ${maxBytes ~/ 1024 ~/ 1024} MB，请只保留需要的部分再发。';
    return null;
  }

  /// 抽出文字：返回 (文字, 页数)。文字已整理，没有截断。
  Future<(String, int)> extract(String name, Uint8List bytes, {void Function(String)? onStatus}) async {
    final kind = kindOf(name);
    switch (kind) {
      case 'txt':
        return (cleanImportedText(decodeTextBytes(bytes).text), 0);
      case 'word':
        if (ext(name) == 'docx') {
          final t = docxText(bytes);
          if (t != null && t.trim().isNotEmpty) return (t, 0);
        }
        return (await _remote(name, bytes, 1, onStatus, word: true), 0);
      case 'pdf':
        int pages;
        try {
          pages = await PdfTools.pageCount(bytes);
        } catch (_) {
          throw AttachmentException('「$name」打不开，可能已损坏或有密码。');
        }
        onStatus?.call('正在读取 PDF 文字…');
        var local = '';
        try {
          local = (await PdfTools.extractText(bytes, 1, pages)).map((t) => t.trim()).where((t) => t.isNotEmpty).join('\n\n');
        } catch (_) {}
        // 平均每页不到 50 字，多半是扫描件：交给解析模型识别前几页
        if (local.length >= 50 * pages.clamp(1, 4)) return (LatexUtil.normalize(local), pages);
        final n = pages.clamp(1, ocrPages);
        final part = n < pages ? await PdfTools.slice(bytes, 1, n) : bytes;
        final t = await _remote(name, part, n, onStatus);
        return (n < pages ? '$t\n\n（扫描版 PDF 只识别了前 $n 页，共 $pages 页）' : t, pages);
    }
    throw AttachmentException('「$name」的格式不支持');
  }

  Future<String> _remote(String name, Uint8List bytes, int pages, void Function(String)? onStatus, {bool word = false}) async {
    if (word && !Settings.supportsWord(settings.ocrProvider)) {
      throw AttachmentException('旧版 .doc 需要解析模型：请在「我的 → 文档解析」里选 DeepSeek OCR 或 Kimi，或把文件另存为 .docx 再发。');
    }
    final p = await parser.parserFor(settings.ocrMixed ? Settings.ocrText : settings.ocrModes.first);
    if (p == null) {
      throw AttachmentException('「$name」是扫描版，没有文字层。请在「我的 → 文档解析」里选 DeepSeek OCR 或 Kimi 后再发。');
    }
    onStatus?.call(word ? '正在用解析模型读取 Word…' : '正在识别扫描版 PDF（$pages 页）…');
    try {
      final r = await p.parse(bytes, name, pages);
      return LatexUtil.normalize(r.pages.map((e) => e.text.trim()).where((t) => t.isNotEmpty).join('\n\n'));
    } on OcrException catch (e) {
      throw AttachmentException('解析「$name」失败：${e.message}');
    }
  }

  /// 在手机上直接读 .docx 的正文（word/document.xml），不联网。读不出来返回 null。
  static String? docxText(Uint8List bytes) {
    try {
      final zip = ZipDecoder().decodeBytes(bytes);
      final f = zip.findFile('word/document.xml');
      if (f == null) return null;
      final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
      final t = xml
          .replaceAll(RegExp(r'<w:tab[^>]*/>'), '\t')
          .replaceAll(RegExp(r'<w:br[^>]*/>'), '\n')
          .replaceAll(RegExp(r'</w:p>'), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .replaceAll('&amp;', '&');
      return cleanImportedText(t);
    } catch (_) {
      return null;
    }
  }

  /// 算出这次能发多少附件文字：上下文 ×(1-安全余量) − 回答预留 − 联网预留 − 图片 − 固定部分（系统提示+资料+提问）
  /// − 对话历史。放不下时先丢最早的对话（成对丢），还放不下再截断附件。
  static ContextPlan plan({
    required int context,
    required int fixedChars,
    required List<int> history,
    required int attachChars,
    bool web = false,
    int images = 0,
  }) {
    int tok(int chars) => (chars / charsPerToken).ceil();
    final avail = (context * (1 - safety)).floor() - replyReserve - (web ? webReserve : 0) - images * imageTokens - tok(fixedChars);
    var drop = 0;
    var hist = history.fold<int>(0, (a, b) => a + tok(b));
    while (drop < history.length && avail - hist < tok(attachChars)) {
      final n = (drop + 2 <= history.length) ? 2 : 1;
      for (var i = 0; i < n; i++) {
        hist -= tok(history[drop + i]);
      }
      drop += n;
    }
    final room = ((avail - hist) * charsPerToken).floor();
    return ContextPlan(context: context, attachChars: attachChars, attachSent: room <= 0 ? 0 : (room < attachChars ? room : attachChars), historyDropped: drop);
  }

  /// 把附件文字拼进系统提示，合计不超过 [budget] 字。返回 (文字, 是否有截断)。
  static (String, bool) promptBlock(List<({String name, String text, bool truncated})> docs, {required int budget}) {
    if (docs.isEmpty) return ('', false);
    final b = StringBuffer();
    var left = budget;
    var cut = false;
    for (final d in docs) {
      if (left <= 0) {
        b.writeln('【附件：${d.name}】（篇幅所限没有附上内容）');
        cut = true;
        continue;
      }
      var t = d.text;
      if (t.length > left) {
        t = t.substring(0, left);
        cut = true;
      }
      left -= t.length;
      b.writeln('【附件：${d.name}】');
      b.writeln(t);
      if (t.length < d.text.length || d.truncated) {
        b.writeln('（附件较长，只附上了前一部分）');
        cut = true;
      }
      b.writeln();
    }
    return (b.toString().trim(), cut);
  }
}
