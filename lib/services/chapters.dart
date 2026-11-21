import 'dart:math';
import 'dart:typed_data';

import '../data/repository.dart';
import '../models.dart';
import 'llm.dart';
import 'pdf_tools.dart';
import 'pipeline.dart';
import 'settings.dart';

// ================= 分章：识别、校验、编辑（纯函数，可单测） =================

const chapterSourceNames = {
  'outline': 'PDF 书签',
  'toc': '目录页',
  'heading': '标题识别',
  'ai': 'AI 分章',
  'fixed': '按页数切分',
  'manual': '手动编辑',
  'single': '全文一章',
};

/// 一级标题：第一章 / 第 1 章 / 第三讲 / 第二篇 / Chapter 1 / Lecture 3 / Unit 2 / Part II
final _tier1 = RegExp(
    r'^(第\s*[一二三四五六七八九十百零〇两\d]+\s*[章篇讲部]|(chapter|lecture|unit|part)\s*[\dIVXLC]+\b)',
    caseSensitive: false);

/// 二级：一、xxx
final _tier2 = RegExp(r'^[一二三四五六七八九十]+\s*[、.．]\s*\S');

/// 三级：第一节 / §1.2 / （一） / 1.2 / 1.2.3 xxx
final _tier3 = RegExp(r'^(第\s*[一二三四五六七八九十\d]+\s*节|§\s*\d+|[（(][一二三四五六七八九十]+[）)]\s*\S|\d+(\.\d+){1,2}\s*\S)');

final _md = RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$');
final _tocLine = RegExp(r'^(.{2,48}?)\s*[\.．·•…\-—_ ]{2,}\s*(\d{1,4})\s*$');
final _tocTitle = RegExp(r'^\s*(目\s*录|contents|table of contents)\s*$', caseSensitive: false);

/// 清理一行：去掉 Markdown 标题符号、加粗符号、多余空白。
String cleanHeading(String line) => line
    .replaceFirst(RegExp(r'^\s*#+\s*'), '')
    .replaceAll('**', '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _norm(String s) => s.replaceAll(RegExp(r'[\s\*#]'), '').toLowerCase();

/// 标题的「编号键」，用来合并页眉里重复出现的同一章（如「第一章 概率」与「第一章 随机事件与概率」）。
String _key(String title) {
  final m = _tier1.firstMatch(title);
  return m != null ? _norm(m[0]!) : _norm(title);
}

bool _isTocPage(String text) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.take(4).any(_tocTitle.hasMatch)) return true;
  return lines.where(_tocLine.hasMatch).length >= 5;
}

/// 把若干「标题 + 起始页」整理成覆盖全部页、无重叠、单调递增的章节列表。
/// 第一章之前的页（封面、前言、目录）合成「前置内容」。无效时返回空列表。
List<ChapterRange> normalizeRanges(List<(String, int)> starts, int total) {
  if (total <= 0) return [];
  final s = starts
      .map((e) => (cleanHeading(e.$1), e.$2))
      .where((e) => e.$1.isNotEmpty && e.$2 >= 1 && e.$2 <= total)
      .toList()
    ..sort((a, b) => a.$2.compareTo(b.$2));
  final out = <ChapterRange>[];
  for (final e in s) {
    if (out.isNotEmpty && out.last.start == e.$2) continue; // 同一页多个标题取第一个
    out.add(ChapterRange(e.$1.length > 40 ? '${e.$1.substring(0, 40)}…' : e.$1, e.$2, e.$2));
  }
  if (out.isEmpty) return [];
  if (out.first.start > 1) out.insert(0, ChapterRange('前置内容', 1, out.first.start - 1));
  for (var i = 0; i < out.length; i++) {
    out[i].end = i + 1 < out.length ? out[i + 1].start - 1 : total;
  }
  return out;
}

