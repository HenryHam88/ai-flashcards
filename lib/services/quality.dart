import 'dart:convert';

import '../models.dart';
import 'json_utils.dart';
import 'latex.dart';
import 'llm.dart';
import 'prompts.dart';

// ============================================================================
// 生成后的自动质检：出处可追溯、公式可渲染、选择题合法、与已有内容不重复。
// 不合格的条目合并成一次便宜的 AI 修正；仍不合格就丢弃。
// ============================================================================

/// 一次生成的质检结果汇总。
class QualityReport {
  int kept = 0; // 最终保留（含修正后的）
  int fixed = 0; // 经 AI 修正后保留
  int deduped = 0; // 与已有内容重复而去掉
  int dropped = 0; // 修正后仍不合格而丢弃
  void add(QualityReport o) {
    kept += o.kept;
    fixed += o.fixed;
    deduped += o.deduped;
    dropped += o.dropped;
  }

  /// 如「自动修正 2 张，去重 3 张」；没有任何处理时返回空。
  String get detail => [
        if (fixed > 0) '自动修正 $fixed 张',
        if (deduped > 0) '去重 $deduped 张',
        if (dropped > 0) '丢弃 $dropped 张',
      ].join('，');
}

// ---------------------------------------------------------------- 文本工具

final _latexCmd = RegExp(r'\\[a-zA-Z]+');
final _punct = RegExp(r'''[\s\$\\{}\[\]()（）【】,，.。:：;；!！?？"“”'‘’、·\-_=+*/^|<>《》~`#&%]''');

/// 归一化：去掉公式命令、标点、空白，转小写。用于比较。
String normText(String s) => s.replaceAll(_latexCmd, '').replaceAll(_punct, '').toLowerCase();

/// 字符 n-gram 集合（中文按字，英文数字也按字符，够用且不依赖分词）。
Set<String> shingles(String s, {int n = 3}) {
  final t = normText(s);
  if (t.isEmpty) return {};
  if (t.length <= n) return {t};
  return {for (var i = 0; i + n <= t.length; i++) t.substring(i, i + n)};
}

double jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final inter = a.intersection(b).length;
  return inter / (a.length + b.length - inter);
}

/// 近似重复检测：归一化后完全相同，或三字组 Jaccard ≥ [threshold]。
class DupIndex {
  final double threshold;
  final _sets = <Set<String>>[];
  final _exact = <String>{};
  DupIndex({this.threshold = 0.8});

  bool isDup(String text) {
    final n = normText(text);
    if (n.isEmpty) return false;
    if (_exact.contains(n)) return true;
    final s = shingles(text);
    return _sets.any((e) => jaccard(e, s) >= threshold);
  }

  void add(String text) {
    final n = normText(text);
    if (n.isEmpty) return;
    _exact.add(n);
    _sets.add(shingles(text));
  }
}

/// 用于去重的文本：闪卡看正面，题目看题干。
String dupKeyCard(Flashcard c) => c.front;
String dupKeyQuestion(Question q) => q.stem;

/// 答案部分在原文中能找到多少：答案 + 解析的二字组，有多少出现在原文里。
double sourceCoverage(String text, String source) {
  final a = shingles(text, n: 2), b = shingles(source, n: 2);
  if (a.isEmpty) return 1;
  return a.where(b.contains).length / a.length;
}

/// 需要在原文里找到依据的文字（不含题干，避免题干照抄原文抬高分数）。
String answerTextOf({Flashcard? card, Question? q}) {
  if (card != null) return '${card.back} ${card.explanation}';
  final x = q!;
  if (x.type == QType.single || x.type == QType.multi) {
    final opts = [
      for (final ch in x.answer.split(''))
        if (ch.codeUnitAt(0) - 65 >= 0 && ch.codeUnitAt(0) - 65 < x.options.length) x.options[ch.codeUnitAt(0) - 65]
    ];
    return '${opts.join(' ')} ${x.explanation}';
  }
  if (x.type == QType.judge) return '${x.stem} ${x.explanation}'; // 判断题答案只有对 / 错，看题干和解析
  return '${x.answer} ${x.explanation}';
}

