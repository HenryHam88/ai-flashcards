import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../data/repository.dart';
import '../models.dart';
import 'chapters.dart';
import 'concurrency.dart';
import 'doc_files.dart';
import 'json_utils.dart';
import 'latex.dart';
import 'llm.dart';
import 'ocr.dart';
import 'pdf_tools.dart';
import 'prompts.dart';
import 'quality.dart';
import 'settings.dart';
import 'text_import.dart';

typedef Progress = void Function(String message, double fraction);

// ================= 切块（纯函数，可单测） =================

final _chapterRe = RegExp(r'^\s*(#{1,2}\s*)?(第\s*[一二三四五六七八九十百零〇0-9]+\s*章.*|Chapter\s+\d+.*|CHAPTER\s+\d+.*)$');
final _sectionRe = RegExp(r'^\s*(#{2,3}\s*)?(第\s*[一二三四五六七八九十0-9]+\s*节.*|§\s*\d+(\.\d+)*.*|\d+\.\d+\s+\S.*)$');

final _mdHeadingRe = RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$');

/// Word 文档没有页码：把解析出的整篇文字按标题（Markdown 标题或「第X章 / 1.2 节」）切成小节，
/// 每个小节当作一「页」，过长的小节再按段落切开（每段不超过 [maxChars] 字）。
List<String> splitWordSections(String text, {int maxChars = 3000}) {
  final out = <String>[];
  final buf = StringBuffer();
  void flush() {
    final t = buf.toString().trim();
    if (t.isNotEmpty) out.add(t);
    buf.clear();
  }

  for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
    final l = line.trimRight();
    final isHeading = l.length < 60 && (_mdHeadingRe.hasMatch(l) || _chapterRe.hasMatch(l) || _sectionRe.hasMatch(l));
    if (isHeading || (buf.length > maxChars && l.trim().isEmpty)) flush();
    if (buf.length > maxChars * 1.5) flush(); // 没有空行的超长段落也要切
    buf.writeln(l);
  }
  flush();
  return out;
}

/// 按章节把页文字切成块，每块记录章节名与页码范围；单块过长时再按字数切。
/// [mdHeadings]：Word 文档用 Markdown 标题判断章节——文中最高一级标题当作章，下一级当作节。
/// [chapterOf]：有分章方案时由页码决定章节，文中的章标题不再改变章节，只识别小节。
/// 此时块 id 带内容指纹：内容不变的块沿用已提取的知识点，变化的块重新提取。
List<Chunk> chunkPages(String projectId, String docId, List<PageText> pages,
    {int maxChars = 5000, bool mdHeadings = false, String Function(int page)? chapterOf}) {
  var topLevel = 7;
  if (mdHeadings) {
    for (final p in pages) {
      for (final l in p.text.split('\n')) {
        final m = _mdHeadingRe.firstMatch(l);
        if (m != null && m[1]!.length < topLevel) topLevel = m[1]!.length;
      }
    }
  }
  final out = <Chunk>[];
  var chapter = '未分章';
  var section = '';
  final buf = StringBuffer();
  int? startPage;
  var lastPage = 0;
  void flush() {
    final t = buf.toString().trim();
    if (t.isNotEmpty) {
      out.add(Chunk(
        id: chapterOf == null ? '${docId}_c${out.length}' : '${docId}_c${out.length}_${_fnv(t)}',
        projectId: projectId,
        docId: docId,
        chapter: chapter,
        section: section,
        pageStart: startPage ?? lastPage,
        pageEnd: lastPage,
        text: t,
      ));
    }
    buf.clear();
    startPage = null;
  }

  for (final p in pages) {
    if (chapterOf != null) {
      final ch = chapterOf(p.page);
      if (ch != chapter) {
        flush();
        chapter = ch;
        section = '';
      }
    }
    for (final rawLine in p.text.split('\n')) {
      final line = rawLine.trimRight();
      final md = mdHeadings && line.length < 60 ? _mdHeadingRe.firstMatch(line) : null;
      var isCh = md != null ? md[1]!.length == topLevel : line.length < 40 && _chapterRe.hasMatch(line);
      var isSec = !isCh && (md != null ? md[1]!.length == topLevel + 1 : line.length < 40 && _sectionRe.hasMatch(line));
      if (chapterOf != null) {
        // 章节由方案决定：章标题行只当普通文字，小节照常识别
        if (isCh) {
          isCh = false;
          isSec = false;
        }
      }
      if (isCh || isSec) {
        flush();
        final title = line.replaceFirst(RegExp(r'^\s*#+\s*'), '').trim();
        if (isCh) {
          chapter = title;
          section = '';
        } else {
          section = title;
        }
      }
      if (buf.length > maxChars) flush();
      startPage ??= p.page;
      lastPage = p.page;
      buf.writeln('[第${p.page}页] $line'.replaceFirst(RegExp(r'^\[第\d+页\] $'), ''));
    }
  }
  flush();
  // 去掉每行重复的页码标签，只保留每页首次出现
  for (final c in out) {
    final seen = <String>{};
    c.text = c.text.split('\n').map((l) {
      final m = RegExp(r'^\[第(\d+)页\] ').firstMatch(l);
      if (m == null) return l;
      return seen.add(m[1]!) ? l : l.substring(m[0]!.length);
    }).join('\n');
  }
  return out;
}

String _fnv(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36);
}

// ================= 知识点去重 =================

Set<String> _bigrams(String s) {
  final t = s.replaceAll(RegExp(r'[\s\$\\{}()（）,，。:：]'), '').toLowerCase();
  if (t.length < 2) return {t};
  return {for (var i = 0; i < t.length - 1; i++) t.substring(i, i + 2)};
}

double similarity(String a, String b) {
  final x = _bigrams(a), y = _bigrams(b);
  if (x.isEmpty || y.isEmpty) return 0;
  return x.intersection(y).length / x.union(y).length;
}

List<KnowledgePoint> dedupeKps(List<KnowledgePoint> input, {double threshold = 0.75}) {
  final out = <KnowledgePoint>[];
  for (final kp in input) {
    final dup = out.where((o) => similarity(o.title, kp.title) >= threshold).firstOrNull;
    if (dup == null) {
      out.add(kp);
    } else if (kp.content.length > dup.content.length) {
      dup.content = kp.content; // 保留更完整的描述
    }
  }
  return out;
}