/// 校验：从第 1 页开始、连续覆盖到最后一页、每章至少 1 页、标题非空。
bool validRanges(List<ChapterRange> l, int total) {
  if (l.isEmpty || l.first.start != 1 || l.last.end != total) return false;
  for (var i = 0; i < l.length; i++) {
    if (l[i].title.trim().isEmpty || l[i].end < l[i].start) return false;
    if (i > 0 && l[i].start != l[i - 1].end + 1) return false;
  }
  return true;
}

/// 按固定页数切分：「第 1–10 页」（Word 为「第 1–5 节」）。
List<ChapterRange> fixedRanges(int total, int every, {bool word = false}) {
  final unit = word ? '节' : '页';
  final n = max(1, every);
  return [
    for (var s = 1; s <= total; s += n)
      ChapterRange('第 $s–${min(total, s + n - 1)} $unit', s, min(total, s + n - 1)),
  ];
}

/// 自动兜底的切分页数：PDF 每 10 页（超过 150 页时控制在约 15 章），Word 每 5 节。
int defaultEvery(int total, {bool word = false}) => word ? 5 : (total > 150 ? (total / 15).ceil() : 10);

/// (a) PDF 书签：取第一个至少有 2 条的层级（只有一个根书签时自动下钻一层）。
List<ChapterRange> rangesFromOutline(List<(String, int, int)> entries, int total) {
  if (entries.isEmpty) return [];
  final levels = entries.map((e) => e.$3).toSet().toList()..sort();
  for (final lv in levels) {
    final at = entries.where((e) => e.$3 == lv).toList();
    if (at.length >= 2) {
      final r = normalizeRanges([for (final e in at) (e.$1, e.$2)], total);
      if (r.where((c) => c.title != '前置内容').length >= 2) return r;
    }
  }
  return [];
}

/// (d) 目录页：读取「第一章 xxx …… 12」这样的行，再到正文里找到对应标题，推算印刷页码与实际页码的偏移。
List<ChapterRange> rangesFromToc(List<PageText> pages) {
  if (pages.isEmpty) return [];
  final total = pages.last.page;
  final tocPages = pages.take(25).where((p) => _isTocPage(p.text)).toList();
  if (tocPages.isEmpty) return [];
  final entries = <(String, int)>[];
  for (final p in tocPages) {
    for (final l in p.text.split('\n')) {
      final m = _tocLine.firstMatch(cleanHeading(l));
      if (m != null) entries.add((m[1]!.trim(), int.parse(m[2]!)));
    }
  }
  var top = entries.where((e) => _tier1.hasMatch(e.$1)).toList();
  if (top.length < 2) top = entries.where((e) => _tier2.hasMatch(e.$1)).toList();
  if (top.length < 2) return [];
  final lastToc = tocPages.last.page;
  final offsets = <int>[];
  final found = <int, int>{};
  for (var i = 0; i < top.length; i++) {
    final want = _norm(top[i].$1);
    for (final p in pages.where((p) => p.page > lastToc)) {
      if (p.text.split('\n').any((l) {
        final n = _norm(cleanHeading(l));
        return n.isNotEmpty && n.length <= want.length + 6 && n.startsWith(want.substring(0, min(want.length, 8)));
      })) {
        found[i] = p.page;
        offsets.add(p.page - top[i].$2);
        break;
      }
    }
  }
  if (offsets.isEmpty) return [];
  offsets.sort();
  final off = offsets[offsets.length ~/ 2];
  final r = normalizeRanges([for (var i = 0; i < top.length; i++) (top[i].$1, found[i] ?? top[i].$2 + off)], total);
  return r.where((c) => c.title != '前置内容').length >= 2 ? r : [];
}

