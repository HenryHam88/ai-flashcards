import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';
import 'study_test.dart' show FakeLlm;

void main() {
  late Settings st;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    st = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
  });

  test('解释 / 伴学模型各项留空时沿用出题模型；填了就用自己的；密钥留空也沿用', () async {
    expect((st.explain.baseUrl, st.explain.model, st.explain.contextTokens, st.explain.custom),
        (st.llmBaseUrl, 'deepseek-flash', 1000000, false));
    expect(st.study.custom, isFalse);
    st.explainModel = 'kimi-k2';
    st.explainBaseUrl = 'https://api.moonshot.cn/v1';
    st.explainContextK = 32;
    expect((st.explain.baseUrl, st.explain.model, st.explain.contextTokens, st.explain.custom),
        ('https://api.moonshot.cn/v1', 'kimi-k2', 32000, true));
    expect(st.study.custom, isFalse, reason: '互不影响');
    st.studyModel = 'qwen-plus';
    expect(st.study.contextTokens, 128000, reason: '只改模型名时按该模型自动估算');
    await st.setLlmKey('sk-llm');
    expect(await st.explainKey(), 'sk-llm');
    await st.setExplainKey('sk-explain');
    expect(await st.explainKey(), 'sk-explain');
    expect(Settings.secretKeys, containsAll(['explain_key', 'study_key']));
    expect(Settings.backupKeys, containsAll(['explain_model', 'study_model', 'explain_context_k']));
  });

  group('按功能选用模型，并各自决定是否借联网模型', () {
    late AppState s;
    late FakeLlm gen, explain, study, web;
    setUp(() async {
      gen = FakeLlm(answer: '出题模型的回答');
      explain = FakeLlm(answer: '解释模型的回答');
      study = FakeLlm(answer: '伴学模型的回答');
      web = FakeLlm(answer: '检索要点');
      s = AppState(Repository(MemoryDocStore()), st,
          llmFactory: (_, _) => gen, explainLlmFactory: (_, _) => explain, studyLlmFactory: (_, _) => study, webLlmFactory: (_, _) => web);
      await seedSampleData(s.repo);
    });

    test('未单独配置时，解释和伴学都走出题模型', () async {
      // 只注入出题模型时，两项都应落到它（单独的 factory 会覆盖，见下一个测试）
      final only = AppState(Repository(MemoryDocStore()), st, llmFactory: (_, _) => gen);
      expect(await only.explainLlm(), same(gen));
      expect(await only.studyLlm(), same(gen));
    });

    test('闪卡「AI 解释」走解释模型；伴学、导图、笔记讲解走伴学模型', () async {
      st.explainModel = 'kimi-k2';
      st.explainBaseUrl = 'https://api.moonshot.cn/v1';
      st.studyModel = 'qwen-plus';
      st.studyBaseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
      expect(await s.explainLlm(), isA<WebRelayLlm>(), reason: '解释模型不能直接联网，应借联网模型');
      expect(await s.studyLlm(), isA<WebRelayLlm>());
      expect(await s.llm(), same(gen), reason: '出题模型仍是 deepseek-flash，直接联网');

      await s.explain(itemId: 'c0', projectId: 'p1', itemText: '条件概率', docId: 'd1', page: 1);
      expect(explain.chats, isNotEmpty);
      expect(gen.chats, isEmpty);
      expect(web.chats, isNotEmpty, reason: '解释模型经联网模型检索');
      expect(explain.webs, [WebMode.off]);

      web.chats.clear();
      await s.studyAsk(StudyChat(id: 'c1', projectId: 'p1'), '讲讲条件概率');
      expect(study.chats, isNotEmpty);
      expect(web.chats, isNotEmpty);
    });

    test('伴学附件预算用伴学模型的上下文长度', () {
      st.studyModel = 'qwen-plus';
      st.studyContextK = 32;
      expect(st.study.contextTokens, 32000);
      expect(st.contextTokens, 1000000, reason: '出题模型上下文不变');
    });
  });
}
