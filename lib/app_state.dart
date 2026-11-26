import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as pth;

import 'data/repository.dart';
import 'desktop/platform.dart' show appFilesDirectory;
import 'models.dart';
import 'services/attachments.dart';
import 'services/backup.dart';
import 'services/chapters.dart';
import 'services/cloud_storage.dart';
import 'services/doc_files.dart';
import 'services/fsrs.dart';
import 'services/kb_export.dart';
import 'services/json_utils.dart';
import 'services/latex.dart';
import 'services/llm.dart';
import 'services/pdf_export.dart';
import 'services/pipeline.dart';
import 'services/prompts.dart';
import 'services/quality.dart';
import 'services/settings.dart';
import 'services/providers.dart';
import 'theme/rich_text.dart' show stripMetaPreamble;
import 'services/review_history.dart';
import 'services/study.dart';
import 'services/study_queue.dart';
import 'services/chapter_reparse.dart';
import 'services/concurrency.dart';
import 'ui/math_raster.dart';

/// 全局状态：持有仓库与设置，提供业务操作。UI 通过 Provider 读取。
/// 单个 PDF 的解析任务状态（用于多文件队列的逐个进度显示）。
class ParseJob {
  final PdfDoc doc;
  String state; // 排队中 / 解析中 / 完成 / 部分失败 / 失败
  String message;
  double frac;
  ParseJob(this.doc, {this.state = '排队中', this.message = '等待中', this.frac = 0});
  bool get active => state == '排队中' || state == '解析中';
}

class AppState extends ChangeNotifier {
  final Repository repo;
  final Settings settings;
  final LlmClient Function(AppState s, String key)? llmFactory; // 测试可注入
  final LlmClient Function(AppState s, String key)? explainLlmFactory;
  final LlmClient Function(AppState s, String key)? studyLlmFactory;
  final LlmClient Function(AppState s, String key)? webLlmFactory;
  AppState(this.repo, this.settings, {this.llmFactory, this.explainLlmFactory, this.studyLlmFactory, this.webLlmFactory}) {
    requestLimiter.max = settings.concurrency; // 全局请求限流 = 「并发数」
    settings.ensureMigrated();
    // 读资料原文件前先确认它在本机（放到云端的会自动下载回来）
    DocFiles.resolver = (d) async => (await cloud()).ensureDocLocal(d);
  }

  /// 测试可注入云端客户端（模拟 HTTP）。
  S3Client Function(CloudConfig c)? cloudClientFactory;

  /// PDF 导出：内置中文字体子集 + 公式栅格化（测试里可以替换）。
  Future<PdfExportService> Function()? pdfExporterOverride;
  Future<PdfExportService> pdfExporter() async {
    if (pdfExporterOverride != null) return pdfExporterOverride!();
    final font = await rootBundle.load('assets/fonts/NotoSansSC-Regular-subset.ttf');
    return PdfExportService(font.buffer.asUint8List(), math: FlutterMathRasterizer());
  }

  /// 把导出的 PDF 存进应用目录并登记（可以在「释放空间」里放到云端）。
  Future<File> saveExport(String projectId, String fileName, Uint8List bytes) async {
    final dir = Directory(pth.join((await appDir()).path, 'exports'))..createSync(recursive: true);
    final id = 'export_${DateTime.now().microsecondsSinceEpoch}';
    final f = File(pth.join(dir.path, '${id}_$fileName'));
    await f.writeAsBytes(bytes);
    await repo.saveMedia(MediaAsset(id: id, projectId: projectId, kind: 'export', ownerId: '', localPath: f.path, fileName: fileName, size: bytes.length));
    return f;
  }