/// (b)(c) 标题识别：依次尝试「第X章 / Chapter」、Markdown 最高级标题、「一、」、「第X节 / §1.2 / 1.2」。
/// 跳过目录页；同一编号只取第一次出现（页眉重复不影响）；容忍 OCR 产生的多余空格。
List<ChapterRange> rangesFromHeadings(List<PageText> pages) {
  if (pages.isEmpty) return [];
  final total = pages.last.page;
  final cands = <(String, int, int, int?)>[]; // 标题, 页, 层级(1/2/3/0), md 级别
  for (final p in pages) {
    if (_isTocPage(p.text)) continue;
    for (final raw in p.text.split('\n')) {
      final md = _md.firstMatch(raw);
      final t = cleanHeading(raw);
      if (t.isEmpty || t.length > 40 || _tocLine.hasMatch(t)) continue;
      final tier = _tier1.hasMatch(t) ? 1 : (_tier2.hasMatch(t) ? 2 : (_tier3.hasMatch(t) ? 3 : 0));
      if (tier == 0 && md == null) continue;
      cands.add((t, p.page, tier, md?[1]!.length));
    }
  }
  List<ChapterRange> pick(Iterable<(String, int, int, int?)> l) {
    final seen = <String>{};
    final starts = <(String, int)>[];
    for (final c in l) {
      if (seen.add(_key(c.$1))) starts.add((c.$1, c.$2));
    }
    final r = normalizeRanges(starts, total);
    return r.where((c) => c.title != '前置内容').length >= 2 ? r : [];
  }

  var r = pick(cands.where((c) => c.$3 == 1));
  if (r.isNotEmpty) return r;
  final mdLevels = cands.map((c) => c.$4).whereType<int>().toSet().toList()..sort();
  for (final lv in mdLevels.take(2)) {
    r = pick(cands.where((c) => c.$4 == lv));
    if (r.isNotEmpty) return r;
  }
  r = pick(cands.where((c) => c.$3 == 2));
  if (r.isNotEmpty) return r;
  // 「1.2」这类只取到第一级编号（1.x 归为第 1 部分），避免切得过碎
  final t3 = cands.where((c) => c.$3 == 3).toList();
  r = pick(t3);
  if (r.isNotEmpty && r.length <= max(30, total ~/ 3)) return r;
  return [];
}

/// 不调用 AI 的自动识别：书签 → 目录页 → 标题识别。
(List<ChapterRange>, String) detectChapters(List<PageText> pages, {List<(String, int, int)> outline = const []}) {
  if (pages.isEmpty) return (<ChapterRange>[], 'single');
  final total = pages.last.page;
  var r = rangesFromOutline(outline, total);
  if (r.isNotEmpty) return (r, 'outline');
  r = rangesFromToc(pages);
  if (r.isNotEmpty) return (r, 'toc');
  r = rangesFromHeadings(pages);
  if (r.isNotEmpty) return (r, 'heading');
  return (<ChapterRange>[], 'single');
}

/// 给 AI 的精简大纲：每页前两行（每行最多 50 字）+ 目录页原文。控制在约 2 万字以内。
String buildOutline(List<PageText> pages, {bool word = false, int budget = 20000}) {
  final unit = word ? '节' : '页';
  final b = StringBuffer();
  final toc = pages.take(25).where((p) => _isTocPage(p.text)).map((p) => p.text).join('\n');
  if (toc.isNotEmpty) b.writeln('【目录页原文】\n${toc.length > 3000 ? toc.substring(0, 3000) : toc}\n');
  b.writeln('【每$unit开头】');
  final perLine = pages.length > 300 ? 1 : 2;
  for (final p in pages) {
    final lines = p.text
        .split('\n')
        .map(cleanHeading)
        .where((l) => l.isNotEmpty && !RegExp(r'^[\d\s\-—第页]+$').hasMatch(l) && !l.startsWith('[第'))
        .take(perLine)
        .map((l) => l.length > 50 ? l.substring(0, 50) : l);
    b.writeln('${p.page}: ${lines.join(' / ')}');
    if (b.length > budget) break;
  }
  return b.toString();
}