/// 出处检查：太短的不判断；计算题答案是算出来的，门槛放低。
bool traceable(String text, String source, {String type = ''}) {
  if (source.trim().isEmpty) return true; // 没有原文可对照时不误杀
  if (shingles(text, n: 2).length < 6) return true;
  final need = type == QType.calc ? 0.2 : 0.3;
  return sourceCoverage(text, source) >= need;
}

/// 选择题合法性：单选恰好一个答案、多选至少两个、选项互不相同、答案字母在选项范围内。
String? mcqProblem(Question q) {
  if (q.type != QType.single && q.type != QType.multi) return null;
  if (q.options.length < 2) return '选项少于 2 个';
  final norm = q.options.map(normText).toList();
  if (norm.any((e) => e.isEmpty)) return '有空选项';
  if (norm.toSet().length != norm.length) return '选项有重复';
  final letters = q.answer.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '').split('').where((e) => e.isNotEmpty).toSet();
  if (letters.any((l) => l.codeUnitAt(0) - 65 >= q.options.length)) return '答案不在选项范围内';
  if (q.type == QType.single && letters.length != 1) return '单选题应恰好有一个正确答案';
  if (q.type == QType.multi && letters.length < 2) return '多选题应至少有两个正确答案';
  return null;
}

/// 公式检查：自动修复后仍无法渲染的问题列表。
List<String> latexProblemsOf({Flashcard? card, Question? q}) {
  final parts = card != null
      ? [card.front, card.back, card.explanation]
      : [q!.stem, ...q.options, if (!QType.isObjective(q.type) || q.type == QType.fill) q.answer, q.explanation];
  return [for (final p in parts) ...LatexUtil.validate(LatexUtil.autoFix(p))];
}

// ---------------------------------------------------------------- 反馈 → 避免清单

const _advice = {
  '答案错误': '务必逐条核对原文，答案和解析都要能在原文中找到依据',
  '太简单': '适当提高难度，少出直接复述定义的题，多考理解和应用',
  '重复': '不要与已有内容重复，换角度考查',
  '超纲': '只考教材原文中出现的内容，不要引入原文没有的知识',
  '表述不清': '题干和答案要表述完整、无歧义，避免指代不明',
  '其他': '参考用户备注',
};

/// 把最近的反馈汇总成一段简短的「避免清单」，拼进出题提示词。没有反馈时返回空字符串。
String buildAvoidList(List<FeedbackEntry> fb, {int maxChars = 500}) {
  if (fb.isEmpty) return '';
  final recent = [...fb]..sort((a, b) => b.at.compareTo(a.at));
  final byReason = <String, List<FeedbackEntry>>{};
  for (final f in recent.take(30)) {
    byReason.putIfAbsent(f.reason, () => []).add(f);
  }
  final order = byReason.keys.toList()..sort((a, b) => byReason[b]!.length.compareTo(byReason[a]!.length));
  String clip(String s, int n) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= n ? t : '${t.substring(0, n)}…';
  }

  final lines = <String>[];
  for (final r in order) {
    final l = byReason[r]!;
    final examples = [
      for (final f in l.take(2))
        if (f.note.trim().isNotEmpty) '备注「${clip(f.note, 30)}」' else if (f.itemText.isNotEmpty) '如「${clip(f.itemText, 24)}」'
    ];
    lines.add('- $r（${l.length} 次）：${_advice[r] ?? _advice['其他']}${examples.isEmpty ? '' : '。${examples.join('；')}'}');
  }
  var out = '根据用户对本项目已有卡片和题目的反馈，这次请特别注意：\n${lines.join('\n')}';
  if (out.length > maxChars) out = '${out.substring(0, maxChars)}…';
  return out;
}

/// 错题本里「AI出错了」的标记也算一条「答案错误」反馈。
List<FeedbackEntry> feedbackFromWrong(List<WrongEntry> wrong, Map<String, String> textOf) => [
      for (final w in wrong.where((w) => w.mark == 'AI出错了'))
        FeedbackEntry(
          id: 'wrong_${w.id}',
          projectId: w.projectId,
          itemId: w.questionId.isNotEmpty ? w.questionId : w.cardId,
          kind: w.questionId.isNotEmpty ? 'question' : 'card',
          reason: '答案错误',
          itemText: textOf[w.questionId.isNotEmpty ? w.questionId : w.cardId] ?? '',
          at: w.addedAt,
        )
    ];

