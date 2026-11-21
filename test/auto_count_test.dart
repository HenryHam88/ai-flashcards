import 'dart:convert';

import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const page1 = r'''第一章 随机事件
1.1 样本空间 随机试验所有可能结果组成的集合称为样本空间，记为 $\Omega$。
1.2 条件概率 设 $P(B)>0$，称 $P(A\mid B)=\frac{P(AB)}{P(B)}$ 为条件概率。''';
const page2 = r'''第二章 随机变量
2.1 分布函数 $F(x)=P(X\le x)$ 称为随机变量 $X$ 的分布函数，它单调不减、右连续。''';

String kpJson(List<String> titles, int page) => jsonEncode({
      'knowledge_points': [
        for (final t in titles) {'title': t, 'type': '定义', 'content': '$t 的内容', 'page': page}
      ]
    });

void main() {
  group('数量推算', () {
    test('闪卡每个知识点 1 张，题目随难度 1–3 道', () {
      expect(questionsPerKp('基础'), 1);
      expect(questionsPerKp('中等'), 2);
      expect(questionsPerKp('混合'), 2);
      expect(questionsPerKp('拔高'), 3);
      final a = deriveAutoCount(6, difficulty: '中等', cap: 100);
      expect((a.cards, a.questions, a.capped), (6, 12, false));
      final b = deriveAutoCount(6, difficulty: '拔高', cards: false, cap: 100);
      expect((b.cards, b.questions), (0, 18));
      final c = deriveAutoCount(6, difficulty: '基础', questions: false, cap: 100);
      expect((c.cards, c.questions), (6, 0));
      expect(deriveAutoCount(0, difficulty: '中等').total, 0);
    });

    test('超过上限按比例缩减，两类都要时各至少 1', () {
      final a = deriveAutoCount(30, difficulty: '中等', cap: 40); // 原本 30 + 60 = 90
      expect(a.total, 40);
      expect(a.capped, isTrue);
      expect(a.rawTotal, 90);
      expect(a.cards, 13); // 40 × 30/90
      expect(a.questions, 27);
      final b = deriveAutoCount(100, difficulty: '拔高', cap: 3);
      expect((b.cards, b.questions), (1, 2));
      final c = deriveAutoCount(50, difficulty: '基础', questions: false, cap: 20);
      expect((c.cards, c.questions), (20, 0));
      expect(deriveAutoCount(5, difficulty: '中等', cap: 0).total, 1); // 上限至少 1
    });

    test('数量模式写进模板 / 项目默认；旧数据默认是固定数量', () {
      final o = GenOptions(autoCount: true, autoQuestions: false);
      final r = GenOptions.fromJson(jsonDecode(jsonEncode(o.toJson())));
      expect((r.autoCount, r.autoCards, r.autoQuestions), (true, true, false));
      final old = GenOptions.fromJson({'cardCount': 15});
      expect((old.autoCount, old.cardCount, old.questionCount), (false, 15, 10));
      expect(GenOptions().toJson().containsKey('autoCount'), isFalse);
    });
  });

  test('知识点 JSON 解析：兼容 items，忽略非对象条目，页码限制在分块范围内', () {
    final c = Chunk(id: 'ch', projectId: 'p', docId: 'd', chapter: '第一章', section: '1.1', pageStart: 3, pageEnd: 5, text: '');
    final l = parseKps('p', c, {
      'items': [
        {'title': '样本空间', 'type': '定义', 'content': r'$\Omega$', 'page': 99},
        '不是对象',
        {'title': '条件概率', 'page': '4'},
      ]
    });
    expect(l.map((k) => k.title), ['样本空间', '条件概率']);
    expect(l.map((k) => k.page), [5, 4]);
    expect(l.first.id, 'ch_k0');
    expect(l.first.chapter, '第一章');
    expect(parseKps('p', c, {'foo': 1}), isEmpty);
  });

  group('规划与生成', () {
    late Repository repo;
    late Settings settings;
    setUp(() async {
      SharedPreferences.setMockInitialValues({'auto_cap': 40});
      repo = Repository(MemoryDocStore());
      settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
      await repo.saveProject(Project(id: 'p', name: '概率论'));
      await repo.savePages([
        PageText(docId: 'd1', projectId: 'p', page: 1, text: page1),
        PageText(docId: 'd2', projectId: 'p', page: 1, text: page2),
      ]);
      await repo.replaceChunks('p', 'd1', chunkPages('p', 'd1', await repo.pages('p', docId: 'd1')));
      await repo.replaceChunks('p', 'd2', chunkPages('p', 'd2', await repo.pages('p', docId: 'd2')));
    });

    LlmClient llm(String Function(String prompt) reply, List<String> log) => LlmClient(
        baseUrl: 'x',
        apiKey: 'k',
        model: 'm',
        client: MockClient((req) async {
          final prompt = (jsonDecode(req.body)['messages'] as List).last['content'] as String;
          log.add(prompt);
          final r = reply(prompt);
          if (r == '500') return http.Response('err', 500);
          return http.Response.bytes(utf8.encode(jsonEncode({'choices': [{'message': {'content': r}}]})), 200);
        }));

    String kpReply(String p) => p.contains('第一章')
        ? kpJson(['样本空间', '条件概率', '乘法公式'], 1)
        : kpJson(['分布函数', '分布函数的性质'], 1);

    test('多份资料：列出知识点并推算数量，确认后生成时复用、不再分析', () async {
      final log = <String>[];
      final client = llm((p) {
        if (p.contains('提取其中的知识点')) return kpReply(p);
        final n = RegExp(r'闪卡数量：(\d+)').firstMatch(p)!.group(1);
        final cards = [
          for (var i = 0; i < int.parse(n!); i++)
            {'front': '问题$i', 'back': '答案$i', 'kp_index': i, 'page': 1}
        ];
        return jsonEncode({'flashcards': cards, 'questions': []});
      }, log);
      final svc = GenerationService(repo, settings, client, qualityCheck: false);
      final o = GenOptions(autoCount: true, autoQuestions: false, difficulty: '中等');
      final plan = await svc.plan('p', o, (_, _) {});
      expect(plan.kps.length, 5);
      expect(plan.chunks, 2);
      expect(plan.byChapter.keys.length, 2);
      expect((plan.count.cards, plan.count.questions), (5, 0));
      final planningCalls = log.length;
      expect(planningCalls, 2);

      o.cardCount = plan.count.cards;
      o.questionCount = plan.count.questions;
      final r = await svc.generate('p', o, (_, _) {}, planned: plan.kps);
      expect(log.where((p) => p.contains('提取其中的知识点')).length, 2); // 没有再次分析
      expect(r.cards, 5);
      expect(r.kps, 5);
      final gen = log.firstWhere((p) => p.contains('生成学习闪卡'));
      for (final t in ['样本空间', '条件概率', '乘法公式', '分布函数']) {
        expect(gen, contains(t)); // 知识点列表写进出题提示词
      }
    });

    test('按章节规划；题目数量随难度并受上限约束', () async {
      final log = <String>[];
      final svc = GenerationService(repo, settings, llm(kpReply, log), qualityCheck: false);
      final chapter = (await repo.chunks('p')).first.chapter;
      final plan = await svc.plan('p', GenOptions(autoCount: true, scope: 'chapters', chapters: [chapter], difficulty: '拔高'),
          (_, _) {});
      expect(plan.kps.length, 3);
      expect((plan.count.cards, plan.count.questions), (3, 9));
      final capped = await svc.plan('p', GenOptions(autoCount: true, difficulty: '拔高'), (_, _) {}, cap: 8);
      expect(capped.count.total, 8);
      expect(capped.count.capped, isTrue);
      // 没选题型时不出题
      final noTypes = await svc.plan('p', GenOptions(autoCount: true, types: []), (_, _) {});
      expect(noTypes.count.questions, 0);
    });

    test('规划失败：接口出错、JSON 无法解析、没有知识点、范围为空，都抛 PlanException', () async {
      Future<Object?> fail(String Function(String) reply, [GenOptions? o]) async {
        try {
          await GenerationService(repo, settings, llm(reply, []), qualityCheck: false)
              .plan('p', o ?? GenOptions(autoCount: true), (_, _) {});
          return null;
        } catch (e) {
          return e;
        }
      }

      final e1 = await fail((_) => '500');
      expect(e1, isA<PlanException>());
      expect('$e1', startsWith('分析知识点失败'));
      expect(await fail((_) => '这不是 json'), isA<PlanException>());
      final e3 = await fail((_) => '{"knowledge_points":[]}');
      expect('$e3', '没有识别到知识点');
      final e4 = await fail(kpReply, GenOptions(autoCount: true, scope: 'chapters', chapters: ['不存在']));
      expect('$e4', '所选范围内没有内容');
    });

    test('固定数量的生成流程不受影响', () async {
      final log = <String>[];
      final client = llm((p) {
        if (p.contains('提取其中的知识点')) return kpReply(p);
        expect(p, contains('闪卡数量：'));
        return jsonEncode({
          'flashcards': [
            {'front': '问题', 'back': '答案', 'kp_index': 0, 'page': 1}
          ],
          'questions': []
        });
      }, log);
      final r = await GenerationService(repo, settings, client, qualityCheck: false)
          .generate('p', GenOptions(cardCount: 1, questionCount: 0), (_, _) {});
      expect(r.cards, 1);
      expect(log.where((p) => p.contains('闪卡数量：1 张')).length, 1);
    });
  });
}