/// 校验 AI 返回的章节：只信任 title 与 startPage，结束页由下一章推出，保证覆盖全部页且不重叠。
List<ChapterRange> rangesFromAi(Map<String, dynamic> j, int total) {
  final raw = j['chapters'];
  final list = raw is List ? raw : const [];
  final starts = <(String, int)>[];
  for (final e in list) {
    if (e is! Map) continue;
    final s = int.tryParse('${e['startPage'] ?? e['start'] ?? ''}');
    final t = '${e['title'] ?? ''}'.trim();
    if (s != null && t.isNotEmpty) starts.add((t, s));
  }
  final r = normalizeRanges(starts, total);
  if (r.isEmpty) return [];
  if (total > 10 && r.length < 2) return [];
  return validRanges(r, total) ? r : [];
}

// ---------- 编辑操作（返回新列表，原列表不变） ----------
List<ChapterRange> _clone(List<ChapterRange> l) => [for (final c in l) c.copy()];

List<ChapterRange> renameChapter(List<ChapterRange> l, int i, String title) {
  final o = _clone(l);
  if (title.trim().isNotEmpty) o[i].title = title.trim();
  return o;
}

/// 在第 [page] 页把第 i 章拆成两章，后半部分叫 [title]。
List<ChapterRange> splitChapter(List<ChapterRange> l, int i, int page, String title) {
  final o = _clone(l);
  final c = o[i];
  if (page <= c.start || page > c.end) return o;
  o.insert(i + 1, ChapterRange(title.trim().isEmpty ? '新章节' : title.trim(), page, c.end));
  c.end = page - 1;
  return o;
}

/// 新增章节：从第 [page] 页开始（落在哪一章就拆哪一章）。
List<ChapterRange> addChapter(List<ChapterRange> l, int page, String title) {
  final i = l.indexWhere((c) => page >= c.start && page <= c.end);
  if (i < 0) return _clone(l);
  if (l[i].start == page) return renameChapter(l, i, title);
  return splitChapter(l, i, page, title);
}

List<ChapterRange> mergeWithNext(List<ChapterRange> l, int i) {
  final o = _clone(l);
  if (i < 0 || i >= o.length - 1) return o;
  o[i].end = o[i + 1].end;
  o.removeAt(i + 1);
  return o;
}

/// 删除第 i 章：它的页并入上一章（删第一章时并入下一章）。
List<ChapterRange> deleteChapter(List<ChapterRange> l, int i) {
  final o = _clone(l);
  if (o.length <= 1) return o;
  if (i == 0) {
    o[1].start = o[0].start;
  } else {
    o[i - 1].end = o[i].end;
  }
  o.removeAt(i);
  return o;
}

/// 调整第 i 章的起始页（上一章的结束页随之改变）。
List<ChapterRange> setChapterStart(List<ChapterRange> l, int i, int page) {
  final o = _clone(l);
  if (i <= 0 || i >= o.length) return o;
  if (page <= o[i - 1].start || page > o[i].end) return o;
  o[i].start = page;
  o[i - 1].end = page - 1;
  return o;
}

// ================= 服务：识别 + AI 分章 + 应用到切块和已生成的内容 =================

const _aiPrompt = '''下面是一本教材（或讲义）的精简大纲：每一{{unit}}开头的一两行文字，以及可能存在的目录页原文。
请据此把全书划分为若干「章」，标题尽量使用原书的章名；没有明显章名时，按内容主题概括一个简短标题（不超过 16 字）。
要求：
1. 共 {{total}} {{unit}}，章节按顺序排列，第一章从第 1 {{unit}}开始，最后一章到第 {{total}} {{unit}}结束，不重叠、不遗漏；
2. 章节数量合适（一般 3–20 章），不要把小节当成章；
3. 只输出 json：{"chapters":[{"title":"章名","startPage":1,"endPage":12}]}

{{outline}}''';

class ChapterService {
  final Repository repo;
  final Settings settings;
  final Future<LlmClient?> Function()? llm; // 没有配置密钥时返回 null
  ChapterService(this.repo, this.settings, {this.llm});

  Future<List<(String, int, int)>> _outline(PdfDoc doc, Uint8List? bytes) async {
    if (doc.isSectioned || bytes == null) return const [];
    try {
      return await PdfTools.outline(bytes);
    } catch (_) {
      return const [];
    }
  }

