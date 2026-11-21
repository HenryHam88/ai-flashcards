/// 按章节重新解析和重新分析知识点。
///
/// - 重新解析：只对这一章的页面用选定的引擎再解析一次，先放在内存里给用户对比，确认后才写入；
///   写入前把旧文字存成「恢复上次解析」的快照。分章不变，已生成的闪卡和题目不做任何修改。
/// - 重新分析知识点：清除这一章知识点的缓存后重新提取，自动数量和出题之后用新的知识点。
/// 整份资料的解析流程（ParseService.parseDoc）不受影响。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../data/repository.dart';
import '../models.dart';
import 'latex.dart';
import 'ocr.dart';
import 'pdf_tools.dart';
import 'pipeline.dart';
import 'settings.dart';
import 'text_import.dart';

/// 重新解析使用的引擎。
enum ReparseEngine { deepseekText, deepseekRich, kimi, local, txt }

extension ReparseEngineX on ReparseEngine {
  String get label => switch (this) {
    ReparseEngine.deepseekText => 'DeepSeek OCR · 文字模式',
    ReparseEngine.deepseekRich => 'DeepSeek OCR · 版面模式',
    ReparseEngine.kimi => 'Kimi',
    ReparseEngine.local => '本地（PDF 文字层）',
    ReparseEngine.txt => '本地重新读取 TXT',
  };

  /// 写进 PageText.source 的来源标记。
  String get sourceTag => switch (this) {
    ReparseEngine.deepseekText => 'deepseek_text',
    ReparseEngine.deepseekRich => 'deepseek_rich',
    ReparseEngine.kimi => 'kimi',
    ReparseEngine.local => 'local',
    ReparseEngine.txt => 'txt',
  };

  bool get online => this != ReparseEngine.local && this != ReparseEngine.txt;
}

/// 这份资料能用的引擎；Word 返回空列表（见 [reparseUnsupported]）。
List<ReparseEngine> enginesFor(PdfDoc doc) {
  if (doc.isText) return [ReparseEngine.txt];
  if (doc.isWord) return [];
  return [ReparseEngine.deepseekText, ReparseEngine.deepseekRich, ReparseEngine.kimi, ReparseEngine.local];
}

/// 不能按章重新解析的原因；能解析返回 null。
String? reparseUnsupported(PdfDoc doc) => doc.isWord
    ? 'Word 没有固定页码，解析模型只能整份解析，切出的小节数每次可能不同，无法只替换这一章。'
          '如需重新解析，请在项目页对这份资料选择「重新解析」（整份），或把文档另存为 PDF 后上传。'
    : null;

/// 默认引擎：跟随「文档解析」设置。
ReparseEngine defaultEngine(PdfDoc doc, Settings s) {
  if (doc.isText) return ReparseEngine.txt;
  return switch (s.ocrProvider) {
    OcrProvider.deepseek =>
      s.ocrModes.first == Settings.ocrRich ? ReparseEngine.deepseekRich : ReparseEngine.deepseekText,
    OcrProvider.kimi => ReparseEngine.kimi,
    OcrProvider.local => ReparseEngine.local,
  };
}

/// 预估说明：页数、批次和费用提示。
String reparseEstimate(PdfDoc doc, ChapterRange r, ReparseEngine e, {int batch = 30}) {
  final n = r.end - r.start + 1;
  final unit = doc.isSectioned ? '节' : '页';
  if (e == ReparseEngine.txt) return '重新读取整个 TXT 文件，只替换这一章的 $n 个小节 · 在手机上读取，免费、不联网';
  if (e == ReparseEngine.local) return '共 $n $unit · 读取 PDF 自带的文字层，免费、不联网（扫描版没有文字层）';
  final batches = (n / max(1, batch)).ceil();
  return '共 $n $unit，分 $batches 批上传 · 按 ${e.label} 的实际用量计费，约等于解析 $n $unit的费用；'
      '只上传这一章的页面';
}

class ReparseCancelled implements Exception {
  @override
  String toString() => '已取消';
}

class ReparseException implements Exception {
  final String message;
  ReparseException(this.message);
  @override
  String toString() => message;
}

/// 取消标记：解析在每一批之间检查。
class CancelToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw ReparseCancelled();
  }
}

/// 一页的新旧对比和用户的选择。
class ReparsePage {
  final int page;
  final String oldText, oldSource;
  final bool oldParsed;
  final String newText, newSource;

