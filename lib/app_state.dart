import 'package:flutter/foundation.dart';

import 'data/repository.dart';
import 'models.dart';
import 'services/fsrs.dart';
import 'services/json_utils.dart';
import 'services/latex.dart';
import 'services/llm.dart';
import 'services/pipeline.dart';
import 'services/prompts.dart';
import 'services/settings.dart';

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
  AppState(this.repo, this.settings, {this.llmFactory});

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

  ParseService get parser => ParseService(repo, settings);

  // ---------- 多文件解析队列 ----------
  /// docId → 任务。放在全局状态里，离开项目页后进度也不会丢。
  final jobs = ValueNotifier<Map<String, ParseJob>>({});
  static const parseConcurrency = 2; // 同时解析的文件数（远低于 DeepSeek 的 15 并发上限）
  ParseService Function()? parserFactory; // 测试可注入
  bool _pumping = false;

  void _touchJobs() => jobs.value = Map.of(jobs.value);

  /// 把多个 PDF 加入队列（已在队列中的忽略），按顺序、最多 2 个并行解析。
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
  Future<GenerationService> generator() async => GenerationService(repo, settings, await llm());

  // ---------- 复习 ----------
  static const fsrs = Fsrs();

  Future<List<Flashcard>> dueCards({String? projectId}) async {
    final now = DateTime.now();
    final l = (await repo.cards(projectId: projectId)).where((c) => !c.due.isAfter(now)).toList()
      ..sort((a, b) => a.due.compareTo(b.due));
    return l;
  }

  /// 评分并返回撤销记录（评分前的卡片快照 + 写入的日志 id），用于「上一张」。
  Future<Map<String, dynamic>> reviewCard(Flashcard c, bool remembered) async {
    final snapshot = c.toJson();
    fsrs.review(c, remembered ? 3 : 1);
    await repo.saveCards([c]);
    final logId = newId();
    await repo.log(LogEntry(id: logId, projectId: c.projectId, kind: 'card', correct: remembered));
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
    final qs = await (await generator()).generateForKp(projectId, kp, hint: hint);
    changed();
    return qs;
  }

  // ---------- AI 解释 / 批改 ----------
  Future<String> sourceText(String docId, int page) async {
    if (docId.isEmpty || page <= 0) return '';
    final p = await repo.page(docId, page);
    return p?.text ?? '';
  }

  /// 首次解释（有缓存直接返回，不重复花钱）。
  Future<ExplainCache> explain({required String itemId, required String projectId, required String itemText, required String docId, required int page}) async {
    final cached = await repo.explain(itemId);
    if (cached != null && cached.messages.isNotEmpty) return cached;
    final src = await sourceText(docId, page);
    final prompt = Prompts.fill(settings.prompt('explain'),
        {'item': itemText, 'page': '$page', 'source': src.isEmpty ? '（无原文）' : src});
    final client = await llm();
    var answer = await client.chat([{'role': 'user', 'content': prompt}]);
    answer = await _ensureLatex(client, [{'role': 'user', 'content': prompt}], answer);
    final c = ExplainCache(id: itemId, projectId: projectId, messages: [
      {'role': 'user', 'content': prompt},
      {'role': 'assistant', 'content': answer},
    ]);
    await repo.saveExplain(c);
    return c;
  }

  Future<ExplainCache> followUp(ExplainCache c, String question) async {
    final msgs = [...c.messages, {'role': 'user', 'content': '$question\n（公式请用 \$...\$ 或 \$\$...\$\$ 书写）'}];
    final client = await llm();
    var answer = await client.chat(msgs);
    answer = await _ensureLatex(client, msgs, answer);
    c.messages = [...c.messages, {'role': 'user', 'content': question}, {'role': 'assistant', 'content': answer}];
    await repo.saveExplain(c);
    return c;
  }

  /// LaTeX 校验失败时让模型修正一次，仍失败则做本地修复。
  Future<String> _ensureLatex(LlmClient client, List<Map<String, String>> msgs, String answer) async {
    final fixed = LatexUtil.autoFix(answer);
    final problems = LatexUtil.validate(fixed);
    if (problems.isEmpty) return fixed;
    final again = await client.chat([
      ...msgs,
      {'role': 'assistant', 'content': answer},
      {'role': 'user', 'content': '你的回答中有公式格式错误：${problems.take(3).join('；')}。请完整重写，所有公式用 \$...\$ 或 \$\$...\$\$。'}
    ]);
    return LatexUtil.autoFix(again);
  }

  /// 主观题 AI 批改，返回 (得分 0-10, 点评)。
  Future<(int, String)> gradeSubjective(Question q, String userAnswer) async {
    final prompt = Prompts.fill(settings.prompt('grade'), {'stem': q.stem, 'answer': q.answer, 'user_answer': userAnswer});
    final j = await (await llm()).chatJson(prompt);
    return (asInt(j['score']).clamp(0, 10), LatexUtil.autoFix('${j['comment'] ?? ''}'));
  }
}
