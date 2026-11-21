import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../data/repository.dart';
import '../models.dart';
import 'json_utils.dart';
import 'latex.dart';
import 'llm.dart';
import 'ocr.dart';
import 'pdf_tools.dart';
import 'prompts.dart';
import 'settings.dart';

typedef Progress = void Function(String message, double fraction);

// ================= 切块（纯函数，可单测） =================

final _chapterRe = RegExp(r'^\s*(#{1,2}\s*)?(第\s*[一二三四五六七八九十百零〇0-9]+\s*章.*|Chapter\s+\d+.*|CHAPTER\s+\d+.*)$');
final _sectionRe = RegExp(r'^\s*(#{2,3}\s*)?(第\s*[一二三四五六七八九十0-9]+\s*节.*|§\s*\d+(\.\d+)*.*|\d+\.\d+\s+\S.*)$');

/// 按章节把页文字切成块，每块记录章节名与页码范围；单块过长时再按字数切。
List<Chunk> chunkPages(String projectId, String docId, List<PageText> pages, {int maxChars = 5000}) {
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
        id: '${docId}_c${out.length}',
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
    for (final rawLine in p.text.split('\n')) {
      final line = rawLine.trimRight();
      final isCh = line.length < 40 && _chapterRe.hasMatch(line);
      final isSec = !isCh && line.length < 40 && _sectionRe.hasMatch(line);
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
  ParseService(this.repo, this.settings, {this.parserOverride});

  Future<PdfParser?> _parser(String purpose) async {
    if (parserOverride != null) return parserOverride;
    switch (settings.ocrProvider) {
      case OcrProvider.deepseek:
        return DeepSeekOcr(baseUrl: settings.ocrBaseUrl, apiKey: await settings.ocrKey(), purpose: purpose);
      case OcrProvider.kimi:
        return KimiFileExtract(baseUrl: settings.kimiBaseUrl, apiKey: await settings.kimiKey());
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
    final bytes = await File(doc.path).readAsBytes();
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
      for (var bi = 0; bi < batches.length; bi++) {
        final b = batches[bi];
        final frac = bi / batches.length;
        final modeName = settings.ocrProvider == OcrProvider.deepseek
            ? (b.purpose == Settings.ocrRich ? '版面' : '文字')
            : '';
        onProgress('第 ${b.from}–${b.to} 页${modeName.isEmpty ? '' : '（$modeName模式）'} · ${bi + 1}/${batches.length} 批', frac);
        final parser = parsers.containsKey(b.purpose) ? parsers[b.purpose] : (parsers[b.purpose] = await _parser(b.purpose));
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
          failed++;
          if (err is OcrException && err.message.contains('401')) throw err;
          continue;
        }
        await repo.savePages([
          for (var i = 0; i < texts.length; i++)
            PageText(docId: doc.id, projectId: doc.projectId, page: b.from + i, text: LatexUtil.normalize(texts[i]))
        ]);
        doc.parsedPages = (await repo.pages(doc.projectId, docId: doc.id)).length;
        await repo.saveDoc(doc);
      }
    }
    final pages = await repo.pages(doc.projectId, docId: doc.id);
    await repo.replaceChunks(doc.projectId, doc.id, chunkPages(doc.projectId, doc.id, pages));
    doc.parsedPages = pages.length;
    doc.status = failed == 0 ? '已解析' : '部分失败';
    await repo.saveDoc(doc);
    onProgress(failed == 0 ? '解析完成' : '$failed 批失败，可点重试继续', 1);
    return failed;
  }
}

// ================= 生成 =================

class GenerationResult {
  final int cards, questions, kps;
  GenerationResult(this.cards, this.questions, this.kps);
}

class GenerationService {
  final Repository repo;
  final Settings settings;
  final LlmClient llm;
  GenerationService(this.repo, this.settings, this.llm);

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