// ================= PDF 解析 =================

final _figureRe = RegExp(r'(^|\n)\s*(图|Figure|Fig\.)\s*\d+([\.\-．]\d+)*', caseSensitive: false);

/// 混合模式的逐页判断：本地文字层很少（扫描页、整页插图/图表），或出现「图 1.2」「Figure 3」这类图注 → 版面模式；
/// 否则用纯文字模式。
String pageOcrPurpose(String localText) {
  final chars = localText.replaceAll(RegExp(r'\s'), '').length;
  if (chars < 80) return Settings.ocrRich;
  if (_figureRe.hasMatch(localText)) return Settings.ocrRich;
  return Settings.ocrText;
}

/// 解析计划中的一批：[from, to] 页（1 起始、闭区间）及使用的 OCR 模式。
class OcrBatch {
  final int from, to;
  final String purpose;
  const OcrBatch(this.from, this.to, this.purpose);
  @override
  String toString() => '$from-$to:$purpose';
}

/// 把相邻同模式的页合并成连续批次，每批不超过 [batch] 页。每页只发送一次。
List<OcrBatch> planOcrBatches(List<String> purposes, int batch) {
  final out = <OcrBatch>[];
  var i = 0;
  while (i < purposes.length) {
    var j = i;
    while (j + 1 < purposes.length && purposes[j + 1] == purposes[i] && j + 1 - i < batch) {
      j++;
    }
    out.add(OcrBatch(i + 1, j + 1, purposes[i]));
    i = j + 1;
  }
  return out;
}

class ParseService {
  final Repository repo;
  final Settings settings;
  final PdfParser? parserOverride; // 测试用
  final http.Client? httpClient; // 测试用
  final ChapterService? chapters; // 有则解析后自动分章（书签/目录/标题/AI/按页数）
  ParseService(this.repo, this.settings, {this.parserOverride, this.httpClient, this.chapters});

  /// 解析完成后切块：有分章服务时先自动分章，再按方案切块。
  Future<void> _rechunk(PdfDoc doc, Progress onProgress, {Uint8List? bytes}) async {
    final cs = chapters;
    if (cs == null) {
      final pages = await repo.pages(doc.projectId, docId: doc.id);
      await repo.replaceChunks(doc.projectId, doc.id, chunkPages(doc.projectId, doc.id, pages, mdHeadings: doc.isSectioned));
      return;
    }
    final plan = await cs.autoPlan(doc, bytes: bytes, onProgress: onProgress);
    await cs.apply(doc, plan);
  }

  /// 记录每页的解析来源（只用于「章节内容」里显示，不影响解析）。
  String sourceTag(String purpose) => switch (settings.ocrProvider) {
        OcrProvider.deepseek => purpose == Settings.ocrRich ? 'deepseek_rich' : 'deepseek_text',
        OcrProvider.kimi => 'kimi',
        OcrProvider.local => 'local',
      };

  static const wordUnsupported = '当前解析模型不支持 Word，请在「文档解析」设置里切换到支持 Word 的模型（DeepSeek OCR 或 Kimi），或把文档另存为 PDF';

  /// 当前「文档解析」设置对应的解析器；本地提取时为 null。伴学附件也用它。
  Future<PdfParser?> parserFor(String purpose) => _parser(purpose);

  Future<PdfParser?> _parser(String purpose) async {
    if (parserOverride != null) return parserOverride;
    switch (settings.ocrProvider) {
      case OcrProvider.deepseek:
        return DeepSeekOcr(baseUrl: settings.ocrBaseUrl, apiKey: await settings.ocrKey(), purpose: purpose, client: httpClient);
      case OcrProvider.kimi:
        return KimiFileExtract(baseUrl: settings.kimiBaseUrl, apiKey: await settings.kimiKey(), client: httpClient);
      case OcrProvider.local:
        return null;
    }
  }

  /// 生成解析计划。DeepSeek 两种模式都选时，先在本地读文字层逐页判断模式。
  Future<List<OcrBatch>> plan(Uint8List bytes, int pageCount) async {
    final batch = settings.ocrBatchPages.clamp(1, 1000);
    if (settings.ocrProvider == OcrProvider.deepseek && settings.ocrMixed) {
      List<String> local;
      try {
        local = await PdfTools.extractText(bytes, 1, pageCount);
      } catch (_) {
        local = List.filled(pageCount, '');
      }
      while (local.length < pageCount) {
        local.add('');
      }
      return planOcrBatches(local.map(pageOcrPurpose).toList(), batch);
    }
    final purpose = settings.ocrModes.first;
    return [for (final (f, t) in pageBatches(pageCount, batch)) OcrBatch(f, t, purpose)];
  }