  /// 这一页解析失败：只能保留旧的。
  final bool failed;
  bool useNew;
  ReparsePage(
    this.page, {
    required this.oldText,
    required this.oldSource,
    required this.oldParsed,
    required this.newText,
    required this.newSource,
    this.failed = false,
  }) : useNew = !failed;
  bool get changed => !failed && (newText.trim() != oldText.trim() || !oldParsed);
}

class ReparseResult {
  final PdfDoc doc;
  final ChapterRange range;
  final ReparseEngine engine;
  final List<ReparsePage> pages;
  ReparseResult(this.doc, this.range, this.engine, this.pages);
  int get changedCount => pages.where((p) => p.changed).length;
  int get failedCount => pages.where((p) => p.failed).length;
  List<ReparsePage> get chosen => pages.where((p) => p.useNew && p.changed).toList();
}

/// 一次「恢复上次解析」的快照（每章一条，id = docId_start-end）。
class ReparseSnapshot {
  final String docId, projectId, title, engine;
  final int start, end;
  final DateTime at;
  final List<PageText> pages; // 替换前的页（只含被替换的页）
  final List<int> missing; // 替换前还没有解析的页（恢复时删除）
  ReparseSnapshot({
    required this.docId,
    required this.projectId,
    required this.title,
    required this.start,
    required this.end,
    required this.engine,
    required this.at,
    required this.pages,
    this.missing = const [],
  });
  static String idFor(String docId, int start, int end) => '${docId}_$start-$end';
  String get id => idFor(docId, start, end);
  Map<String, dynamic> toJson() => {
    'id': id,
    'docId': docId,
    'projectId': projectId,
    'title': title,
    'start': start,
    'end': end,
    'engine': engine,
    'at': at.toIso8601String(),
    'pages': [for (final p in pages) p.toJson()],
    'missing': missing,
  };
  factory ReparseSnapshot.fromJson(Map<String, dynamic> j) => ReparseSnapshot(
    docId: j['docId'],
    projectId: j['projectId'] ?? '',
    title: j['title'] ?? '',
    start: (j['start'] as num).toInt(),
    end: (j['end'] as num).toInt(),
    engine: j['engine'] ?? '',
    at: DateTime.tryParse(j['at'] ?? '') ?? DateTime.now(),
    pages: [for (final p in (j['pages'] as List? ?? [])) PageText.fromJson(Map<String, dynamic>.from(p))],
    missing: [for (final m in (j['missing'] as List? ?? [])) (m as num).toInt()],
  );
}

/// 知识点对比：新列表里每条是「新增」还是「保留」，旧列表里没出现在新列表的是「移除」。
class KpDiff {
  final List<KnowledgePoint> oldKps, newKps;
  final Set<String> addedIds, removedIds;
  KpDiff(this.oldKps, this.newKps, this.addedIds, this.removedIds);
  factory KpDiff.of(List<KnowledgePoint> oldKps, List<KnowledgePoint> newKps, {double threshold = 0.75}) {
    bool has(List<KnowledgePoint> l, KnowledgePoint k) => l.any((o) => similarity(o.title, k.title) >= threshold);
    return KpDiff(
      oldKps,
      newKps,
      {
        for (final k in newKps)
          if (!has(oldKps, k)) k.id,
      },
      {
        for (final k in oldKps)
          if (!has(newKps, k)) k.id,
      },
    );
  }
}

typedef BatchFetcher = Future<List<String>> Function(ReparseEngine engine, int from, int to);

class ChapterReparseService {
  final Repository repo;
  final Settings settings;
  final http.Client? httpClient;

  /// 测试用：直接返回某一批页的文字。
  final BatchFetcher? fetchOverride;

  /// 测试用：TXT 文件内容。
  final Uint8List? bytesOverride;

  /// 测试用：重试间隔。
  final Duration retryDelay;
  ChapterReparseService(
    this.repo,
    this.settings, {
    this.httpClient,
    this.fetchOverride,
    this.bytesOverride,
    this.retryDelay = const Duration(seconds: 2),
  });

  Future<PdfParser> _parser(ReparseEngine e) async => switch (e) {
    ReparseEngine.kimi => KimiFileExtract(
      baseUrl: settings.kimiBaseUrl,
      apiKey: await settings.kimiKey(),
      client: httpClient,
    ),
    _ => DeepSeekOcr(
      baseUrl: settings.ocrBaseUrl,
      apiKey: await settings.ocrKey(),
      purpose: e == ReparseEngine.deepseekRich ? Settings.ocrRich : Settings.ocrText,
      client: httpClient,
    ),
  };