// ---------------------------------------------------------------- 质检 + 批量修正

/// 待修正条目。
class _Fix {
  final Flashcard? card;
  final Question? q;
  final List<String> issues;
  final String source;
  _Fix(this.card, this.q, this.issues, this.source);
}

/// 一条被解析阶段直接丢掉的原始条目（如公式无法渲染），交给修正。
class RawReject {
  final Flashcard? card; // 已按原始文本填好（不经 LaTeX 过滤）
  final Question? q;
  final String issue;
  RawReject({this.card, this.q, required this.issue});
}

typedef SourceOf = Future<String> Function(String docId, int page, String kpId);

class QualityService {
  final LlmClient? llm; // 没有时只做本地检查，不修正（不合格直接丢）
  final String fixPrompt;
  QualityService(this.llm, {String? fixPrompt}) : fixPrompt = fixPrompt ?? Prompts.defaults['fix']!;

  /// 检查一批新生成的内容。[dups] 是项目里已有内容的索引，会把保留下来的条目加进去。
  Future<(List<Flashcard>, List<Question>, QualityReport)> process({
    required List<Flashcard> cards,
    required List<Question> questions,
    List<RawReject> rejects = const [],
    required SourceOf sourceOf,
    required DupIndex cardDups,
    required DupIndex questionDups,
  }) async {
    final r = QualityReport();
    final okCards = <Flashcard>[], okQs = <Question>[];
    final fixes = <_Fix>[];

    Future<List<String>> issuesOf({Flashcard? card, Question? q}) async {
      final out = <String>[];
      out.addAll(latexProblemsOf(card: card, q: q).take(2).map((e) => '公式无法渲染：$e'));
      if (q != null) {
        final m = mcqProblem(q);
        if (m != null) out.add(m);
      }
      final src = await sourceOf(card?.docId ?? q!.docId, card?.page ?? q!.page, card?.kpId ?? q!.kpId);
      if (!traceable(answerTextOf(card: card, q: q), src, type: q?.type ?? '')) out.add('答案或解析在教材原文中找不到依据');
      return out;
    }

    // 1) 去重 + 检查
    for (final c in cards) {
      if (cardDups.isDup(dupKeyCard(c))) {
        r.deduped++;
        continue;
      }
      final iss = await issuesOf(card: c);
      if (iss.isEmpty) {
        okCards.add(c);
        cardDups.add(dupKeyCard(c));
      } else {
        fixes.add(_Fix(c, null, iss, await sourceOf(c.docId, c.page, c.kpId)));
      }
    }
    for (final q in questions) {
      if (questionDups.isDup(dupKeyQuestion(q))) {
        r.deduped++;
        continue;
      }
      final iss = await issuesOf(q: q);
      if (iss.isEmpty) {
        okQs.add(q);
        questionDups.add(dupKeyQuestion(q));
      } else {
        fixes.add(_Fix(null, q, iss, await sourceOf(q.docId, q.page, q.kpId)));
      }
    }
    for (final x in rejects) {
      final key = x.card != null ? dupKeyCard(x.card!) : dupKeyQuestion(x.q!);
      if ((x.card != null ? cardDups : questionDups).isDup(key)) {
        r.deduped++;
        continue;
      }
      fixes.add(_Fix(x.card, x.q, [x.issue],
          await sourceOf(x.card?.docId ?? x.q!.docId, x.card?.page ?? x.q!.page, x.card?.kpId ?? x.q!.kpId)));
    }

    // 2) 不合格的合并成一次 AI 修正
    if (fixes.isNotEmpty) {
      final repaired = llm == null ? <int, Object>{} : await _repair(fixes);
      for (var i = 0; i < fixes.length; i++) {
        final got = repaired[i];
        if (got is Flashcard) {
          final iss = await issuesOf(card: got);
          if (iss.isEmpty && !cardDups.isDup(dupKeyCard(got))) {
            okCards.add(got);
            cardDups.add(dupKeyCard(got));
            r.fixed++;
            continue;
          }
        } else if (got is Question) {
          final iss = await issuesOf(q: got);
          if (iss.isEmpty && !questionDups.isDup(dupKeyQuestion(got))) {
            okQs.add(got);
            questionDups.add(dupKeyQuestion(got));
            r.fixed++;
            continue;
          }
        }
        r.dropped++;
      }
    }
    r.kept = okCards.length + okQs.length;
    return (okCards, okQs, r);
  }