  /// 解析一份 PDF：按计划分批上传，失败自动重试 3 次；已解析的页直接跳过。
  /// 返回失败的批次数（0 表示全部成功）。
  Future<int> parseDoc(PdfDoc doc, Progress onProgress) async {
    if (doc.isWord) return _parseWord(doc, onProgress);
    if (doc.isText) return _parseText(doc, onProgress);
    final bytes = await DocFiles.read(doc);
    if (doc.pageCount == 0) doc.pageCount = await PdfTools.pageCount(bytes);
    final cached = {for (final p in await repo.pages(doc.projectId, docId: doc.id)) p.page};
    final todo = List.generate(doc.pageCount, (i) => i + 1).where((p) => !cached.contains(p)).toList();
    doc.status = '解析中';
    await repo.saveDoc(doc);
    var failed = 0;
    if (todo.isNotEmpty) {
      onProgress('正在分析页面…', 0.02);
      final batches = (await plan(bytes, doc.pageCount))
          .where((b) => [for (var p = b.from; p <= b.to; p++) p].any((p) => !cached.contains(p)))
          .toList();
      final parsers = <String, PdfParser?>{};
      for (final b in batches) {
        if (!parsers.containsKey(b.purpose)) parsers[b.purpose] = await _parser(b.purpose);
      }
      // 「并发数」= 1 时逐批顺序解析（与原来完全一样）；大于 1 时最多同时上传这么多批，
      // 实际在途请求还受全局限流约束。每页的结果按页码保存，与完成顺序无关。
      final conc = settings.concurrency;
      var done = 0;
      final results = await runPool<bool>(batches.length, conc, (bi) async {
        final b = batches[bi];
        final modeName = settings.ocrProvider == OcrProvider.deepseek
            ? (b.purpose == Settings.ocrRich ? '版面' : '文字')
            : '';
        final mode = modeName.isEmpty ? '' : '（$modeName模式）';
        final frac = conc == 1 ? bi / batches.length : done / batches.length;
        onProgress(
            conc == 1
                ? '第 ${b.from}–${b.to} 页$mode · ${bi + 1}/${batches.length} 批'
                : '第 ${b.from}–${b.to} 页$mode · 已完成 $done/${batches.length} 批',
            frac);
        final parser = parsers[b.purpose];
        List<String>? texts;
        Object? err;
        for (var attempt = 0; attempt < 3 && texts == null; attempt++) {
          try {
            if (parser == null) {
              texts = await PdfTools.extractText(bytes, b.from, b.to);
            } else {
              final part = await PdfTools.slice(bytes, b.from, b.to);
              final r = await parser.parse(part, '${doc.name}_p${b.from}-${b.to}.pdf', b.to - b.from + 1);
              texts = List.generate(b.to - b.from + 1, (i) => i < r.pages.length ? r.pages[i].text : '');
            }
          } catch (e) {
            err = e;
            if (e is OcrException && e.message.contains('401')) break;
            onProgress('第 ${b.from}–${b.to} 页失败，重试中（${attempt + 1}/3）', frac);
            await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
          }
        }
        if (texts == null) {
          if (err is OcrException && err.message.contains('401')) throw err;
          return false;
        }
        await repo.savePages([
          for (var i = 0; i < texts.length; i++)
            PageText(
                docId: doc.id,
                projectId: doc.projectId,
                page: b.from + i,
                text: LatexUtil.normalize(texts[i]),
                source: parser == null ? 'local' : sourceTag(b.purpose))
        ]);
        doc.parsedPages = (await repo.pages(doc.projectId, docId: doc.id)).length;
        await repo.saveDoc(doc);
        return true;
      }, onDone: (d, total) {
        done = d;
        if (conc > 1) onProgress('已完成 $d/$total 批', d / total);
      });
      failed = results.where((ok) => !ok).length;
    }
    await _rechunk(doc, onProgress, bytes: bytes);
    final pages = await repo.pages(doc.projectId, docId: doc.id);
    doc.parsedPages = pages.length;
    doc.status = failed == 0 ? '已解析' : '部分失败';
    await repo.saveDoc(doc);
    onProgress(failed == 0 ? '解析完成' : '$failed 批失败，可点重试继续', 1);
    return failed;
  }
}