  Future<Uint8List> _bytes(PdfDoc doc) async {
    if (bytesOverride != null) return bytesOverride!;
    final f = File(doc.path);
    if (doc.path.isEmpty || !await f.exists()) throw ReparseException('找不到原文件，可能已被删除，请重新上传这份资料');
    return f.readAsBytes();
  }

  /// 重新解析这一章：只读取 / 上传 [range] 内的页，结果只放在内存里，不写入任何数据。
  /// 每一批之间检查 [cancel]；取消时抛 [ReparseCancelled]，原有数据不受影响。
  Future<ReparseResult> run(
    PdfDoc doc,
    ChapterRange range,
    ReparseEngine engine, {
    Progress? onProgress,
    CancelToken? cancel,
  }) async {
    final why = reparseUnsupported(doc);
    if (why != null) throw ReparseException(why);
    if (!enginesFor(doc).contains(engine)) throw ReparseException('这份资料不能用 ${engine.label} 重新解析');
    final old = {for (final p in await repo.pages(doc.projectId, docId: doc.id)) p.page: p};
    final texts = <int, String>{};
    final failed = <int>{};
    if (doc.isText) {
      onProgress?.call('正在重新读取 TXT…', 0.3);
      final decoded = decodeTextBytes(await _bytes(doc));
      final sections = splitTextPages(cleanImportedText(decoded.text));
      final before = old.isEmpty ? doc.pageCount : old.keys.reduce(max);
      if (sections.length != before) {
        throw ReparseException('文件内容和上次读取时不一样（小节数 $before → ${sections.length}），无法只替换这一章，请在项目页重新解析整份资料');
      }
      for (var p = range.start; p <= range.end && p <= sections.length; p++) {
        texts[p] = sections[p - 1];
      }
      cancel?.check();
    } else {
      final batch = settings.ocrBatchPages.clamp(1, 1000);
      final batches = [for (var f = range.start; f <= range.end; f += batch) (f, min(range.end, f + batch - 1))];
      Uint8List? bytes;
      PdfParser? parser;
      for (var bi = 0; bi < batches.length; bi++) {
        cancel?.check();
        final (from, to) = batches[bi];
        onProgress?.call('第 $from–$to 页 · ${bi + 1}/${batches.length} 批', bi / batches.length);
        List<String>? got;
        Object? err;
        for (var attempt = 0; attempt < 3 && got == null; attempt++) {
          cancel?.check();
          try {
            if (fetchOverride != null) {
              got = await fetchOverride!(engine, from, to);
            } else {
              bytes ??= await _bytes(doc);
              if (engine == ReparseEngine.local) {
                got = await PdfTools.extractText(bytes, from, to);
              } else {
                parser ??= await _parser(engine);
                final part = await PdfTools.slice(bytes, from, to);
                final r = await parser.parse(part, '${doc.name}_p$from-$to.pdf', to - from + 1);
                got = [for (var i = 0; i <= to - from; i++) i < r.pages.length ? r.pages[i].text : ''];
              }
            }
          } on ReparseException {
            rethrow;
          } catch (e) {
            err = e;
            if (e is OcrException && (e.message.contains('401') || e.message.contains('密钥'))) {
              throw ReparseException(e.message);
            }
            onProgress?.call('第 $from–$to 页失败，重试中（${attempt + 1}/3）', bi / batches.length);
            await Future.delayed(retryDelay * (attempt + 1));
          }
        }
        if (got == null) {
          for (var p = from; p <= to; p++) {
            failed.add(p);
          }
          if (batches.length == 1) throw ReparseException('解析失败：$err');
          continue;
        }
        for (var p = from; p <= to; p++) {
          final i = p - from;
          texts[p] = LatexUtil.normalize(i < got.length ? got[i] : '');
        }
      }
      if (failed.length == range.end - range.start + 1) throw ReparseException('这一章的页面全部解析失败，请稍后重试或换一个引擎');
    }
    onProgress?.call('解析完成，正在对比', 1);
    return ReparseResult(doc, range, engine, [
      for (var p = range.start; p <= range.end; p++)
        ReparsePage(
          p,
          oldText: old[p]?.text ?? '',
          oldSource: old[p]?.source ?? '',
          oldParsed: old.containsKey(p),
          newText: texts[p] ?? '',
          newSource: engine.sourceTag,
          failed: failed.contains(p) || !texts.containsKey(p),
        ),
    ]);
  }

