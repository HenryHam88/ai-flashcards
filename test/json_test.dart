import 'dart:convert';

import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/json_utils.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('模型 JSON 解析', () {
    test('去掉代码块和前后杂质', () {
      expect(parseModelJson('好的：\n```json\n{"a":1}\n```'), {'a': 1});
      expect(parseModelJson('结果如下 {"a":{"b":"}"}} 以上'), {
        'a': {'b': '}'}
      });
    });

    test(r'单反斜杠的 LaTeX（\frac、\theta）被修复而不是变成转义字符', () {
      final j = parseModelJson(r'{"back":"$\frac{1}{2}$ 与 $\theta$，换行\n结束","ok":"$\\alpha$"}');
      expect(j['back'], '\$\\frac{1}{2}\$ 与 \$\\theta\$，换行\n结束');
      expect(j['ok'], r'$\alpha$');
    });

    test('合法 JSON 不受影响', () {
      final src = {'s': r'$\dfrac{a}{b}$', 'u': 'é', 'q': '"x"'};
      expect(parseModelJson(jsonEncode(src)), src);
    });
  });

  group('生成结果解析与校验', () {
    final kps = [KnowledgePoint(id: 'k0', projectId: 'p', title: '条件概率', chapter: '第一章', page: 12, docId: 'd')];
    test('合格的闪卡/题目被保留，答案规范化', () {
      final (cards, qs, problems) = parseGenerated('p', kps, {
        'flashcards': [
          {'front': '什么是条件概率？', 'back': r'$P(A\mid B)=\dfrac{P(AB)}{P(B)}$', 'kp_index': 0}
        ],
        'questions': [
          {'type': '单选题', 'stem': '选出正确项', 'options': ['A. \$1\$', 'B. \$2\$'], 'answer': 'b', 'kp_index': 0},
          {'type': '判断', 'stem': '\$P(\\Omega)=1\$', 'answer': '正确'},
          {'type': '填空', 'stem': '\$1+1=\$____', 'answer': '2|二'},
        ]
      });
      expect(problems, isEmpty);
      expect(cards.single.page, 12);
      expect(cards.single.chapter, '第一章');
      expect(qs[0].type, QType.single);
      expect(qs[0].options, ['\$1\$', '\$2\$']);
      expect(qs[0].answer, 'B');
      expect(qs[1].answer, '对');
      expect(gradeObjective(qs[2], ' 二 '), isTrue);
    });

    test('公式不合格的条目被丢弃并报告问题', () {
      final (cards, _, problems) = parseGenerated('p', kps, {
        'flashcards': [
          {'front': r'求 $\frac{1}{$ ', 'back': 'x'}
        ]
      });
      expect(cards, isEmpty);
      expect(problems, isNotEmpty);
    });
  });

  test('客观题判分', () {
    final m = Question(id: 'q', projectId: 'p', type: QType.multi, stem: 's', options: ['a', 'b', 'c'], answer: 'AC');
    expect(gradeObjective(m, 'CA'), isTrue);
    expect(gradeObjective(m, 'A'), isFalse);
    final f = Question(id: 'q', projectId: 'p', type: QType.fill, stem: 's', answer: r'\dfrac{1}{2}');
    expect(gradeObjective(f, r'$\frac{1}{2}$'), isTrue);
  });

  test('按章节切块并记录页码', () {
    final pages = [
      PageText(docId: 'd', projectId: 'p', page: 1, text: '第一章 随机事件\n1.1 样本空间\n内容A'),
      PageText(docId: 'd', projectId: 'p', page: 2, text: '内容B\n1.2 条件概率\n内容C'),
      PageText(docId: 'd', projectId: 'p', page: 3, text: '第二章 随机变量\n内容D'),
    ];
    final cs = chunkPages('p', 'd', pages);
    expect(cs.map((c) => '${c.chapter}|${c.section}|${c.pageStart}-${c.pageEnd}').toList(), [
      '第一章 随机事件||1-1',
      '第一章 随机事件|1.1 样本空间|1-2',
      '第一章 随机事件|1.2 条件概率|2-2',
      '第二章 随机变量||3-3',
    ]);
    expect(cs[1].text.contains('[第2页]'), isTrue);
  });

  test('知识点去重', () {
    final l = dedupeKps([
      KnowledgePoint(id: '1', projectId: 'p', title: '条件概率的定义', content: '短'),
      KnowledgePoint(id: '2', projectId: 'p', title: '条件概率的定义。', content: '更长的内容'),
      KnowledgePoint(id: '3', projectId: 'p', title: '全概率公式'),
    ]);
    expect(l.map((e) => e.id), ['1', '3']);
    expect(l.first.content, '更长的内容');
  });

  test('LLM 客户端：空内容自动重试，并带上 json_object（模拟接口）', () async {
    var calls = 0;
    Map<String, dynamic>? lastBody;
    final mock = MockClient((req) async {
      calls++;
      lastBody = jsonDecode(req.body);
      final content = calls == 1 ? '' : '{"ok":true}';
      return http.Response(jsonEncode({'choices': [{'message': {'content': content}}]}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final c = LlmClient(baseUrl: 'https://api.deepseek.com/', apiKey: 'k', model: 'deepseek-flash', client: mock);
    expect(await c.chatJson('输出 json'), {'ok': true});
    expect(calls, 2);
    expect(lastBody!['response_format'], {'type': 'json_object'});
    expect(lastBody!['model'], 'deepseek-flash');
  });

  test('完整生成流程（模拟 LLM）：知识点 → 闪卡和题目，带出处页码', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository(MemoryDocStore());
    final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    await repo.saveProject(Project(id: 'p', name: '概率论'));
    await repo.savePages([PageText(docId: 'd', projectId: 'p', page: 12, text: '第一章 随机事件\n条件概率定义：\$P(A\\mid B)=P(AB)/P(B)\$。一般 \$P(A\\mid B)\$ 不等于 \$P(A)\$，仅当 A 与 B 独立时成立。')]);
    await repo.replaceChunks('p', 'd', chunkPages('p', 'd', await repo.pages('p')));
    final mock = MockClient((req) async {
      final prompt = (jsonDecode(req.body)['messages'] as List).last['content'] as String;
      final content = prompt.contains('提取其中的知识点')
          ? r'{"knowledge_points":[{"title":"条件概率","type":"定义","content":"$P(A\\mid B)$","page":12}]}'
          : r'{"flashcards":[{"front":"条件概率公式？","back":"$P(A\\mid B)=\\dfrac{P(AB)}{P(B)}$","explanation":"定义","kp_index":0,"page":12}],'
              r'"questions":[{"type":"判断","stem":"$P(A\\mid B)$ 总是等于 $P(A)$","options":[],"answer":"错","explanation":"仅独立时成立","kp_index":0,"page":12}]}';
      return http.Response.bytes(utf8.encode(jsonEncode({'choices': [{'message': {'content': content}}]})), 200);
    });
    final gen = GenerationService(repo, settings, LlmClient(baseUrl: 'x', apiKey: 'k', model: 'm', client: mock));
    final r = await gen.generate('p', GenOptions(cardCount: 1, questionCount: 1, types: [QType.judge]), (_, _) {});
    expect(r.cards, 1);
    expect(r.questions, 1);
    final q = (await repo.questions(projectId: 'p')).single;
    expect(q.page, 12);
    expect(q.chapter, '第一章 随机事件');
    expect((await repo.cards(projectId: 'p')).single.back, r'$P(A\mid B)=\dfrac{P(AB)}{P(B)}$');
  });
}