  Future<Directory> appDir() async {
    if (appDirOverride != null) return appDirOverride!;
    try {
      return await appFilesDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  /// 云端存储（省手机空间）。没配置时各入口自动隐藏，不影响任何功能。
  Future<CloudStorageService> cloud() async =>
      CloudStorageService(repo: repo, settings: settings, appDir: await appDir(), clientFactory: cloudClientFactory);

  /// 删除资料：本机文件、云端那份（[remote]）和全部解析结果。
  Future<void> deleteDocEverywhere(PdfDoc d, {bool remote = false}) async {
    final m = await repo.mediaAsset(MediaAsset.docId(d.id));
    if (m != null) {
      await (await cloud()).deleteAsset(m, remote: remote);
    }
    try {
      final f = File(d.path);
      if (d.path.isNotEmpty && await f.exists()) await f.delete();
    } catch (_) {}
    await repo.deleteDoc(d);
  }

  /// 这些资料 / 项目在云端有没有文件（删除时询问要不要一起删）。
  Future<int> cloudFileCount({String? projectId, String? docId}) async => (await repo.media(projectId: projectId))
      .where((m) => m.inCloud && (docId == null || m.id == MediaAsset.docId(docId)))
      .length;

  /// 删除项目：本机原文件、照片、导出文件，可选删除云端文件，再删数据。
  Future<void> deleteProjectEverywhere(String projectId, {bool remote = false}) async {
    final c = await cloud();
    for (final m in await repo.media(projectId: projectId)) {
      try {
        await c.deleteAsset(m, remote: remote);
      } catch (_) {
        if (remote) rethrow;
      }
    }
    for (final d in await repo.docs(projectId)) {
      try {
        final f = File(d.path);
        if (d.path.isNotEmpty && await f.exists()) await f.delete();
      } catch (_) {}
    }
    await repo.deleteProject(projectId);
  }

  /// 应用版本号（main 里从安装包读取）。
  String appVersion = '';
  /// 测试可注入应用目录。
  Directory? appDirOverride;

  Future<BackupService> backup() async => BackupService(
      store: repo.store,
      settings: settings,
      appDir: appDirOverride ?? await appFilesDirectory(),
      appVersion: appVersion);

  /// 导出到 Obsidian / Notion：照片和伴学附件放到云端的会自动下载回来。
  KbExportService kbExporter() => KbExportService(repo: repo, media: chatFile);

  /// 导入数据后刷新内存缓存和所有页面。
  Future<void> afterImport() async {
    await repo.loadDocTypes();
    changed();
  }

  /// 外观相关设置的指纹；变化时 MaterialApp 才重建。
  String get appearanceKey {
    final st = settings;
    return '${st.themeMode}|${st.textScale}|${st.mathScale}|${st.reduceMotion}|${st.haptics}|${st.onboarded}';
  }

  int _version = 0;
  int get version => _version;
  void changed() {
    _version++;
    notifyListeners();
  }

  /// 出题模型（出闪卡、出题、质检、分章、主观题批改）。
  Future<LlmClient> llm() async => _client(settings.generate, await settings.llmKey(), llmFactory);

  /// 闪卡 / 测验的「AI 解释」和追问。未单独配置时与出题模型相同。
  Future<LlmClient> explainLlm() async =>
      _client(settings.explain, await settings.explainKey(), explainLlmFactory ?? (settings.explain.custom ? null : llmFactory));

  /// AI 伴学、思维导图、笔记「让 AI 讲解」。未单独配置时与出题模型相同。
  /// [chat] 若指定了这个对话自己的模型，就用那个。
  Future<LlmClient> studyLlm({StudyChat? chat}) async {
    final e = studyEndpoint(chat);
    final key = await settings.keyFor(e);
    return _client(e, key, studyLlmFactory ?? (e.custom ? null : llmFactory));
  }

  LlmEndpoint studyEndpoint([StudyChat? chat]) =>
      settings.resolved(LlmUse.study, overrideProvider: chat?.llmProvider, overrideModel: chat?.llmModel);

  /// 按这个接口实际能否联网决定：能直接用 DeepSeek 工具就直接联网，否则借联网模型检索后再交给它回答。
  Future<LlmClient> _client(LlmEndpoint e, String key, LlmClient Function(AppState s, String key)? factory) async {
    final made = factory?.call(this, key);
    final main = made ?? LlmClient(baseUrl: e.baseUrl, apiKey: key, model: e.model, kind: e.kind, reasoning: e.reasoning);
    if (settings.webNativeOf(e) || !settings.webRelayOf(e)) return main;
    final wk = await settings.webKey();
    final webE = settings.resolved(LlmUse.web);
    return WebRelayLlm(
      main,
      webLlmFactory?.call(this, wk) ??
          LlmClient(baseUrl: Settings.webBaseUrl, apiKey: wk, model: settings.webModel, kind: webE.kind, reasoning: webE.reasoning),
    );
  }

  ParseService get parser => ParseService(repo, settings, chapters: chapterService);

  /// 按章重新解析 / 重新分析知识点。测试可注入。
  ChapterReparseService Function()? reparseFactory;
  ChapterReparseService get reparser => reparseFactory?.call() ?? ChapterReparseService(repo, settings);

  /// 分章服务：没有配置出题模型密钥时不调用 AI（直接按页数切分）。
  ChapterService get chapterService => ChapterService(repo, settings, llm: () async {
        final key = await settings.llmKey();
        if (key.isEmpty && llmFactory == null) return null;
        return llm();
      });

  // ---------- 多文件解析队列 ----------
  /// docId → 任务。放在全局状态里，离开项目页后进度也不会丢。
  final jobs = ValueNotifier<Map<String, ParseJob>>({});
  /// 同时解析的文件数：2–4 份（按「并发数」）。所有文件的联网请求共用一个全局限流（requestLimiter），
  /// 同时在途的请求总数不超过「并发数」，不会因为多份文件同时解析而成倍增加。
  int get parseConcurrency => settings.concurrency.clamp(2, 4);
  ParseService Function()? parserFactory; // 测试可注入
  bool _pumping = false;

  void _touchJobs() => jobs.value = Map.of(jobs.value);

  /// 把多个 PDF 加入队列（已在队列中的忽略），按顺序、最多 [parseConcurrency] 个并行解析。
  void enqueueParse(List<PdfDoc> docs) {
    for (final d in docs) {
      final j = jobs.value[d.id];
      if (j != null && j.active) continue;
      jobs.value[d.id] = ParseJob(d);
    }
    _touchJobs();
    _pump();
  }

  void dismissJob(String docId) {
    jobs.value.remove(docId);
    _touchJobs();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      final running = <Future<void>>[];
      while (true) {
        // 全部占满时等一个完成；中途新加入的任务也会在这里被取到
        while (running.length >= parseConcurrency) {
          await Future.any(running);
        }
        final next = jobs.value.values.where((j) => j.state == '排队中').firstOrNull;
        if (next == null) {
          if (running.isEmpty) break;
          await Future.any(running);
          continue;
        }
        next.state = '解析中';
        _touchJobs();
        late Future<void> f;
        f = _runJob(next).whenComplete(() => running.remove(f));
        running.add(f);
      }
      await Future.wait(running);
    } finally {
      _pumping = false;
    }
  }

  Future<void> _runJob(ParseJob j) async {
    try {
      final failed = await (parserFactory?.call() ?? parser).parseDoc(j.doc, (m, f) {
        j.message = m;
        j.frac = f;
        _touchJobs();
      });
      j.state = failed == 0 ? '完成' : '部分失败';
      j.frac = 1;
    } catch (e) {
      j.state = '失败';
      j.message = '$e';
      j.doc.status = '部分失败';
      await repo.saveDoc(j.doc);
    }
    _touchJobs();
    changed();
  }
  Future<GenerationService> generator({String? projectId}) async => GenerationService(repo, settings, await llm(),
      avoid: projectId == null ? '' : await avoidList(projectId));

  // ---------------------------------------------------------------- 质量反馈

  /// 本项目最近的反馈（含错题本「AI出错了」）汇总成避免清单。
  Future<String> avoidList(String projectId) async {
    final since = DateTime.now().subtract(const Duration(days: 60));
    final fb = (await repo.feedback(projectId: projectId)).where((f) => f.at.isAfter(since)).toList();
    final wrong = (await repo.wrong(projectId: projectId)).where((w) => w.mark == 'AI出错了' && w.addedAt.isAfter(since)).toList();
    final texts = <String, String>{};
    for (final w in wrong) {
      if (w.questionId.isNotEmpty) {
        texts[w.questionId] = (await repo.question(w.questionId))?.stem ?? '';
      } else if (w.cardId.isNotEmpty) {
        texts[w.cardId] = (await repo.card(w.cardId))?.front ?? '';
      }
    }
    // 同一题既有反馈又标了 AI出错了 时只算一次
    final ids = fb.map((f) => f.itemId).toSet();
    return buildAvoidList([...fb, ...feedbackFromWrong(wrong, texts).where((f) => !ids.contains(f.itemId))]);
  }

  /// 「这张有问题」：记录反馈，可选暂停。
  Future<void> submitFeedback(
      {Flashcard? card, Question? q, required String reason, String note = '', bool suspend = false}) async {
    final id = card?.id ?? q!.id;
    await repo.saveFeedback(FeedbackEntry(
      id: newId(),
      projectId: card?.projectId ?? q!.projectId,
      itemId: id,
      kind: card != null ? 'card' : 'question',
      reason: reason,
      note: note,
      itemText: card?.front ?? q!.stem,
    ));
    if (card != null) {
      card
        ..flag = reason
        ..suspended = suspend || card.suspended;
      await repo.saveCards([card]);
    } else {
      q!
        ..flag = reason
        ..suspended = suspend || q.suspended;
      await repo.saveQuestions([q]);
    }
    changed();
  }

  /// AI 按原因修正 / 重写一条（不保存，由调用方确认后保存）。
  Future<Object?> aiRewrite({Flashcard? card, Question? q, required String reason}) async {
    final src = await sourceText(card?.docId ?? q!.docId, card?.page ?? q!.page);
    final svc = QualityService(await llm(), fixPrompt: settings.prompt('fix'));
    final r = await svc.rewriteOne(card: card, q: q, reason: reason, source: src);
    if (r == null) throw LlmException('AI 没能给出修改，请稍后再试或手动编辑');
    return r;
  }

  // ---------------------------------------------------------------- 学习时长

  /// 开始一次学习会话。每次评分 / 作答时调用 touch()，离开页面时调用 end()。
  /// 两次操作间隔超过 2 分钟的部分不计（视为走神或挂机）。
  SessionTimer startSession(String? projectId, String kind) =>
      SessionTimer((secs, start) => repo.saveSession(
          StudySession(id: newId(), projectId: projectId ?? '', kind: kind, start: start, seconds: secs)));

  // ---------- 复习 ----------
  /// FSRS 调度器：目标记忆率来自学习设置（默认 0.9，与旧版相同）。
  Fsrs get fsrs => Fsrs(requestRetention: settings.desiredRetention);

  /// 「今天」的开始时刻（按学习设置里的每日开始时间）。
  DateTime dayStart([DateTime? now]) {
    final n = now ?? DateTime.now();
    var d = DateTime(n.year, n.month, n.day, settings.dayStartHour);
    if (n.isBefore(d)) d = d.subtract(const Duration(days: 1));
    return d;
  }

  /// 今天（按每日开始时间）的闪卡学习记录。
  Future<List<LogEntry>> _todayCardLogs(DateTime now) async {
    final since = dayStart(now);
    return (await repo.logs()).where((e) => e.kind == 'card' && !e.at.isBefore(since)).toList();
  }

  String todayKey([DateTime? now]) => dayKey(now ?? DateTime.now(), settings.dayStartHour);

  /// 新学 / 待复习数量（首页、项目页、复习页）。
  Future<StudyCounts> studyCounts({String? projectId, DateTime? now}) async {
    final n = now ?? DateTime.now();
    return computeCounts(await repo.cards(projectId: projectId), await _todayCardLogs(n),
        newLimit: settings.dailyNewLimit, reviewLimit: settings.dailyReviewLimit, extra: settings.newExtraFor(todayKey(n)), now: n);
  }

  /// 学习队列：全部学习（先复习、后新卡）/ 只学新卡 / 只复习。新卡受每日上限限制（可当天追加）。
  Future<List<Flashcard>> studyQueue({String? projectId, StudyMode mode = StudyMode.all, DateTime? now}) async {
    final n = now ?? DateTime.now();
    return buildQueue(await repo.cards(projectId: projectId), await _todayCardLogs(n), mode,
        newLimit: settings.dailyNewLimit, reviewLimit: settings.dailyReviewLimit, extra: settings.newExtraFor(todayKey(n)), now: n);
  }

  /// 「今天再学 N 张」：只放宽今天的新卡上限。
  void extendNewToday([int n = 10]) {
    settings.addNewExtra(todayKey(), n);
    changed();
  }

  /// 全部学习的队列（旧接口，保留给已有的调用方）。
  Future<List<Flashcard>> dueCards({String? projectId}) => studyQueue(projectId: projectId);

  /// 四档评分（1 没记住 / 2 模糊 / 3 记住了 / 4 很简单），返回本轮的评分记录（含评分前快照），用于回看时修改评分。
  Future<ReviewEntry> rateCard(Flashcard c, int grade, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final snapshot = c.toJson();
    fsrs.review(c, grade, now: t);
    await repo.saveCards([c]);
    final logId = newId();
    await repo.log(LogEntry(
        id: logId, projectId: c.projectId, kind: 'card', correct: grade > Grade.again, grade: grade, at: t, isNew: snapshot['reps'] == 0));
    changed();
    return ReviewEntry(cardId: c.id, pre: snapshot, grade: grade, at: t, logId: logId);
  }

  /// 修改本轮第 [i] 次评分：从评分前的快照按原时间重新计算 FSRS（同一张卡后面的评分依次重放），
  /// 并原地更新对应的复习记录（不新增记录）。返回更新后的卡片。
  Future<Flashcard> changeRating(List<ReviewEntry> entries, int i, int grade) async {
    final id = entries[i].cardId;
    final current = await repo.card(id) ?? Flashcard.fromJson(entries[i].pre);
    final c = replayFrom(entries, i, grade, current, fsrs);
    await repo.saveCards([c]);
    for (final e in entries.where((e) => e.cardId == id)) {
      final log = await repo.logEntry(e.logId);
      if (log == null) continue;
      log
        ..correct = e.grade > Grade.again
        ..grade = e.grade;
      await repo.log(log);
    }
    changed();
    return c;
  }

  /// 评分并返回撤销记录（评分前的卡片快照 + 写入的日志 id），用于「上一张」。
  Future<Map<String, dynamic>> reviewCard(Flashcard c, bool remembered) async {
    final snapshot = c.toJson();
    fsrs.review(c, remembered ? 3 : 1);
    await repo.saveCards([c]);
    final logId = newId();
    await repo.log(LogEntry(id: logId, projectId: c.projectId, kind: 'card', correct: remembered, isNew: snapshot['reps'] == 0));
    changed();
    return {'card': snapshot, 'log': logId};
  }

  /// 撤销一次评分：恢复卡片的 FSRS 状态和到期时间，并删除那条复习记录。
  /// 返回 (恢复后的卡片, 重做记录)。重做记录保存评分后的状态和原日志，供「下一张」原样恢复。
  Future<(Flashcard, Map<String, dynamic>)> undoReview(Map<String, dynamic> undo) async {
    final pre = (undo['card'] as Map).cast<String, dynamic>();
    final c = Flashcard.fromJson(pre);
    final post = await repo.card(c.id);
    final log = await repo.logEntry(undo['log'] as String);
    await repo.saveCards([c]);
    await repo.deleteLog(undo['log'] as String);
    changed();
    return (c, {'pre': pre, 'post': post?.toJson() ?? pre, 'log': log?.toJson()});
  }

  /// 重做（「下一张」）：原样恢复当时的评分结果和复习记录（同一 id、同一时间），返回撤销记录。
  Future<Map<String, dynamic>> redoReview(Map<String, dynamic> redo) async {
    final post = Flashcard.fromJson((redo['post'] as Map).cast<String, dynamic>());
    await repo.saveCards([post]);
    final logJson = (redo['log'] as Map?)?.cast<String, dynamic>();
    if (logJson != null) await repo.log(LogEntry.fromJson(logJson));
    changed();
    return {'card': redo['pre'], 'log': logJson?['id'] ?? ''};
  }

  // ---------- 答题与错题本 ----------
  Future<void> recordAnswer(Question q, bool correct, String userAnswer) async {
    await repo.log(LogEntry(id: newId(), projectId: q.projectId, kind: 'quiz', correct: correct));
    final existing = await repo.wrongEntry(q.id);
    if (!correct) {
      final w = existing ?? WrongEntry(id: q.id, projectId: q.projectId, questionId: q.id, kpId: q.kpId);
      w.streak = 0;
      w.lastAnswer = userAnswer;
      if (w.mark != 'AI出错了') w.mark = '答错';
      await repo.saveWrong(w);
      await repo.boostKp(q.projectId, q.kpId);
    } else if (existing != null) {
      existing.streak += 1;
      if (existing.streak >= 3) {
        await repo.deleteWrong(existing.id); // 连续答对 3 次，自动移出
      } else {
        await repo.saveWrong(existing);
      }
    }
    changed();
  }

  /// 手动标记：不确定 / AI出错了 / 答错（加入错题本）。
  Future<void> mark({Question? q, Flashcard? card, required String mark}) async {
    final id = q?.id ?? 'card_${card!.id}';
    final projectId = q?.projectId ?? card!.projectId;
    final kpId = q?.kpId ?? card!.kpId;
    final w = await repo.wrongEntry(id) ??
        WrongEntry(id: id, projectId: projectId, questionId: q?.id ?? '', cardId: card?.id ?? '', kpId: kpId);
    w.mark = mark;
    w.streak = 0;
    await repo.saveWrong(w);
    if (mark != 'AI出错了') await repo.boostKp(projectId, kpId);
    changed();
  }

  Future<List<Question>> relatedQuestions(String projectId, String kpId, {String hint = ''}) async {
    final kps = await repo.kps(projectId);
    final kp = kps.where((k) => k.id == kpId).firstOrNull;
    if (kp == null) throw LlmException('找不到对应的知识点');
    final qs = await (await generator(projectId: projectId)).generateForKp(projectId, kp, hint: hint);
    changed();
    return qs;
  }

  /// 出处文字：PDF 显示「第 N 页」，Word 没有页码，显示章节/小节标题。
  String sourceLabel(String docId, int page, String chapter, [String section = '']) {
    if (repo.isWordDoc(docId)) {
      final h = [chapter, section].where((e) => e.isNotEmpty && e != '未分章').join(' · ');
      return h.isEmpty ? 'Word 第 $page 节' : h;
    }
    if (repo.isTextDoc(docId)) {
      final h = [chapter, section].where((e) => e.isNotEmpty && e != '未分章').join(' · ');
      return h.isEmpty ? '第 $page 节' : '$h · 第 $page 节';
    }
    return '第 $page 页';
  }

  // ---------- AI 解释 / 批改 ----------
  Future<String> sourceText(String docId, int page) async {
    if (docId.isEmpty || page <= 0) return '';
    final p = await repo.page(docId, page);
    return p?.text ?? '';
  }

  /// 首次解释（有缓存直接返回，不重复花钱）。
  Future<ExplainCache> explain(
      {required String itemId,
      required String projectId,
      required String itemText,
      required String docId,
      required int page,
      String kind = '',
      String title = '',
      AiIo? io}) async {
    final cached = await repo.explain(itemId);
    if (cached != null && cached.messages.isNotEmpty) return cached;
    final src = await sourceText(docId, page);
    final prompt = Prompts.fill(settings.prompt('explain'),
        {'item': itemText, 'page': '$page', 'source': src.isEmpty ? '（无原文）' : src});
    final client = await explainLlm();
    final msgs = [{'role': 'user', 'content': prompt}];
    final r = await _answer(client, msgs, web: settings.web(), io: io);
    final c = ExplainCache(id: itemId, projectId: projectId, kind: kind, title: title, messages: [
      {'role': 'user', 'content': prompt},
      {'role': 'assistant', 'content': r.content, ...r.extras()},
    ]);
    await repo.saveExplain(c);
    return c;
  }

  Future<ExplainCache> followUp(ExplainCache c, String question, {AiIo? io}) async {
    final msgs = [...c.messages, {'role': 'user', 'content': '$question\n（${Prompts.answerStyle}）'}];
    final client = await explainLlm();
    final r = await _answer(client, msgs, web: settings.web(), io: io);
    c.messages = [...c.messages, {'role': 'user', 'content': question}, {'role': 'assistant', 'content': r.content, ...r.extras()}];
    c.updatedAt = DateTime.now();
    await repo.saveExplain(c);
    return c;
  }

  /// 联网时在系统提示里说明「教材为准、网页补充」。
  static List<Map<String, String>> withWebGuide(List<Map<String, String>> msgs, WebMode web) {
    if (web == WebMode.off) return msgs;
    if (msgs.isNotEmpty && msgs.first['role'] == 'system') {
      return [{...msgs.first, 'content': '${msgs.first['content']}\n\n${Prompts.webGuide}'}, ...msgs.skip(1)];
    }
    return [{'role': 'system', 'content': Prompts.webGuide}, ...msgs];
  }

  /// 一次可联网、可流式、可停止的回答。停止时保留已经收到的部分；什么都还没收到就抛 [LlmCancelled]。
  Future<LlmReply> _answer(LlmClient client, List<Map<String, String>> msgs, {required WebMode web, AiIo? io}) async {
    var partial = '';
    final onDelta = io?.onDelta;
    try {
      final r = await client.ask(withWebGuide(msgs, web),
          web: web,
          onDelta: onDelta == null
              ? null
              : (t) {
                  partial = t;
                  onDelta(t);
                },
          onStatus: io?.onStatus,
          cancel: io?.cancel);
      final fixed = await _ensureLatex(client, msgs, r.content);
      return LlmReply(r.truncated ? '$fixed\n\n（回答太长，被截断了，可以追问「接着讲」）' : fixed,
          sources: r.sources, serverToolCalls: r.serverToolCalls, reasoning: r.reasoning);
    } on LlmCancelled {
      if (partial.trim().isEmpty) rethrow;
      return LlmReply('${stripMetaPreamble(LatexUtil.autoFix(partial))}\n\n（已停止生成）');
    }
  }

  /// LaTeX 校验失败时让模型修正一次，仍失败则做本地修复。
  Future<String> _ensureLatex(LlmClient client, List<Map<String, String>> msgs, String answer) async {
    final fixed = stripMetaPreamble(LatexUtil.autoFix(answer));
    final problems = LatexUtil.validate(fixed);
    if (problems.isEmpty) return fixed;
    final again = await client.chat([
      for (final m in msgs) {'role': m['role'] ?? 'user', 'content': m['content'] ?? ''},
      {'role': 'assistant', 'content': answer},
      {
        'role': 'user',
        'content': '上面回答中有公式格式错误：${problems.take(3).join('；')}。请直接输出修正后的完整回答正文（Markdown，'
            '公式用 \$...\$ 或 \$\$...\$\$），第一句就进入讲解内容，不要说明你在重写或修正，不要任何开场白。'
      }
    ]);
    return stripMetaPreamble(LatexUtil.autoFix(again));
  }

  // ---------- 学习板块 ----------
  StudyService get study => StudyService(repo, settings);

  /// 按需生成一章的思维导图（用户点按钮才调用）。
  Future<ChapterMindMap> generateMindMap(StudyChapter c) async {
    final m = await study.generateMindMap(await studyLlm(), c, web: settings.web());
    changed();
    return m;
  }

  /// 伴学这次要发的消息：选中资料原文进系统提示；附件按模型上下文长度动态分配，放不下时先丢最早的对话，再截断附件。
  Future<(List<Map<String, String>>, WebMode)> _studyPrompt(StudyChat chat, String question) async {
    final st = study;
    final mat = await st.material(chat.projectId, chat.scope);
    final scope = chat.scope.isEmpty ? '（未选择资料）' : await st.scopeLabel(chat.projectId, chat.scope);
    final web = settings.web(chatOn: chat.web, chatMode: chat.webMode == null ? null : (chat.webMode == 'normal' ? WebMode.normal : WebMode.deep));
    final system = Prompts.fill(settings.prompt('study'), {
      'scope': mat.truncated ? '$scope（原文较长，只附上了前 ${mat.used} 字，约占所选范围的 ${mat.percent}%）' : scope,
      'material': mat.text.isEmpty
          ? (web == WebMode.off ? '（没有选择资料，请按一般教材知识回答，并提醒学生选择资料）' : '（没有选择资料，可以联网查资料回答，并提醒学生选择资料）')
          : mat.text,
    });
    // 附件：文档文字拼进系统提示，图片随这次提问一起发给模型看
    final docs = [
      for (final a in chat.attachments.where((a) => !a.isImage)) (name: a.name, text: await attachmentText(a), truncated: false),
    ];
    final images = <String>[];
    for (final a in chat.attachments.where((a) => a.isImage)) {
      final f = await chatFile(a.id);
      if (f == null) continue;
      images.add('data:${AttachmentService.mimeOf(a.name)};base64,${base64Encode(await f.readAsBytes())}');
    }
    final names = [for (final a in chat.attachments) a.name].join('、');
    final head = '$system\n\n学生上传了附件（$names），回答时可以引用附件名。${images.isEmpty ? '' : '图片附在学生的提问里。'}\n';
    final plan = AttachmentService.plan(
      context: studyEndpoint(chat).contextTokens,
      fixedChars: head.length + question.length + docs.fold<int>(0, (a, d) => a + d.name.length + 24),
      history: [for (final m in chat.messages) (m['content'] ?? '').length],
      attachChars: docs.fold<int>(0, (a, d) => a + d.text.length),
      web: web != WebMode.off,
      images: images.length,
    );
    chat.plan = chat.attachments.isEmpty ? null : plan;
    final (block, _) = AttachmentService.promptBlock(docs, budget: plan.attachSent);
    final msgs = [
      {'role': 'system', 'content': block.isEmpty && images.isEmpty ? system : '$head$block'.trim()},
      ...chat.messages.skip(plan.historyDropped),
      {'role': 'user', 'content': question, if (images.isNotEmpty) 'images': jsonEncode(images)},
    ];
    return (msgs, web);
  }

  /// 重新计算附件能发多少（添加 / 删除附件、换资料后刷新提示）。
  Future<ContextPlan?> refreshStudyPlan(StudyChat chat) async {
    if (chat.attachments.isEmpty) return chat.plan = null;
    await _studyPrompt(chat, '');
    return chat.plan;
  }

  /// AI 伴学：每次都把选中资料的原文放进系统提示，对话本身只存可见内容。
  Future<StudyChat> studyAsk(StudyChat chat, String question, {AiIo? io}) async {
    final (msgs, web) = await _studyPrompt(chat, question);
    final r = await _answer(await studyLlm(chat: chat), msgs, web: web, io: io);
    chat.messages = [...chat.messages, {'role': 'user', 'content': question}, {'role': 'assistant', 'content': r.content, ...r.extras()}];
    if (chat.title.isEmpty) chat.title = question.length > 24 ? '${question.substring(0, 24)}…' : question;
    chat.updatedAt = DateTime.now();
    await repo.saveStudyChat(chat);
    return chat;
  }

  // ---------- 伴学附件 ----------
  AttachmentService get attachments => AttachmentService(settings, parser);

  /// 添加附件：检查格式和大小，存进 media 目录（可释放到云端、会进备份），抽出文字随对话保存。
  Future<ChatAttachment> addChatAttachment(StudyChat chat, String name, Uint8List bytes, {void Function(String)? onStatus}) async {
    final err = AttachmentService.check(name, bytes.length, chat.attachments.length);
    if (err != null) throw AttachmentException(err);
    final kind = AttachmentService.kindOf(name)!;
    if (kind == 'image') {
      final why = LlmClient.visionUnavailableReason(studyEndpoint(chat).baseUrl, studyEndpoint(chat).model);
      if (why != null) throw AttachmentException(why);
    }
    var text = '';
    var pages = 0;
    if (kind != 'image') {
      (text, pages) = await attachments.extract(name, bytes, onStatus: onStatus);
      if (text.trim().isEmpty) throw AttachmentException('没有从「$name」里读到文字');
    }
    final dir = Directory(pth.join((await appDir()).path, 'media'))..createSync(recursive: true);
    final id = 'chatfile_${newId()}';
    final f = File(pth.join(dir.path, '$id.${AttachmentService.ext(name)}'));
    await f.writeAsBytes(bytes);
    await repo.saveMedia(MediaAsset(id: id, projectId: chat.projectId, kind: 'chat_file', ownerId: chat.id, localPath: f.path, fileName: name, size: bytes.length));
    final a = ChatAttachment(
        id: id,
        name: name,
        kind: kind,
        size: bytes.length,
        text: text.length > AttachmentService.storeChars ? text.substring(0, AttachmentService.storeChars) : text,
        chars: text.length,
        pages: pages);
    if (a.truncated) {
      // 全文另存一份（也登记为附件文件：会进备份、可释放到云端），数据库里只放预览
      final tf = File(pth.join(dir.path, '${id}_text.txt'));
      await tf.writeAsString(text);
      await repo.saveMedia(MediaAsset(
          id: '${id}_text', projectId: chat.projectId, kind: 'chat_file', ownerId: chat.id, localPath: tf.path, fileName: '$name.txt', size: await tf.length()));
    }
    chat.attachments = [...chat.attachments, a];
    chat.updatedAt = DateTime.now();
    await repo.saveStudyChat(chat);
    await refreshStudyPlan(chat);
    return a;
  }

  /// 附件文件：放到云端的会自动下载回来。
  Future<File?> chatFile(String id) async {
    final m = await repo.mediaAsset(id);
    if (m == null) return null;
    try {
      return await (await cloud()).ensureLocal(m);
    } catch (_) {
      return null;
    }
  }

  /// 附件全文：短的就在对话里，长的从另存的全文文件读（读不到时用预览）。
  Future<String> attachmentText(ChatAttachment a) async {
    if (!a.truncated) return a.text;
    final f = await chatFile('${a.id}_text');
    if (f == null) return a.text;
    try {
      return await f.readAsString();
    } catch (_) {
      return a.text;
    }
  }

  Future<void> _deleteAttachmentFiles(String id) async {
    for (final mid in [id, '${id}_text']) {
      final m = await repo.mediaAsset(mid);
      if (m != null) await (await cloud()).deleteAsset(m);
    }
  }

  Future<void> removeChatAttachment(StudyChat chat, String id) async {
    await _deleteAttachmentFiles(id);
    chat.attachments = chat.attachments.where((a) => a.id != id).toList();
    await repo.saveStudyChat(chat);
    await refreshStudyPlan(chat);
  }

  /// 删除对话，连同它的附件（本机和云端）。
  Future<void> deleteStudyChat(StudyChat chat) async {
    for (final a in chat.attachments) {
      await _deleteAttachmentFiles(a.id);
    }
    await repo.deleteStudyChat(chat.id);
  }

  // ---------- 笔记 ----------
  /// 打开某个知识点的笔记：已有就返回（不保存空笔记），没有就新建一条（未保存）。
  Future<StudyNote> noteFor({required String projectId, String kpId = '', String title = '', String chapter = ''}) async {
    if (kpId.isNotEmpty) {
      final old = (await repo.notes(projectId: projectId)).where((n) => n.kpId == kpId).firstOrNull;
      if (old != null) return old;
      final kp = await repo.kp(kpId);
      if (kp != null) {
        title = title.isEmpty ? kp.title : title;
        chapter = chapter.isEmpty ? kp.chapter : chapter;
      }
    }
    return StudyNote(id: newId(), projectId: projectId, kpId: kpId, title: title, chapter: chapter);
  }

  Future<void> saveNote(StudyNote n) async {
    n.updatedAt = DateTime.now();
    await repo.saveNote(n);
    changed();
  }

  /// 把（已压缩的）照片存进应用目录并登记，返回 MediaAsset id。
  Future<String> addNotePhoto(StudyNote n, List<int> bytes, {String ext = 'jpg'}) async {
    final dir = Directory(pth.join((await appDir()).path, 'media'))..createSync(recursive: true);
    final id = 'photo_${newId()}';
    final f = File(pth.join(dir.path, '$id.$ext'));
    await f.writeAsBytes(bytes);
    await repo.saveMedia(MediaAsset(
        id: id, projectId: n.projectId, kind: 'photo', ownerId: n.id, localPath: f.path, fileName: '${n.title.isEmpty ? '笔记照片' : n.title}.$ext', size: bytes.length));
    n.photoIds = [...n.photoIds, id];
    await saveNote(n);
    return id;
  }

  /// 照片文件：在本机直接用，放到云端的会自动下载。找不到时返回 null。
  Future<File?> notePhoto(String id) async {
    final m = await repo.mediaAsset(id);
    if (m == null) return null;
    try {
      return await (await cloud()).ensureLocal(m);
    } catch (_) {
      return null;
    }
  }

  Future<void> removeNotePhoto(StudyNote n, String id, {bool remote = true}) async {
    final m = await repo.mediaAsset(id);
    if (m != null) await (await cloud()).deleteAsset(m, remote: remote);
    n.photoIds = n.photoIds.where((e) => e != id).toList();
    await saveNote(n);
  }

  Future<void> deleteNoteEverywhere(StudyNote n, {bool remote = true}) async {
    final c = await cloud();
    for (final id in n.photoIds) {
      final m = await repo.mediaAsset(id);
      if (m != null) await c.deleteAsset(m, remote: remote);
    }
    await repo.deleteNote(n.id);
    changed();
  }

  /// AI 讲解知识点：和「AI 解释」同一个提示词，带上知识点内容和教材原文。
  Future<LlmReply> noteExplain(StudyNote n, {AiIo? io}) async {
    final kp = n.kpId.isEmpty ? null : await repo.kp(n.kpId);
    final item = [n.title, if (kp != null && kp.content.isNotEmpty) kp.content, if (n.own.trim().isNotEmpty) '我的理解：${n.own}'].join('\n');
    final docId = kp?.docId ?? (n.quotes.isEmpty ? '' : n.quotes.first.docId);
    final page = kp?.page ?? (n.quotes.isEmpty ? 0 : n.quotes.first.page);
    final src = await sourceText(docId, page);
    final quotes = n.quotes.map((q) => q.text).join('\n');
    final prompt = Prompts.fill(settings.prompt('explain'),
        {'item': item, 'page': '$page', 'source': [src, quotes].where((e) => e.trim().isNotEmpty).join('\n\n').ifEmpty('（无原文）')});
    return _answer(await studyLlm(), [{'role': 'user', 'content': prompt}], web: settings.web(), io: io);
  }

  /// 主观题 AI 批改，返回 (得分 0-10, 点评)。
  Future<(int, String)> gradeSubjective(Question q, String userAnswer) async {
    final prompt = Prompts.fill(settings.prompt('grade'), {'stem': q.stem, 'answer': q.answer, 'user_answer': userAnswer});
    final j = await (await llm()).askJson(prompt, web: settings.web());
    return (asInt(j['score']).clamp(0, 10), LatexUtil.autoFix('${j['comment'] ?? ''}'));
  }
}


extension _IfEmpty on String {
  String ifEmpty(String d) => isEmpty ? d : this;
}

class SessionTimer {
  final void Function(int seconds, DateTime start) onEnd;
  final DateTime start = DateTime.now();
  late DateTime _last = start;
  int _active = 0;
  bool _done = false;
  SessionTimer(this.onEnd);

  int get seconds => _active;

  void touch([DateTime? now]) {
    final n = now ?? DateTime.now();
    _active += n.difference(_last).inSeconds.clamp(0, 120);
    _last = n;
  }

  void end() {
    if (_done) return;
    _done = true;
    touch();
    if (_active >= 5) onEnd(_active, start);
  }
}