  /// 保存用户选择的新文字：先存快照（用于「恢复上次解析」），再一次性写入所选页，然后重新切块。
  /// 只改这一章被选中的页；分章、闪卡、题目都不变。重新切块失败时还原旧文字。返回替换的页数。
  Future<int> commit(ReparseResult r) async {
    final chosen = r.chosen;
    if (chosen.isEmpty) return 0;
    final doc = r.doc;
    final old = {for (final p in await repo.pages(doc.projectId, docId: doc.id)) p.page: p};
    final snap = ReparseSnapshot(
      docId: doc.id,
      projectId: doc.projectId,
      title: r.range.title,
      start: r.range.start,
      end: r.range.end,
      engine: r.engine.sourceTag,
      at: DateTime.now(),
      pages: [
        for (final p in chosen)
          if (old.containsKey(p.page)) old[p.page]!,
      ],
      missing: [
        for (final p in chosen)
          if (!old.containsKey(p.page)) p.page,
      ],
    );
    final oldChunks = await _docChunks(doc);
    await repo.saveReparseSnapshot(snap.id, snap.projectId, snap.toJson());
    await repo.savePages([
      for (final p in chosen)
        PageText(docId: doc.id, projectId: doc.projectId, page: p.page, text: p.newText, source: p.newSource),
    ]);
    try {
      await rechunk(doc, oldChunks: oldChunks);
    } catch (e) {
      // 还原：写回旧文字，删除原本没有的页，恢复切块
      await repo.savePages(snap.pages);
      for (final p in snap.missing) {
        await repo.deletePage(doc.id, p);
      }
      await repo.replaceChunks(doc.projectId, doc.id, oldChunks);
      await repo.deleteReparseSnapshot(snap.id);
      rethrow;
    }
    await _updateDocCount(doc);
    return chosen.length;
  }

  Future<ReparseSnapshot?> snapshot(PdfDoc doc, ChapterRange r) async {
    final j = await repo.reparseSnapshot(ReparseSnapshot.idFor(doc.id, r.start, r.end));
    return j == null ? null : ReparseSnapshot.fromJson(j);
  }

  /// 恢复上次解析：把快照里的旧文字写回，当前文字存成新的快照（再点一次可以换回来）。
  Future<int> undo(PdfDoc doc, ChapterRange r) async {
    final snap = await snapshot(doc, r);
    if (snap == null) return 0;
    final cur = {for (final p in await repo.pages(doc.projectId, docId: doc.id)) p.page: p};
    final touched = [...snap.pages.map((p) => p.page), ...snap.missing];
    final back = ReparseSnapshot(
      docId: doc.id,
      projectId: doc.projectId,
      title: snap.title,
      start: snap.start,
      end: snap.end,
      engine: snap.engine,
      at: DateTime.now(),
      pages: [
        for (final p in touched)
          if (cur.containsKey(p)) cur[p]!,
      ],
      missing: [
        for (final p in touched)
          if (!cur.containsKey(p)) p,
      ],
    );
    final oldChunks = await _docChunks(doc);
    await repo.savePages(snap.pages);
    for (final p in snap.missing) {
      await repo.deletePage(doc.id, p);
    }
    await repo.saveReparseSnapshot(back.id, back.projectId, back.toJson());
    await rechunk(doc, oldChunks: oldChunks);
    await _updateDocCount(doc);
    return touched.length;
  }

  Future<void> _updateDocCount(PdfDoc doc) async {
    final n = (await repo.pages(doc.projectId, docId: doc.id)).length;
    doc.parsedPages = n;
    if (doc.status == '部分失败' && n >= doc.pageCount && doc.pageCount > 0) doc.status = '已解析';
    await repo.saveDoc(doc);
  }

  Future<List<Chunk>> _docChunks(PdfDoc doc) async =>
      (await repo.chunks(doc.projectId)).where((c) => c.docId == doc.id).toList();