  /// 第 1–2 步：提取知识点（已提取过的块会复用），并去重。
  Future<List<KnowledgePoint>> extractKps(String projectId, List<Chunk> chunks, Progress p) async {
    final existing = await repo.kps(projectId);
    final result = <KnowledgePoint>[];
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      final cachedForChunk = existing.where((k) => k.id.startsWith('${c.id}_k')).toList();
      if (cachedForChunk.isNotEmpty) {
        result.addAll(cachedForChunk);
        continue;
      }
      p('提取知识点：${c.chapter} ${c.section}（${i + 1}/${chunks.length}）', 0.1 + 0.4 * i / chunks.length);
      final prompt = Prompts.fill(settings.prompt('kp'), {
        'chapter': c.chapter,
        'section': c.section,
        'pages': '${c.pageStart}–${c.pageEnd}',
        'text': c.text,
      });
      final j = await llm.chatJson(prompt);
      final list = listOfMaps(j['knowledge_points'] ?? j['items']);
      final kps = <KnowledgePoint>[];
      for (var k = 0; k < list.length; k++) {
        final m = list[k];
        kps.add(KnowledgePoint(
          id: '${c.id}_k$k',
          projectId: projectId,
          docId: c.docId,
          chapter: c.chapter,
          section: c.section,
          title: '${m['title'] ?? ''}',
          type: '${m['type'] ?? ''}',
          content: LatexUtil.autoFix('${m['content'] ?? ''}'),
          page: asInt(m['page'], c.pageStart).clamp(c.pageStart, max(c.pageStart, c.pageEnd)),
        ));
      }
      await repo.saveKps(kps);
      result.addAll(kps);
    }
    return dedupeKps(result);
  }

  static String optionsText(List<String> l) => l.isEmpty ? '不限' : l.join('、');

  /// 第 3 步：根据知识点生成闪卡和题目。LaTeX 不合格的整批重新生成（最多 2 次）。
  Future<GenerationResult> generate(String projectId, GenOptions o, Progress p) async {
    final allChunks = await repo.chunks(projectId);
    if (allChunks.isEmpty) throw LlmException('还没有解析好的资料，请先上传并解析 PDF');
    final chunks = _scope(allChunks, o);
    if (chunks.isEmpty) throw LlmException('所选范围内没有内容');
    p('准备中…', 0.05);
    var kps = await extractKps(projectId, chunks, p);
    if (kps.isEmpty) throw LlmException('没有提取到知识点');
    kps.sort((a, b) => b.priority.compareTo(a.priority));
    const perBatch = 8;
    final batches = <List<KnowledgePoint>>[];
    for (var i = 0; i < kps.length; i += perBatch) {
      batches.add(kps.sublist(i, min(i + perBatch, kps.length)));
    }
    // 按批次平均分配数量
    var cardsLeft = o.cardCount, qLeft = o.questionCount;
    var totalCards = 0, totalQ = 0;
    for (var bi = 0; bi < batches.length && (cardsLeft > 0 || qLeft > 0); bi++) {
      final remainingBatches = batches.length - bi;
      final nc = (cardsLeft / remainingBatches).ceil();
      final nq = (qLeft / remainingBatches).ceil();
      p('生成闪卡和题目（${bi + 1}/${batches.length}）', 0.5 + 0.5 * bi / batches.length);
      final (cards, qs) = await _generateBatch(projectId, batches[bi], nc, nq, o);
      await repo.saveCards(cards);
      await repo.saveQuestions(qs);
      cardsLeft -= cards.length;
      qLeft -= qs.length;
      totalCards += cards.length;
      totalQ += qs.length;
    }
    p('完成', 1);
    return GenerationResult(totalCards, totalQ, kps.length);
  }

  /// 针对单个知识点（错题 / AI 解释面板）换个角度再出几道题。
  Future<List<Question>> generateForKp(String projectId, KnowledgePoint kp, {int count = 3, String hint = ''}) async {
    final o = GenOptions(cardCount: 0, questionCount: count, types: [QType.single, QType.judge, QType.fill, QType.calc],
        difficulty: '混合', focus: ['易错点', '计算应用'], custom: '换一个角度考查，避免与已有题目重复。$hint');
    final (_, qs) = await _generateBatch(projectId, [kp], 0, count, o);
    await repo.saveQuestions(qs);
    return qs;
  }

  Future<(List<Flashcard>, List<Question>)> _generateBatch(
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
      'custom': o.custom.trim().isEmpty ? '无' : o.custom.trim(),
      'kps': kpText,
    });
    for (var attempt = 0; attempt < 3; attempt++) {
      final j = await llm.chatJson(prompt + extra);
      final (cards, qs, problems) = parseGenerated(projectId, kps, j, allowedTypes: o.types);
      if (problems.isEmpty || attempt == 2) {
        return (cards, qs);
      }
      extra = '\n\n上一次输出存在公式格式问题，请修正后重新输出：\n${problems.take(5).join('\n')}';
    }
    return (<Flashcard>[], <Question>[]);
  }
}

/// 把模型 JSON 转成闪卡/题目，并校验 LaTeX。返回 (合格闪卡, 合格题目, 问题列表)。
(List<Flashcard>, List<Question>, List<String>) parseGenerated(
    String projectId, List<KnowledgePoint> kps, Map<String, dynamic> j,
    {List<String> allowedTypes = const []}) {
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
    final front = fix('${m['front'] ?? ''}'), back = fix('${m['back'] ?? ''}');
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
      explanation: fix('${m['explanation'] ?? ''}'),
      page: asInt(m['page'], kp?.page ?? 0),
    ));
  }
  final qs = <Question>[];
  for (final m in listOfMaps(j['questions'])) {
    final kp = kpOf(m['kp_index']);
    var type = '${m['type'] ?? QType.single}'.replaceAll('题', '');
    if (!QType.all.contains(type)) type = QType.single;
    if (allowedTypes.isNotEmpty && !allowedTypes.contains(type)) continue;
    final stem = fix('${m['stem'] ?? ''}');
    final options = ((m['options'] as List?) ?? [])
        .map((e) => fix('$e'.replaceFirst(RegExp(r'^\s*[A-Fa-f][\.．、:：]\s*'), '')))
        .toList();
    if (stem.isEmpty || options.any((e) => e.isEmpty)) continue;
    var answer = '${m['answer'] ?? ''}'.trim();
    if (type == QType.single || type == QType.multi) {
      answer = answer.toUpperCase().replaceAll(RegExp(r'[^A-F]'), '');
      if (answer.isEmpty || options.length < 2) continue;
    } else if (type == QType.judge) {
      answer = RegExp(r'^(对|正确|true|√|T)', caseSensitive: false).hasMatch(answer) ? '对' : '错';
    } else {
      answer = fix(answer);
      if (answer.isEmpty) continue;
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
      explanation: fix('${m['explanation'] ?? ''}'),
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