  /// AI 分章（每份资料只调用一次）。失败返回空列表。
  Future<List<ChapterRange>> aiRanges(PdfDoc doc, List<PageText> pages) async {
    if (pages.isEmpty) return [];
    final client = await llm?.call();
    if (client == null) return [];
    final total = pages.last.page;
    final unit = doc.isSectioned ? '节' : '页';
    try {
      final j = await client.chatJson(_aiPrompt
          .replaceAll('{{unit}}', unit)
          .replaceAll('{{total}}', '$total')
          .replaceAll('{{outline}}', buildOutline(pages, word: doc.isSectioned)));
      return rangesFromAi(j, total);
    } catch (_) {
      return [];
    }
  }

  /// 自动分章：手动编辑过的方案保留（仅按新页数修正）；否则 书签 → 目录页 → 标题识别 →（不足 2 章时）AI → 按页数切分。
  Future<ChapterPlan> autoPlan(PdfDoc doc, {Uint8List? bytes, bool allowAi = true, bool keepManual = true, Progress? onProgress}) async {
    final pages = await repo.pages(doc.projectId, docId: doc.id);
    final total = max(max(1, doc.pageCount), pages.isEmpty ? 0 : pages.last.page);
    final old = await repo.chapterPlan(doc.id);
    if (keepManual && old != null && old.source == 'manual') {
      final fixed = normalizeRanges([for (final c in old.chapters) (c.title, c.start)], total);
      if (fixed.isNotEmpty) return ChapterPlan(docId: doc.id, projectId: doc.projectId, source: 'manual', chapters: fixed);
    }
    onProgress?.call('正在识别章节…', 0.9);
    var (r, src) = detectChapters(pages, outline: await _outline(doc, bytes));
    if (r.isEmpty && total <= 5) {
      r = [ChapterRange(doc.name, 1, total)];
      src = 'single';
    }
    if (r.isEmpty && allowAi) {
      onProgress?.call('没有识别到章节，正在让 AI 分章…', 0.93);
      r = await aiRanges(doc, pages);
      src = 'ai';
    }
    if (r.isEmpty) {
      r = fixedRanges(total, defaultEvery(total, word: doc.isSectioned), word: doc.isSectioned);
      src = 'fixed';
    }
    return ChapterPlan(docId: doc.id, projectId: doc.projectId, source: src, chapters: r);
  }

  /// 保存方案并重新切块；已生成的知识点、闪卡、题目按出处页码重新归章。
  Future<void> apply(PdfDoc doc, ChapterPlan plan) async {
    await repo.saveChapterPlan(plan);
    final pages = await repo.pages(doc.projectId, docId: doc.id);
    await repo.replaceChunks(
        doc.projectId, doc.id, chunkPages(doc.projectId, doc.id, pages, mdHeadings: doc.isSectioned, chapterOf: plan.titleFor));
    await reassign(doc.projectId, doc.id, plan);
  }

  Future<void> reassign(String projectId, String docId, ChapterPlan plan) async {
    final kps = (await repo.kps(projectId)).where((k) => k.docId == docId && k.page > 0).toList();
    for (final k in kps) {
      final t = plan.titleFor(k.page);
      if (t != k.chapter) {
        k.chapter = t;
        k.section = '';
      }
    }
    await repo.saveKps(kps);
    final cards = (await repo.cards(projectId: projectId)).where((c) => c.docId == docId && c.page > 0).toList();
    for (final c in cards) {
      final t = plan.titleFor(c.page);
      if (t != c.chapter) {
        c.chapter = t;
        c.section = '';
      }
    }
    await repo.saveCards(cards);
    final qs = (await repo.questions(projectId: projectId)).where((q) => q.docId == docId && q.page > 0).toList();
    for (final q in qs) {
      final t = plan.titleFor(q.page);
      if (t != q.chapter) {
        q.chapter = t;
        q.section = '';
      }
    }
    await repo.saveQuestions(qs);
  }
}