extension on ParseService {
  /// Word：整份 .docx / .doc 直接交给设置里的解析模型（DeepSeek OCR / Kimi），不在手机上本地解析。
  /// 解析模型不支持 Word 时不联网，直接在这份资料上显示提示。
  Future<int> _parseWord(PdfDoc doc, Progress onProgress) async {
    if (parserOverride == null && !Settings.supportsWord(settings.ocrProvider)) {
      doc.status = '不支持';
      doc.note = ParseService.wordUnsupported;
      await repo.saveDoc(doc);
      onProgress(ParseService.wordUnsupported, 1);
      return 1;
    }
    final bytes = await DocFiles.read(doc);
    doc.status = '解析中';
    doc.note = '';
    await repo.saveDoc(doc);
    // 文字模式下，没有图片的 Word 会被 DeepSeek 直接抽取文字（不做逐页识别）；混合模式也用文字模式。
    final purpose = settings.ocrMixed ? Settings.ocrText : settings.ocrModes.first;
    onProgress('正在上传 Word 给解析模型…', 0.1);
    final parser = await _parser(purpose);
    if (parser == null) throw OcrException(ParseService.wordUnsupported);
    OcrResult? r;
    Object? err;
    for (var attempt = 0; attempt < 3 && r == null; attempt++) {
      try {
        r = await parser.parse(bytes, '${doc.name}.${doc.type}', 1); // 扩展名决定 MIME
      } catch (e) {
        err = e;
        if (e is OcrException && (e.message.contains('401') || e.message.contains('密钥'))) break;
        onProgress('解析失败，重试中（${attempt + 1}/3）', 0.1);
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    if (r == null) {
      doc.status = '部分失败';
      doc.note = '解析失败：$err';
      await repo.saveDoc(doc);
      if (err is OcrException && err.message.contains('401')) throw err;
      onProgress('解析失败，可点重试', 1);
      return 1;
    }
    onProgress('按标题切分小节…', 0.8);
    final text = r.pages.map((p) => p.text).where((t) => t.trim().isNotEmpty).join('\n\n');
    final sections = splitWordSections(LatexUtil.normalize(text));
    await repo.deletePages(doc.projectId, doc.id); // 小节数可能变化，整份重写
    await repo.savePages([
      for (var i = 0; i < sections.length; i++)
        PageText(docId: doc.id, projectId: doc.projectId, page: i + 1, text: sections[i], source: sourceTag(purpose))
    ]);
    doc.pageCount = sections.length;
    await _rechunk(doc, onProgress);
    doc.parsedPages = sections.length;
    doc.status = sections.isEmpty ? '部分失败' : '已解析';
    doc.note = sections.isEmpty ? '解析模型没有返回文字' : '';
    await repo.saveDoc(doc);
    onProgress(sections.isEmpty ? '没有解析出文字' : '解析完成：${sections.length} 个小节', 1);
    return sections.isEmpty ? 1 : 0;
  }
}

extension on ParseService {
  /// TXT：在手机上直接读取（不联网、不调用任何接口），识别编码后按段落切成小节，再照常分章。
  Future<int> _parseText(PdfDoc doc, Progress onProgress) async {
    doc.status = '解析中';
    doc.note = '';
    await repo.saveDoc(doc);
    onProgress('正在读取 TXT…', 0.2);
    final bytes = await DocFiles.read(doc);
    final decoded = decodeTextBytes(bytes);
    final sections = splitTextPages(cleanImportedText(decoded.text));
    await repo.deletePages(doc.projectId, doc.id); // 小节数可能变化，整份重写
    await repo.savePages([
      for (var i = 0; i < sections.length; i++)
        PageText(docId: doc.id, projectId: doc.projectId, page: i + 1, text: sections[i], source: 'txt')
    ]);
    doc.pageCount = sections.length;
    onProgress('按标题识别章节…', 0.7);
    await _rechunk(doc, onProgress);
    doc.parsedPages = sections.length;
    doc.status = sections.isEmpty ? '部分失败' : '已解析';
    doc.note = sections.isEmpty ? '文件里没有文字' : '';
    await repo.saveDoc(doc);
    onProgress(sections.isEmpty ? '没有读取到文字' : '读取完成：${sections.length} 个小节（${decoded.encoding}）', 1);
    return sections.isEmpty ? 1 : 0;
  }
}

// ================= 生成 =================

class GenerationResult {
  final int cards, questions, kps;
  final List<String> cardIds, questionIds;
  final QualityReport quality;
  final bool pending; // true：放进了「待审核」，还没加入复习
  GenerationResult(this.cards, this.questions, this.kps,
      {this.cardIds = const [], this.questionIds = const [], QualityReport? quality, this.pending = false})
      : quality = quality ?? QualityReport();

  /// 如「生成 30 张，自动修正 2 张，去重 3 张」。
  String get summary {
    final d = quality.detail;
    return '生成 ${cards + questions} 张（闪卡 $cards，题目 $questions）${d.isEmpty ? '' : '，$d'}';
  }
}

// ================= 自动数量（按知识点） =================

/// 每个知识点出几道题：基础 1、中等 / 混合 2、拔高 3。
int questionsPerKp(String difficulty) => switch (difficulty) {
      '基础' => 1,
      '拔高' => 3,
      _ => 2,
    };

/// 自动数量的估算结果。[rawCards] / [rawQuestions] 是不设上限时的数量。
class AutoCount {
  final int cards, questions, rawCards, rawQuestions, cap;
  const AutoCount(this.cards, this.questions, this.rawCards, this.rawQuestions, this.cap);
  int get total => cards + questions;
  int get rawTotal => rawCards + rawQuestions;
  bool get capped => rawTotal > total;
}

/// 按知识点推算数量：闪卡约每个知识点 1 张，题目每个知识点 1–3 道（随难度）。
/// 合计超过 [cap] 时按比例缩减，两类都要时各至少 1。
AutoCount deriveAutoCount(int kpCount,
    {required String difficulty, bool cards = true, bool questions = true, int cap = 40}) {
  final rc = cards ? kpCount : 0;
  final rq = questions ? kpCount * questionsPerKp(difficulty) : 0;
  final limit = max(1, cap);
  if (rc + rq <= limit) return AutoCount(rc, rq, rc, rq, limit);
  var c = (limit * rc / (rc + rq)).round();
  if (rc > 0 && rq > 0 && limit >= 2) c = c.clamp(1, limit - 1);
  return AutoCount(c, limit - c, rc, rq, limit);
}

/// 自动数量的规划结果：所选范围内的知识点 + 推算的数量。生成时直接复用这些知识点，不再重复分析。
class GenPlan {
  final List<KnowledgePoint> kps;
  final AutoCount count;
  final int chunks;
  GenPlan(this.kps, this.count, this.chunks);

  /// 按章节分组（保持出现顺序），用于确认面板的知识点列表。
  Map<String, List<KnowledgePoint>> get byChapter {
    final m = <String, List<KnowledgePoint>>{};
    for (final k in kps) {
      m.putIfAbsent(k.chapter.isEmpty ? '未分章' : k.chapter, () => []).add(k);
    }
    return m;
  }
}

class PlanException implements Exception {
  final String message;
  PlanException(this.message);
  @override
  String toString() => message;
}

/// 解析知识点 JSON（knowledge_points 或 items），忽略不是对象的条目。
List<KnowledgePoint> parseKps(String projectId, Chunk c, Map<String, dynamic> j) {
  final list = listOfMaps(j['knowledge_points'] ?? j['items']);
  return [
    for (var k = 0; k < list.length; k++)
      KnowledgePoint(
        id: '${c.id}_k$k',
        projectId: projectId,
        docId: c.docId,
        chapter: c.chapter,
        section: c.section,
        title: '${list[k]['title'] ?? ''}',
        type: '${list[k]['type'] ?? ''}',
        content: LatexUtil.autoFix('${list[k]['content'] ?? ''}'),
        page: asInt(list[k]['page'], c.pageStart).clamp(c.pageStart, max(c.pageStart, c.pageEnd)),
      )
  ];
}

/// [GenerationService.analyzeChunks] 的结果。
class ChunkAnalysis {
  /// 分析成功的段落 id → 知识点数（0 = 这一段没有知识点）。
  final counts = <String, int>{};

  /// 失败的段落 id → 原因。
  final errors = <String, String>{};

  /// 每一段都会遇到的错误（密钥无效、余额不足），出现后就停止了。
  String? fatal;
}

class GenerationService {
  final Repository repo;
  final Settings settings;
  final LlmClient llm;
  /// 根据用户反馈汇总的「避免清单」，拼进每次出题的自定义要求里。
  final String avoid;
  /// 生成后自动质检（出处、公式、选择题、去重）；测试可关闭。
  final bool qualityCheck;
  GenerationService(this.repo, this.settings, this.llm, {this.avoid = '', this.qualityCheck = true});

  late final QualityService _quality = QualityService(llm, fixPrompt: settings.prompt('fix'));

  /// 质检用的原文：知识点所在的分块原文 + 知识点内容（分块按 id 前缀匹配，找不到再取当页）。
  final _chunkText = <String, String>{};
  final _kpText = <String, String>{};
  Future<String> _sourceOf(String docId, int page, String kpId) async {
    final k = _kpText[kpId] ?? '';
    for (final e in _chunkText.entries) {
      if (kpId.startsWith('${e.key}_k')) return '${e.value}\n$k';
    }
    final p = docId.isEmpty || page <= 0 ? null : await repo.page(docId, page);
    return '${p?.text ?? ''}\n$k';
  }

  Future<(DupIndex, DupIndex)> _dupIndex(String projectId) async {
    final cd = DupIndex(), qd = DupIndex();
    for (final c in [...await repo.cards(projectId: projectId), ...await repo.inboxCards(projectId: projectId)]) {
      cd.add(dupKeyCard(c));
    }
    for (final q in [...await repo.questions(projectId: projectId), ...await repo.inboxQuestions(projectId: projectId)]) {
      qd.add(dupKeyQuestion(q));
    }
    return (cd, qd);
  }

  List<Chunk> _scope(List<Chunk> all, GenOptions o) {
    switch (o.scope) {
      case 'chapters':
        return all.where((c) => o.chapters.contains(c.chapter)).toList();
      case 'pages':
        return all.where((c) => c.pageEnd >= o.pageFrom && c.pageStart <= o.pageTo).toList();
      default:
        return all;
    }
  }

  /// 分析一段文字：调用模型、保存知识点。这一段确实没有知识点时记下来，之后不再重复分析。
  Future<List<KnowledgePoint>> _analyzeChunk(String projectId, Chunk c, {bool strict = false}) async {
    final prompt = Prompts.fill(settings.prompt('kp'), {
      'chapter': c.chapter,
      'section': c.section,
      'pages': '${c.pageStart}–${c.pageEnd}',
      'text': c.text,
    });
    final j = await llm.chatJson(prompt);
    final kps = parseKps(projectId, c, j);
    if (kps.isEmpty) {
      // 返回里根本没有知识点列表（不是「这一段没有」）：不记，下次还会再试
      if (j['knowledge_points'] == null && j['items'] == null) {
        if (strict) throw LlmException('模型没有返回知识点');
        return kps;
      }
      settings.markKpEmpty([c]);
    } else {
      await repo.saveKps(kps);
    }
    return kps;
  }

  /// 第 1–2 步：提取知识点（已提取过的块会复用），并去重。
  Future<List<KnowledgePoint>> extractKps(String projectId, List<Chunk> chunks, Progress p) async {
    final existing = await repo.kps(projectId);
    // 「并发数」= 1 时逐块顺序分析（与原来一样）；大于 1 时同时分析多块。结果按块的顺序合并，再去重。
    final conc = settings.concurrency;
    var done = 0;
    final perChunk = await runPool<List<KnowledgePoint>>(chunks.length, conc, (i) async {
      final c = chunks[i];
      final cachedForChunk = existing.where((k) => k.id.startsWith('${c.id}_k')).toList();
      if (cachedForChunk.isNotEmpty) return cachedForChunk;
      if (settings.kpEmptyMarked(c)) return const <KnowledgePoint>[]; // 分析过，这一段没有知识点
      p(
          conc == 1
              ? '提取知识点：${c.chapter} ${c.section}（${i + 1}/${chunks.length}）'
              : '提取知识点：${c.chapter} ${c.section}（已完成 $done/${chunks.length}）',
          0.1 + 0.4 * (conc == 1 ? i : done) / chunks.length);
      return _analyzeChunk(projectId, c);
    }, onDone: (d, _) => done = d);
    return dedupeKps([for (final l in perChunk) ...l]);
  }

  /// 只分析还没分析的段落：已有知识点的不动。
  /// 和 [extractKps] 不同，某一段失败不会中断其它段——失败的记下原因，下次再点还会继续分析它们。
  /// 密钥无效、余额不足这类每一段都会遇到的错误才会提前停止。
  Future<ChunkAnalysis> analyzeChunks(String projectId, List<Chunk> chunks, Progress p) async {
    final out = ChunkAnalysis();
    var done = 0;
    await runPool<bool>(chunks.length, settings.concurrency, (i) async {
      if (out.fatal != null) return false;
      final c = chunks[i];
      p('分析知识点：${c.chapter} ${c.section}（已完成 $done/${chunks.length}）', chunks.isEmpty ? 1 : done / chunks.length);
      try {
        final kps = await _analyzeChunk(projectId, c, strict: true);
        out.counts[c.id] = kps.length;
      } on LlmCancelled {
        rethrow;
      } catch (e) {
        out.errors[c.id] = '$e';
        final t = '$e';
        if (t.contains('密钥') || t.contains('余额')) out.fatal ??= t;
      }
      return true;
    }, onDone: (d, _) => done = d);
    return out;
  }

  static String optionsText(List<String> l) => l.isEmpty ? '不限' : l.join('、');

  /// 自动数量第 1 步（规划）：列出所选范围内的知识点（定义、定理、公式、例题…），据此推算数量。
  /// 用的是同一个知识点提取步骤（结果会缓存），所以随后生成时不会再分析一遍。失败时抛 [PlanException]。
  Future<GenPlan> plan(String projectId, GenOptions o, Progress p, {int? cap}) async {
    final allChunks = await repo.chunks(projectId);
    if (allChunks.isEmpty) throw PlanException('还没有解析好的资料，请先上传并解析资料');
    final chunks = _scope(allChunks, o);
    if (chunks.isEmpty) throw PlanException('所选范围内没有内容');
    p('分析知识点…', 0.05);
    final List<KnowledgePoint> kps;
    try {
      kps = await extractKps(projectId, chunks, (m, f) => p(m.replaceFirst('提取知识点', '分析知识点'), f * 2));
    } catch (e) {
      throw PlanException('分析知识点失败：$e');
    }
    if (kps.isEmpty) throw PlanException('没有识别到知识点');
    kps.sort((a, b) => b.priority.compareTo(a.priority));
    final count = deriveAutoCount(kps.length,
        difficulty: o.difficulty,
        cards: o.autoCards,
        questions: o.autoQuestions && o.types.isNotEmpty,
        cap: cap ?? settings.autoCap);
    return GenPlan(kps, count, chunks.length);
  }

  /// 第 3 步：根据知识点生成闪卡和题目。LaTeX 不合格的整批重新生成（最多 2 次）。
  /// [planned]：自动数量规划时得到的知识点，直接复用。
  Future<GenerationResult> generate(String projectId, GenOptions o, Progress p, {List<KnowledgePoint>? planned}) async {
    final allChunks = await repo.chunks(projectId);
    if (allChunks.isEmpty) throw LlmException('还没有解析好的资料，请先上传并解析 PDF');
    final chunks = _scope(allChunks, o);
    if (chunks.isEmpty) throw LlmException('所选范围内没有内容');
    p('准备中…', 0.05);
    var kps = planned != null && planned.isNotEmpty ? [...planned] : await extractKps(projectId, chunks, p);
    if (kps.isEmpty) throw LlmException('没有提取到知识点');
    for (final c in chunks) {
      _chunkText[c.id] = c.text;
    }
    for (final k in kps) {
      _kpText[k.id] = '${k.title} ${k.content}';
    }
    final (cardDups, qDups) = await _dupIndex(projectId);
    final report = QualityReport();
    final reviewFirst = settings.reviewBeforeAdd;
    final cardIds = <String>[], qIds = <String>[];
    kps.sort((a, b) => b.priority.compareTo(a.priority));
    const perBatch = 8;
    final batches = <List<KnowledgePoint>>[];
    for (var i = 0; i < kps.length; i += perBatch) {
      batches.add(kps.sublist(i, min(i + perBatch, kps.length)));
    }
    if (settings.concurrency > 1 && batches.length > 1) {
      return _generateConcurrent(projectId, o, p, kps, batches, cardDups, qDups, report, reviewFirst);
    }
    // 按批次平均分配数量
    var cardsLeft = o.cardCount, qLeft = o.questionCount;
    var totalCards = 0, totalQ = 0;
    for (var bi = 0; bi < batches.length && (cardsLeft > 0 || qLeft > 0); bi++) {
      final remainingBatches = batches.length - bi;
      var nc = (cardsLeft / remainingBatches).ceil();
      var nq = (qLeft / remainingBatches).ceil();
      if (o.autoCount) {
        // 自动数量：按每批知识点个数分配，让每个知识点都覆盖到
        final restKps = batches.skip(bi).fold<int>(0, (a, b) => a + b.length);
        final last = bi == batches.length - 1;
        nc = last ? max(0, cardsLeft) : (max(0, cardsLeft) * batches[bi].length / restKps).round();
        nq = last ? max(0, qLeft) : (max(0, qLeft) * batches[bi].length / restKps).round();
        if (nc == 0 && nq == 0) continue;
      }
      p('生成闪卡和题目（${bi + 1}/${batches.length}）', 0.5 + 0.5 * bi / batches.length);
      var (cards, qs, rejects) = await _generateBatch(projectId, batches[bi], nc, nq, o);
      if (qualityCheck) {
        p('检查质量（${bi + 1}/${batches.length}）', 0.5 + 0.5 * (bi + 0.8) / batches.length);
        final (c2, q2, r) = await _quality.process(
            cards: cards, questions: qs, rejects: rejects, sourceOf: _sourceOf, cardDups: cardDups, questionDups: qDups);
        cards = c2;
        qs = q2;
        report.add(r);
      }
      if (reviewFirst) {
        await repo.saveInbox(cards, qs);
      } else {
        await repo.saveCards(cards);
        await repo.saveQuestions(qs);
      }
      cardIds.addAll(cards.map((e) => e.id));
      qIds.addAll(qs.map((e) => e.id));
      cardsLeft -= cards.length;
      qLeft -= qs.length;
      totalCards += cards.length;
      totalQ += qs.length;
    }
    p('完成', 1);
    return GenerationResult(totalCards, totalQ, kps.length,
        cardIds: cardIds, questionIds: qIds, quality: report, pending: reviewFirst);
  }

  /// 「并发数」> 1 时的出题：先按与顺序出题完全相同的算法（[allocateBatches]）算好每批的数量，
  /// 再最多同时生成「并发数」批；每批照常质检。全部完成后跨批次再去重一次（并发时各批的去重可能同时进行），
  /// 有缺口（去重、模型少给）时补一轮，最后按批次顺序保存。
  Future<GenerationResult> _generateConcurrent(String projectId, GenOptions o, Progress p, List<KnowledgePoint> kps,
      List<List<KnowledgePoint>> batches, DupIndex cardDups, DupIndex qDups, QualityReport report, bool reviewFirst) async {
    final conc = settings.concurrency;
    final cards = List<List<Flashcard>>.generate(batches.length, (_) => []);
    final qs = List<List<Question>>.generate(batches.length, (_) => []);
    Object? error;
    StackTrace? errorStack;

    Future<void> round(List<(int, int)> alloc, String label) async {
      final todo = [for (var i = 0; i < alloc.length; i++) if (alloc[i].$1 > 0 || alloc[i].$2 > 0) i];
      if (todo.isEmpty) return;
      p('$label（已完成 0/${todo.length}）', 0.5);
      await runPool<void>(todo.length, conc, (t) async {
        if (error != null) return;
        final bi = todo[t];
        try {
          var (c, q, rejects) = await _generateBatch(projectId, batches[bi], alloc[bi].$1, alloc[bi].$2, o);
          if (qualityCheck) {
            final (c2, q2, r) = await _quality.process(
                cards: c, questions: q, rejects: rejects, sourceOf: _sourceOf, cardDups: cardDups, questionDups: qDups);
            c = c2;
            q = q2;
            report.add(r);
          }
          cards[bi].addAll(c);
          qs[bi].addAll(q);
        } catch (e, st) {
          error ??= e;
          errorStack ??= st;
        }
      }, onDone: (d, total) => p('$label（已完成 $d/$total）', 0.5 + 0.45 * d / total));
    }

    // 跨批次去重：按批次顺序，后出现的重复项去掉
    void crossDedup() {
      if (!qualityCheck) return;
      final cd = DupIndex(), qd = DupIndex();
      var removed = 0;
      for (var bi = 0; bi < batches.length; bi++) {
        final before = cards[bi].length + qs[bi].length;
        cards[bi].retainWhere((c) {
          if (cd.isDup(dupKeyCard(c))) return false;
          cd.add(dupKeyCard(c));
          return true;
        });
        qs[bi].retainWhere((q) {
          if (qd.isDup(dupKeyQuestion(q))) return false;
          qd.add(dupKeyQuestion(q));
          return true;
        });
        removed += before - cards[bi].length - qs[bi].length;
      }
      report.deduped += removed;
      report.kept -= removed;
    }

    int total(List<List<Object>> l) => l.fold(0, (a, b) => a + b.length);
    final sizes = [for (final b in batches) b.length];
    await round(allocateBatches(sizes, o.cardCount, o.questionCount, auto: o.autoCount), '生成闪卡和题目');
    crossDedup();
    // 补一轮：缺口按同样的算法分到各批
    final missC = max(0, o.cardCount - total(cards)), missQ = max(0, o.questionCount - total(qs));
    if (error == null && (missC > 0 || missQ > 0)) {
      await round(allocateBatches(sizes, missC, missQ, auto: o.autoCount), '补充生成');
      crossDedup();
    }
    final allCards = [for (final l in cards) ...l], allQs = [for (final l in qs) ...l];
    if (reviewFirst) {
      await repo.saveInbox(allCards, allQs);
    } else {
      await repo.saveCards(allCards);
      await repo.saveQuestions(allQs);
    }
    if (error != null) Error.throwWithStackTrace(error!, errorStack!);
    p('完成', 1);
    return GenerationResult(allCards.length, allQs.length, kps.length,
        cardIds: allCards.map((e) => e.id).toList(),
        questionIds: allQs.map((e) => e.id).toList(),
        quality: report,
        pending: reviewFirst);
  }

  /// 针对单个知识点（错题 / AI 解释面板）换个角度再出几道题。
  Future<List<Question>> generateForKp(String projectId, KnowledgePoint kp, {int count = 3, String hint = ''}) async {
    final o = GenOptions(cardCount: 0, questionCount: count, types: [QType.single, QType.judge, QType.fill, QType.calc],
        difficulty: '混合', focus: ['易错点', '计算应用'], custom: '换一个角度考查，避免与已有题目重复。$hint');
    var (_, qs, rejects) = await _generateBatch(projectId, [kp], 0, count, o);
    if (qualityCheck) {
      _kpText[kp.id] = '${kp.title} ${kp.content}';
      final (_, qDups) = await _dupIndex(projectId);
      final (_, q2, _) = await _quality.process(
          cards: const [], questions: qs, rejects: rejects, sourceOf: _sourceOf, cardDups: DupIndex(), questionDups: qDups);
      qs = q2;
    }
    await repo.saveQuestions(qs);
    return qs;
  }

  Future<(List<Flashcard>, List<Question>, List<RawReject>)> _generateBatch(
      String projectId, List<KnowledgePoint> kps, int nc, int nq, GenOptions o,
      {String extra = ''}) async {
    final kpText = [
      for (var i = 0; i < kps.length; i++)
        '[$i] （${kps[i].chapter} ${kps[i].section}，第${kps[i].page}页）${kps[i].title}：${kps[i].content}'
    ].join('\n');
    final prompt = Prompts.fill(settings.prompt('gen'), {
      'card_count': '$nc',
      'question_count': '$nq',
      'types': optionsText(o.types),
      'difficulty': o.difficulty,
      'focus': optionsText(o.focus),
      'custom': [o.custom.trim(), avoid.trim()].where((e) => e.isNotEmpty).join('\n').ifEmpty('无'),
      'kps': kpText,
    });
    for (var attempt = 0; attempt < 3; attempt++) {
      final j = await llm.chatJson(prompt + extra);
      final rejects = <RawReject>[];
      final (cards, qs, problems) = parseGenerated(projectId, kps, j, allowedTypes: o.types, rejects: rejects);
      // 个别条目的公式问题交给质检单独修正（便宜）；整批都不能用时才重新生成
      final usable = qualityCheck ? cards.isNotEmpty || qs.isNotEmpty || rejects.isNotEmpty : problems.isEmpty;
      if (usable || attempt == 2) {
        return (cards, qs, qualityCheck ? rejects : <RawReject>[]);
      }
      extra = '\n\n上一次输出存在公式格式问题，请修正后重新输出：\n${problems.take(5).join('\n')}';
    }
    return (<Flashcard>[], <Question>[], <RawReject>[]);
  }
}

/// 每批出多少：与顺序出题循环的算法完全一致（假设每批都按要求的数量给出）。
/// [sizes] 为每批知识点个数；返回每批的 (闪卡数, 题目数)，(0, 0) 表示这一批不出题。
List<(int, int)> allocateBatches(List<int> sizes, int cards, int questions, {bool auto = false}) {
  final out = List<(int, int)>.filled(sizes.length, (0, 0));
  var cardsLeft = cards, qLeft = questions;
  for (var bi = 0; bi < sizes.length && (cardsLeft > 0 || qLeft > 0); bi++) {
    final remainingBatches = sizes.length - bi;
    var nc = (cardsLeft / remainingBatches).ceil();
    var nq = (qLeft / remainingBatches).ceil();
    if (auto) {
      final restKps = sizes.skip(bi).fold<int>(0, (a, b) => a + b);
      final last = bi == sizes.length - 1;
      nc = last ? max(0, cardsLeft) : (max(0, cardsLeft) * sizes[bi] / restKps).round();
      nq = last ? max(0, qLeft) : (max(0, qLeft) * sizes[bi] / restKps).round();
      if (nc == 0 && nq == 0) continue;
    }
    out[bi] = (nc, nq);
    cardsLeft -= nc;
    qLeft -= nq;
  }
  return out;
}

/// 把模型 JSON 转成闪卡/题目，并校验 LaTeX。返回 (合格闪卡, 合格题目, 问题列表)。
(List<Flashcard>, List<Question>, List<String>) parseGenerated(
    String projectId, List<KnowledgePoint> kps, Map<String, dynamic> j,
    {List<String> allowedTypes = const [], List<RawReject>? rejects}) {
  final problems = <String>[];
  KnowledgePoint? kpOf(dynamic idx) {
    final i = asInt(idx, -1);
    return i >= 0 && i < kps.length ? kps[i] : (kps.isEmpty ? null : kps.first);
  }

  String fix(String s) {
    final f = LatexUtil.autoFix(s.trim());
    final pr = LatexUtil.validate(f);
    problems.addAll(pr);
    return pr.isEmpty ? f : '';
  }

  final cards = <Flashcard>[];
  for (final m in listOfMaps(j['flashcards'])) {
    final kp = kpOf(m['kp_index']);
    final before = problems.length;
    final front = fix('${m['front'] ?? ''}'), back = fix('${m['back'] ?? ''}');
    final expl = fix('${m['explanation'] ?? ''}');
    if (problems.length > before && rejects != null) {
      // 公式有问题：保留原文交给质检修正
      String raw(Object? v) => LatexUtil.autoFix('${v ?? ''}'.trim());
      if (raw(m['front']).isNotEmpty && raw(m['back']).isNotEmpty) {
        rejects.add(RawReject(
            issue: '公式无法渲染：${problems.sublist(before).take(2).join('；')}',
            card: Flashcard(
              id: newId(),
              projectId: projectId,
              kpId: kp?.id ?? '',
              docId: kp?.docId ?? '',
              chapter: kp?.chapter ?? '',
              section: kp?.section ?? '',
              front: raw(m['front']),
              back: raw(m['back']),
              explanation: raw(m['explanation']),
              page: asInt(m['page'], kp?.page ?? 0),
            )));
      }
      continue;
    }
    if (front.isEmpty || back.isEmpty) continue;
    cards.add(Flashcard(
      id: newId(),
      projectId: projectId,
      kpId: kp?.id ?? '',
      docId: kp?.docId ?? '',
      chapter: kp?.chapter ?? '',
      section: kp?.section ?? '',
      front: front,
      back: back,
      explanation: expl,
      page: asInt(m['page'], kp?.page ?? 0),
    ));
  }
  final qs = <Question>[];
  for (final m in listOfMaps(j['questions'])) {
    final kp = kpOf(m['kp_index']);
    var type = '${m['type'] ?? QType.single}'.replaceAll('题', '');
    if (!QType.all.contains(type)) type = QType.single;
    if (allowedTypes.isNotEmpty && !allowedTypes.contains(type)) continue;
    final before = problems.length;
    final stem = fix('${m['stem'] ?? ''}');
    final options = ((m['options'] as List?) ?? [])
        .map((e) => fix('$e'.replaceFirst(RegExp(r'^\s*[A-Fa-f][\.．、:：]\s*'), '')))
        .toList();
    if ((stem.isEmpty || options.any((e) => e.isEmpty)) && problems.length == before) continue;
    var answer = '${m['answer'] ?? ''}'.trim();
    if (type == QType.single || type == QType.multi) {
      answer = answer.toUpperCase().replaceAll(RegExp(r'[^A-F]'), '');
      if (answer.isEmpty || options.length < 2) continue;
    } else if (type == QType.judge) {
      answer = RegExp(r'^(对|正确|true|√|T)', caseSensitive: false).hasMatch(answer) ? '对' : '错';
    } else {
      answer = fix(answer);
      if (answer.isEmpty && problems.length == before) continue;
    }
    final expl = fix('${m['explanation'] ?? ''}');
    if (problems.length > before) {
      if (rejects != null) {
        String raw(Object? v) => LatexUtil.autoFix('${v ?? ''}'.trim());
        final rawOpts = ((m['options'] as List?) ?? [])
            .map((e) => raw('$e'.replaceFirst(RegExp(r'^\s*[A-Fa-f][\.．、:：]\s*'), '')))
            .toList();
        var rawAns = '${m['answer'] ?? ''}'.trim();
        if (type == QType.single || type == QType.multi) rawAns = rawAns.toUpperCase().replaceAll(RegExp(r'[^A-F]'), '');
        if (type == QType.judge) rawAns = answer;
        if (raw(m['stem']).isNotEmpty) {
          rejects.add(RawReject(
              issue: '公式无法渲染：${problems.sublist(before).take(2).join('；')}',
              q: Question(
                id: newId(),
                projectId: projectId,
                kpId: kp?.id ?? '',
                docId: kp?.docId ?? '',
                chapter: kp?.chapter ?? '',
                section: kp?.section ?? '',
                type: type,
                stem: raw(m['stem']),
                options: (type == QType.single || type == QType.multi) ? rawOpts : const [],
                answer: type == QType.judge || type == QType.single || type == QType.multi ? rawAns : raw(m['answer']),
                explanation: raw(m['explanation']),
                difficulty: '${m['difficulty'] ?? '中等'}',
                page: asInt(m['page'], kp?.page ?? 0),
              )));
        }
      }
      continue;
    }
    qs.add(Question(
      id: newId(),
      projectId: projectId,
      kpId: kp?.id ?? '',
      docId: kp?.docId ?? '',
      chapter: kp?.chapter ?? '',
      section: kp?.section ?? '',
      type: type,
      stem: stem,
      options: (type == QType.single || type == QType.multi) ? options : const [],
      answer: answer,
      explanation: expl,
      difficulty: '${m['difficulty'] ?? '中等'}',
      page: asInt(m['page'], kp?.page ?? 0),
    ));
  }
  return (cards, qs, problems);
}

// ================= 判分 =================

String _norm(String s) => s
    .replaceAll(RegExp(r'[\s\$]'), '')
    .replaceAll('，', ',')
    .replaceAll('：', ':')
    .replaceAll(r'\left', '')
    .replaceAll(r'\right', '')
    .replaceAll(r'\dfrac', r'\frac')
    .toLowerCase();

/// 客观题自动判分。
bool gradeObjective(Question q, String userAnswer) {
  switch (q.type) {
    case QType.single:
    case QType.multi:
      final a = (q.answer.toUpperCase().split('')..sort()).join();
      final u = (userAnswer.toUpperCase().replaceAll(RegExp(r'[^A-F]'), '').split('')..sort()).join();
      return a == u;
    case QType.judge:
      return q.answer == userAnswer;
    case QType.fill:
      return q.answer.split('|').map(_norm).contains(_norm(userAnswer));
    default:
      return false;
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