  static String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

  static Map<String, dynamic> itemJson({Flashcard? card, Question? q}) => card != null
      ? {'kind': 'card', 'front': card.front, 'back': card.back, 'explanation': card.explanation}
      : {
          'kind': 'question',
          'type': q!.type,
          'stem': q.stem,
          'options': q.options,
          'answer': q.answer,
          'explanation': q.explanation,
        };

  /// 一次请求修正多条。返回 序号 → 修正后的 Flashcard / Question。
  Future<Map<int, Object>> _repair(List<_Fix> fixes) async {
    final items = StringBuffer();
    for (var i = 0; i < fixes.length; i++) {
      final f = fixes[i];
      items.writeln('[$i] 问题：${f.issues.join('；')}');
      items.writeln('内容：${jsonEncode(itemJson(card: f.card, q: f.q))}');
      if (f.source.trim().isNotEmpty) items.writeln('原文：${_clip(f.source, 900)}');
      items.writeln();
    }
    try {
      final j = await llm!.chatJson(Prompts.fill(fixPrompt, {'items': items.toString().trim()}));
      final out = <int, Object>{};
      for (final m in listOfMaps(j['items'])) {
        final i = asInt(m['id'], -1);
        if (i < 0 || i >= fixes.length) continue;
        final f = fixes[i];
        final fixed = applyFix(m, card: f.card, q: f.q);
        if (fixed != null) out[i] = fixed;
      }
      return out;
    } catch (_) {
      return {}; // 修正失败：全部按不合格处理，不影响已通过的条目
    }
  }

  /// 把模型返回的修正内容套回原条目（保留 id、出处、复习状态）。
  static Object? applyFix(Map<String, dynamic> m, {Flashcard? card, Question? q}) {
    String fx(Object? v) => LatexUtil.autoFix('${v ?? ''}'.trim());
    if (card != null) {
      final front = fx(m['front']), back = fx(m['back']);
      if (front.isEmpty || back.isEmpty) return null;
      return Flashcard.fromJson({
        ...card.toJson(),
        'front': front,
        'back': back,
        'explanation': fx(m['explanation'] ?? card.explanation),
      });
    }
    final x = q!;
    final stem = fx(m['stem']);
    if (stem.isEmpty) return null;
    final opts = ((m['options'] as List?) ?? x.options)
        .map((e) => fx('$e'.replaceFirst(RegExp(r'^\s*[A-Fa-f][\.．、:：]\s*'), '')))
        .toList();
    var answer = '${m['answer'] ?? x.answer}'.trim();
    if (x.type == QType.single || x.type == QType.multi) answer = answer.toUpperCase().replaceAll(RegExp(r'[^A-F]'), '');
    if (x.type == QType.judge) {
      answer = RegExp(r'^(对|正确|true|√|T)', caseSensitive: false).hasMatch(answer) ? '对' : '错';
    }
    return Question.fromJson({
      ...x.toJson(),
      'stem': stem,
      'options': (x.type == QType.single || x.type == QType.multi) ? opts : <String>[],
      'answer': answer,
      'explanation': fx(m['explanation'] ?? x.explanation),
    });
  }

  /// 「AI 重写这张」/ 反馈后的「AI 修正」：单条，带用户给的原因。
  Future<Object?> rewriteOne({Flashcard? card, Question? q, required String reason, required String source}) async {
    final f = _Fix(card, q, [reason], source);
    final r = await _repair([f]);
    return r[0];
  }
}