  /// 按已保存的分章方案重新切块（不改分章、不改闪卡和题目）。
  /// 知识点缓存：内容没变的块继续用原来的知识点（块序号变了也会迁移过去）；内容变了的块下次重新提取。
  Future<void> rechunk(PdfDoc doc, {List<Chunk>? oldChunks}) async {
    final before = oldChunks ?? await _docChunks(doc);
    final plan = await repo.chapterPlan(doc.id);
    final pages = await repo.pages(doc.projectId, docId: doc.id);
    final fresh = chunkPages(doc.projectId, doc.id, pages, mdHeadings: doc.isSectioned, chapterOf: plan?.titleFor);
    await repo.replaceChunks(doc.projectId, doc.id, fresh);
    final kps = (await repo.kps(doc.projectId)).where((k) => k.docId == doc.id).toList();
    List<KnowledgePoint> kpsOf(String chunkId) => kps.where((k) => k.id.startsWith('${chunkId}_k')).toList();
    final oldById = {for (final c in before) c.id: c};
    final oldByText = <String, Chunk>{for (final c in before) '${c.chapter}\u0000${c.text}': c};
    final stale = <String>[];
    final copies = <KnowledgePoint>[];
    for (final c in fresh) {
      final same = oldById[c.id];
      if (same != null) {
        // 同一个 id（没有分章方案时 id 不含内容指纹）但内容变了：旧知识点作废
        if (same.text != c.text) stale.addAll(kpsOf(c.id).map((k) => k.id));
        continue;
      }
      final prev = oldByText['${c.chapter}\u0000${c.text}'];
      if (prev == null) continue;
      final list = kpsOf(prev.id);
      if (list.isEmpty || kpsOf(c.id).isNotEmpty) continue;
      for (final k in list) {
        final j = k.toJson()..['id'] = '${c.id}_k${k.id.substring('${prev.id}_k'.length)}';
        copies.add(KnowledgePoint.fromJson(j));
      }
    }
    if (stale.isNotEmpty) await repo.deleteKps(stale);
    if (copies.isNotEmpty) await repo.saveKps(copies);
  }

  /// 这一章当前的分块（按页码与章节范围相交）。
  Future<List<Chunk>> chapterChunks(PdfDoc doc, ChapterRange r) async =>
      (await _docChunks(doc)).where((c) => c.pageEnd >= r.start && c.pageStart <= r.end).toList()
        ..sort((a, b) => a.pageStart.compareTo(b.pageStart));

  /// 这一章已缓存的知识点（去重后）；还没分析过返回空列表。
  Future<List<KnowledgePoint>> chapterKps(PdfDoc doc, ChapterRange r) async {
    final chunks = await chapterChunks(doc, r);
    final kps = await repo.kps(doc.projectId);
    return dedupeKps(
      [for (final c in chunks) ...kps.where((k) => k.id.startsWith('${c.id}_k'))..toList()]
          .map((k) => KnowledgePoint.fromJson(k.toJson()))
          .toList(),
    );
  }

  /// 已分析过的块数 / 总块数（判断知识点是否需要重新分析）。
  Future<(int, int)> kpCoverage(PdfDoc doc, ChapterRange r) async {
    final chunks = await chapterChunks(doc, r);
    final kps = await repo.kps(doc.projectId);
    final done = chunks.where((c) => kps.any((k) => k.id.startsWith('${c.id}_k'))).length;
    return (done, chunks.length);
  }

  /// 清除这一章的知识点缓存（只删知识点记录，闪卡和题目不变）。返回清除的条数。
  Future<int> clearChapterKps(PdfDoc doc, ChapterRange r) async {
    final chunks = await chapterChunks(doc, r);
    final ids = [
      for (final k in await repo.kps(doc.projectId))
        if (chunks.any((c) => k.id.startsWith('${c.id}_k'))) k.id,
    ];
    await repo.deleteKps(ids);
    return ids.length;
  }

  /// 重新分析知识点：清除缓存后用出题模型重新提取。返回新旧对比。
  Future<KpDiff> reanalyzeKps(PdfDoc doc, ChapterRange r, GenerationService gen, {Progress? onProgress}) async {
    final old = await chapterKps(doc, r);
    final chunks = await chapterChunks(doc, r);
    if (chunks.isEmpty) throw ReparseException('这一章还没有解析出的文字');
    // 先提取到内存，成功后再替换缓存：失败时保留原来的知识点
    final backup = [
      for (final k in await repo.kps(doc.projectId))
        if (chunks.any((c) => k.id.startsWith('${c.id}_k'))) k,
    ];
    await clearChapterKps(doc, r);
    try {
      final fresh = await gen.extractKps(doc.projectId, chunks, onProgress ?? (_, _) {});
      return KpDiff.of(old, fresh);
    } catch (_) {
      await repo.saveKps(backup);
      rethrow;
    }
  }
}
