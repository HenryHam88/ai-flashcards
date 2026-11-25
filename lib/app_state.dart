import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';

import 'data/repository.dart';
import 'models.dart';
import 'services/backup.dart';
import 'services/chapters.dart';
import 'services/cloud_storage.dart';
import 'services/doc_files.dart';
import 'services/fsrs.dart';
import 'services/json_utils.dart';
import 'services/latex.dart';
import 'services/llm.dart';
import 'services/pdf_export.dart';
import 'services/pipeline.dart';
import 'services/prompts.dart';
import 'services/quality.dart';
import 'services/settings.dart';
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
  AppState(this.repo, this.settings, {this.llmFactory}) {
    requestLimiter.max = settings.concurrency; // 全局请求限流 = 「并发数」
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
      return await getApplicationDocumentsDirectory();
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
      appDir: appDirOverride ?? await getApplicationDocumentsDirectory(),
      appVersion: appVersion);

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

  Future<LlmClient> llm() async {
    final key = await settings.llmKey();
    return llmFactory?.call(this, key) ??
        LlmClient(baseUrl: settings.llmBaseUrl, apiKey: key, model: settings.llmModel);
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
      String title = ''}) async {
    final cached = await repo.explain(itemId);
    if (cached != null && cached.messages.isNotEmpty) return cached;
    final src = await sourceText(docId, page);
    final prompt = Prompts.fill(settings.prompt('explain'),
        {'item': itemText, 'page': '$page', 'source': src.isEmpty ? '（无原文）' : src});
    final client = await llm();
    var answer = await client.chat([{'role': 'user', 'content': prompt}]);
    answer = await _ensureLatex(client, [{'role': 'user', 'content': prompt}], answer);
    final c = ExplainCache(id: itemId, projectId: projectId, kind: kind, title: title, messages: [
      {'role': 'user', 'content': prompt},
      {'role': 'assistant', 'content': answer},
    ]);
    await repo.saveExplain(c);
    return c;
  }

  Future<ExplainCache> followUp(ExplainCache c, String question) async {
    final msgs = [...c.messages, {'role': 'user', 'content': '$question\n（${Prompts.answerStyle}）'}];
    final client = await llm();
    var answer = await client.chat(msgs);
    answer = await _ensureLatex(client, msgs, answer);
    c.messages = [...c.messages, {'role': 'user', 'content': question}, {'role': 'assistant', 'content': answer}];
    c.updatedAt = DateTime.now();
    await repo.saveExplain(c);
    return c;
  }

  /// LaTeX 校验失败时让模型修正一次，仍失败则做本地修复。
  Future<String> _ensureLatex(LlmClient client, List<Map<String, String>> msgs, String answer) async {
    final fixed = stripMetaPreamble(LatexUtil.autoFix(answer));
    final problems = LatexUtil.validate(fixed);
    if (problems.isEmpty) return fixed;
    final again = await client.chat([
      ...msgs,
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
    final m = await study.generateMindMap(await llm(), c);
    changed();
    return m;
  }

  /// AI 伴学：每次都把选中资料的原文放进系统提示，对话本身只存可见内容。
  Future<StudyChat> studyAsk(StudyChat chat, String question) async {
    final st = study;
    final mat = await st.material(chat.projectId, chat.scope);
    final scope = chat.scope.isEmpty ? '（未选择资料）' : await st.scopeLabel(chat.projectId, chat.scope);
    final system = Prompts.fill(settings.prompt('study'), {
      'scope': mat.truncated ? '$scope（原文较长，只附上了前一部分）' : scope,
      'material': mat.text.isEmpty ? '（没有选择资料，请按一般教材知识回答，并提醒学生选择资料）' : mat.text,
    });
    final msgs = [
      {'role': 'system', 'content': system},
      ...chat.messages,
      {'role': 'user', 'content': question},
    ];
    final client = await llm();
    var answer = await client.chat(msgs);
    answer = await _ensureLatex(client, msgs, answer);
    chat.messages = [...chat.messages, {'role': 'user', 'content': question}, {'role': 'assistant', 'content': answer}];
    if (chat.title.isEmpty) chat.title = question.length > 24 ? '${question.substring(0, 24)}…' : question;
    chat.updatedAt = DateTime.now();
    await repo.saveStudyChat(chat);
    return chat;
  }

  /// 主观题 AI 批改，返回 (得分 0-10, 点评)。
  Future<(int, String)> gradeSubjective(Question q, String userAnswer) async {
    final prompt = Prompts.fill(settings.prompt('grade'), {'stem': q.stem, 'answer': q.answer, 'user_answer': userAnswer});
    final j = await (await llm()).chatJson(prompt);
    return (asInt(j['score']).clamp(0, 10), LatexUtil.autoFix('${j['comment'] ?? ''}'));
  }
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
