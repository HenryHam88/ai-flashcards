import 'dart:convert';

import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/quality.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const source = r'''1.4 条件概率
定义 设 $A,B$ 是两个事件，且 $P(B)>0$，称 $P(A\mid B)=\frac{P(AB)}{P(B)}$ 为在事件 $B$ 发生的条件下事件 $A$ 发生的条件概率。
乘法公式：$P(AB)=P(B)P(A\mid B)$。全概率公式把复杂事件按完备事件组分解后加权求和。''';

Question q(String type, List<String> opts, String ans, {String stem = '条件概率的定义是什么？', String expl = ''}) =>
    Question(id: 'q', projectId: 'p', type: type, stem: stem, options: opts, answer: ans, explanation: expl);

LlmClient mockLlm(String Function(String prompt) reply, {List<String>? log}) => LlmClient(
    baseUrl: 'x',
    apiKey: 'k',
    model: 'm',
    client: MockClient((req) async {
      final prompt = (jsonDecode(req.body)['messages'] as List).last['content'] as String;
      log?.add(prompt);
      return http.Response.bytes(utf8.encode(jsonEncode({'choices': [{'message': {'content': reply(prompt)}}]})), 200);
    }));

void main() {
  group('选择题校验', () {
    test('合法的单选 / 多选通过', () {
      expect(mcqProblem(q(QType.single, ['甲', '乙', '丙', '丁'], 'B')), isNull);
      expect(mcqProblem(q(QType.multi, ['甲', '乙', '丙', '丁'], 'AC')), isNull);
      expect(mcqProblem(q(QType.judge, [], '对')), isNull);
    });
    test('单选多个答案、多选只有一个答案', () {
      expect(mcqProblem(q(QType.single, ['甲', '乙', '丙', '丁'], 'AB')), contains('恰好有一个'));
      expect(mcqProblem(q(QType.multi, ['甲', '乙', '丙', '丁'], 'C')), contains('至少有两个'));
    });
    test('选项重复（忽略空格和公式符号）、答案超出范围', () {
      expect(mcqProblem(q(QType.single, [r'$P(A)$', 'P(A)', '丙', '丁'], 'C')), contains('重复'));
      expect(mcqProblem(q(QType.single, ['甲', '乙', '丙'], 'D')), contains('范围'));
      expect(mcqProblem(q(QType.single, ['甲'], 'A')), contains('少于'));
    });
  });

  group('近似重复', () {
    test('完全相同、只差标点或个别字都算重复；不同内容不算', () {
      final d = DupIndex()..add('什么是条件概率？');
      expect(d.isDup('什么是条件概率'), isTrue);
      expect(d.isDup(' 什么是 条件概率 ?'), isTrue);
      final d2 = DupIndex()..add('写出全概率公式并说明它的适用条件');
      expect(d2.isDup('请写出全概率公式，并说明它的适用条件。'), isTrue);
      expect(d2.isDup('写出全概率公式并说明其适用条件'), isFalse); // 改一个字仍低于 0.8，避免误伤
      expect(d2.isDup('贝叶斯公式中的先验概率指什么'), isFalse);
    });
    test('Jaccard 计算', () {
      expect(jaccard({'a', 'b'}, {'a', 'b'}), 1);
      expect(jaccard({'a', 'b'}, {'c'}), 0);
      expect(jaccard({'a', 'b', 'c'}, {'b', 'c', 'd'}), closeTo(0.5, 1e-9));
    });
  });

  group('出处可追溯', () {
    test('答案来自原文 → 通过；与原文无关 → 不通过', () {
      expect(traceable(r'在事件 $B$ 发生的条件下事件 $A$ 发生的概率，等于 $P(AB)/P(B)$', source), isTrue);
      expect(traceable('光合作用把二氧化碳和水转化为葡萄糖并释放氧气', source), isFalse);
    });
    test('太短或没有原文时不误杀', () {
      expect(traceable('对', source), isTrue);
      expect(traceable('完全无关的一段比较长的文字内容', ''), isTrue);
    });
    test('选择题看正确选项和解析，不看题干', () {
      final good = q(QType.single, ['在事件 B 发生的条件下事件 A 发生的概率', '光合作用的速率', '细胞分裂的次数', '地球公转周期'], 'A');
      final bad = q(QType.single, ['在事件 B 发生的条件下事件 A 发生的概率', '光合作用释放氧气的速率', '细胞分裂的次数', '地球公转周期'], 'B');
      expect(traceable(answerTextOf(q: good), source), isTrue);
      expect(traceable(answerTextOf(q: bad), source), isFalse);
    });
  });

  test('公式检查：能渲染的通过，坏公式报错', () {
    final ok = Flashcard(id: 'c', projectId: 'p', front: r'条件概率 $P(A\mid B)$？', back: r'$\frac{P(AB)}{P(B)}$');
    final bad = Flashcard(id: 'c', projectId: 'p', front: r'坏公式 $\frac{1}{$', back: r'$\undefinedcommand{x}$');
    expect(latexProblemsOf(card: ok), isEmpty);
    expect(latexProblemsOf(card: bad), isNotEmpty);
  });

  group('反馈 → 避免清单', () {
    test('按原因汇总，带建议和例子；没有反馈为空', () {
      expect(buildAvoidList([]), isEmpty);
      final fb = [
        FeedbackEntry(id: '1', projectId: 'p', itemId: 'a', kind: 'card', reason: '太简单', itemText: '什么是事件？'),
        FeedbackEntry(id: '2', projectId: 'p', itemId: 'b', kind: 'card', reason: '太简单', itemText: '什么是样本空间？'),
        FeedbackEntry(id: '3', projectId: 'p', itemId: 'c', kind: 'question', reason: '答案错误', note: '应该选 C'),
      ];
      final t = buildAvoidList(fb);
      expect(t, contains('太简单（2 次）'));
      expect(t, contains('提高难度'));
      expect(t, contains('答案错误（1 次）'));
      expect(t, contains('应该选 C'));
      expect(t.indexOf('太简单'), lessThan(t.indexOf('答案错误'))); // 次数多的在前
      expect(t.length, lessThanOrEqualTo(501));
    });
    test('错题本「AI出错了」算作答案错误', () {
      final l = feedbackFromWrong([
        WrongEntry(id: 'q1', projectId: 'p', questionId: 'q1', mark: 'AI出错了'),
        WrongEntry(id: 'q2', projectId: 'p', questionId: 'q2', mark: '答错'),
      ], {'q1': '题干一'});
      expect(l, hasLength(1));
      expect(l.single.reason, '答案错误');
      expect(l.single.itemText, '题干一');
    });
    test('避免清单会拼进出题提示词', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = Repository(MemoryDocStore());
      final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
      await repo.saveProject(Project(id: 'p', name: '概率论'));
      await repo.savePages([PageText(docId: 'd', projectId: 'p', page: 12, text: source)]);
      await repo.replaceChunks('p', 'd', chunkPages('p', 'd', await repo.pages('p')));
      final prompts = <String>[];
      final llm = mockLlm((p) => p.contains('提取其中的知识点')
          ? r'{"knowledge_points":[{"title":"条件概率","type":"定义","content":"$P(A\\mid B)=\\frac{P(AB)}{P(B)}$","page":12}]}'
          : r'{"flashcards":[],"questions":[]}', log: prompts);
      final avoid = buildAvoidList([FeedbackEntry(id: '1', projectId: 'p', itemId: 'a', kind: 'card', reason: '超纲')]);
      await GenerationService(repo, settings, llm, avoid: avoid)
          .generate('p', GenOptions(cardCount: 1, questionCount: 0, custom: '多出计算题'), (_, _) {});
      final gen = prompts.firstWhere((p) => p.contains('生成学习闪卡'));
      expect(gen, contains('多出计算题'));
      expect(gen, contains('超纲（1 次）'));
    });
  });

  group('质检流程', () {
    Future<String> src(String docId, int page, String kpId) async => source;

    test('去重、合格直接保留、不合格批量修正一次，修不好就丢', () async {
      final calls = <String>[];
      final llm = mockLlm((p) {
        // 只修好第 0 条（无出处的闪卡），第 1 条（单选两个答案）返回仍然错误
        return jsonEncode({
          'items': [
            {'id': 0, 'front': '条件概率的乘法公式？', 'back': r'$P(AB)=P(B)P(A\mid B)$', 'explanation': '由条件概率的定义变形得到乘法公式'},
            {'id': 1, 'stem': '条件概率的定义中要求？', 'options': ['P(B)>0', 'P(B)<0', 'P(A)=1', 'P(B)=2'], 'answer': 'AB'},
          ]
        });
      }, log: calls);
      final svc = QualityService(llm);
      final cardDups = DupIndex()..add('什么是条件概率？');
      final (cards, qs, r) = await svc.process(
        cards: [
          Flashcard(id: 'dup', projectId: 'p', front: '什么是条件概率', back: '……'),
          Flashcard(id: 'good', projectId: 'p', front: '条件概率公式', back: r'$P(A\mid B)=\frac{P(AB)}{P(B)}$，要求 $P(B)>0$'),
          Flashcard(id: 'hallu', projectId: 'p', front: '乘法公式？', back: '光合作用把二氧化碳和水转化为葡萄糖并释放氧气'),
        ],
        questions: [q(QType.single, ['P(B)>0', 'P(B)<0', 'P(A)=1', 'P(B)=2'], 'AB')],
        sourceOf: src,
        cardDups: cardDups,
        questionDups: DupIndex(),
      );
      expect(calls, hasLength(1)); // 只请求一次
      expect(calls.single, contains('[0]'));
      expect(calls.single, contains('[1]'));
      expect(cards.map((c) => c.id), ['good', 'hallu']);
      expect(cards.last.back, contains(r'P(A\mid B)')); // 修正后的内容，id 不变
      expect(qs, isEmpty);
      expect(r.deduped, 1);
      expect(r.fixed, 1);
      expect(r.dropped, 1);
      expect(r.kept, 2);
      expect(r.detail, '自动修正 1 张，去重 1 张，丢弃 1 张');
    });

    test('解析阶段的坏公式条目会交给修正', () async {
      final rejects = <RawReject>[];
      final (cards, _, problems) = parseGenerated('p', [], {
        'flashcards': [
          {'front': r'坏公式 $\frac{1}{$', 'back': '条件概率'},
          {'front': '条件概率公式？', 'back': r'$P(A\mid B)=\frac{P(AB)}{P(B)}$'},
        ]
      }, rejects: rejects);
      expect(cards, hasLength(1));
      expect(problems, isNotEmpty);
      expect(rejects, hasLength(1));
      expect(rejects.single.issue, contains('公式'));

      final llm = mockLlm((_) => jsonEncode({
            'items': [
              {'id': 0, 'front': r'条件概率 $P(A\mid B)$ 的定义？', 'back': r'$P(A\mid B)=\frac{P(AB)}{P(B)}$，其中 $P(B)>0$'}
            ]
          }));
      final (c2, _, r) = await QualityService(llm).process(
          cards: cards, questions: [], rejects: rejects, sourceOf: src, cardDups: DupIndex(), questionDups: DupIndex());
      expect(c2, hasLength(2));
      expect(r.fixed, 1);
    });

    test('没有模型或修正请求失败时：不合格的直接丢，合格的不受影响', () async {
      final llm = LlmClient(baseUrl: 'x', apiKey: 'k', model: 'm', client: MockClient((_) async => http.Response('boom', 500)));
      final (cards, _, r) = await QualityService(llm).process(
        cards: [
          Flashcard(id: 'good', projectId: 'p', front: '条件概率公式', back: r'$P(A\mid B)=\frac{P(AB)}{P(B)}$'),
          Flashcard(id: 'hallu', projectId: 'p', front: '乘法公式？', back: '光合作用把二氧化碳和水转化为葡萄糖并释放氧气'),
        ],
        questions: [],
        sourceOf: src,
        cardDups: DupIndex(),
        questionDups: DupIndex(),
      );
      expect(cards.single.id, 'good');
      expect(r.dropped, 1);
    });

    test('同一批内部的重复也会去掉', () async {
      final (cards, _, r) = await QualityService(null).process(
        cards: [
          Flashcard(id: 'a', projectId: 'p', front: '条件概率公式', back: r'$P(A\mid B)=\frac{P(AB)}{P(B)}$'),
          Flashcard(id: 'b', projectId: 'p', front: '条件概率公式？', back: r'$P(A\mid B)=\frac{P(AB)}{P(B)}$'),
        ],
        questions: [],
        sourceOf: src,
        cardDups: DupIndex(),
        questionDups: DupIndex(),
      );
      expect(cards.map((c) => c.id), ['a']);
      expect(r.deduped, 1);
    });
  });

  test('开启「生成后先审核」：生成结果进待审核，不进复习', () async {
    SharedPreferences.setMockInitialValues({'review_before_add': true});
    final repo = Repository(MemoryDocStore());
    final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    await repo.saveProject(Project(id: 'p', name: '概率论'));
    await repo.savePages([PageText(docId: 'd', projectId: 'p', page: 12, text: source)]);
    await repo.replaceChunks('p', 'd', chunkPages('p', 'd', await repo.pages('p')));
    final llm = mockLlm((p) => p.contains('提取其中的知识点')
        ? r'{"knowledge_points":[{"title":"条件概率","type":"定义","content":"$P(A\\mid B)=\\frac{P(AB)}{P(B)}$","page":12}]}'
        : r'{"flashcards":[{"front":"条件概率公式？","back":"$P(A\\mid B)=\\frac{P(AB)}{P(B)}$，要求 $P(B)>0$","explanation":"条件概率的定义","kp_index":0,"page":12}],"questions":[]}');
    final r = await GenerationService(repo, settings, llm).generate('p', GenOptions(cardCount: 1, questionCount: 0), (_, _) {});
    expect(r.pending, isTrue);
    expect(r.summary, startsWith('生成 1 张'));
    expect(await repo.cards(projectId: 'p'), isEmpty);
    expect(await repo.inboxCards(projectId: 'p'), hasLength(1));
    await repo.acceptInbox(await repo.inboxCards(projectId: 'p'), []);
    expect(await repo.cards(projectId: 'p'), hasLength(1));
    expect(await repo.inboxCards(projectId: 'p'), isEmpty);
  });
}
