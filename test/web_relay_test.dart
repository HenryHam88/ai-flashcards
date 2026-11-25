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

class BrokenLlm extends FakeLlm {
  @override
  Future<LlmReply> ask(List<Map<String, String>> messages,
      {WebMode web = WebMode.off, bool json = false, double temperature = 0.7, int retries = 3, void Function(String text)? onDelta, LlmStatus? onStatus, AiCancel? cancel}) async {
    throw LlmException('网络错误');
  }
}

void main() {
  late Settings st;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    st = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
  });

  test('出题模型是 deepseek-flash 时直接联网；换成其他服务时借联网模型；联网模型填错时关掉联网并说明', () {
    expect((st.webNative, st.webRelay, st.webUnavailable), (true, false, null));
    st.llmBaseUrl = 'https://api.moonshot.cn/v1';
    st.llmModel = 'kimi-k2';
    expect((st.webNative, st.webRelay, st.webUnavailable), (false, true, null));
    expect(st.web(), WebMode.deep);
    st.webModel = 'deepseek-v4-pro';
    expect(st.webUnavailable, contains('deepseek-flash'));
    expect(st.web(), WebMode.off);
  });

  test('联网密钥：单独填的优先，否则用 DeepSeek 出题模型或 DeepSeek OCR 的密钥', () async {
    await st.setLlmKey('sk-llm');
    await st.setOcrKey('sk-ocr');
    expect(await st.webKey(), 'sk-llm');
    st.llmBaseUrl = 'https://api.moonshot.cn/v1';
    expect(await st.webKey(), 'sk-ocr');
    await st.setWebKey('sk-web');
    expect(await st.webKey(), 'sk-web');
    expect(Settings.secretKeys, contains('web_key'));
    expect(Settings.backupKeys, containsAll(['web_model', 'llm_context_k']));
  });

  test('上下文长度：默认按模型，自己填了就用填的', () {
    expect(st.contextTokens, 1000000);
    st.llmModel = 'qwen-max';
    expect(st.contextTokens, 128000);
    st.llmContextK = 32;
    expect(st.contextTokens, 32000);
    st.llmContextK = 0;
    expect(st.contextTokens, 128000);
  });

  group('借联网模型', () {
    late AppState s;
    late FakeLlm main, web;
    setUp(() async {
      main = FakeLlm(answer: '主模型的回答');
      web = FakeLlm(answer: '要点：条件概率定义 [百科]');
      s = AppState(Repository(MemoryDocStore()), st, llmFactory: (_, _) => main, webLlmFactory: (_, _) => web);
      await seedSampleData(s.repo);
    });

    test('DeepSeek 直接联网时不经过联网模型', () async {
      expect(await s.llm(), same(main));
    });

    test('伴学：先让联网模型检索，再把结果交给出题模型回答，来源来自检索', () async {
      st.llmBaseUrl = 'https://api.moonshot.cn/v1';
      st.llmModel = 'kimi-k2';
      final chat = await s.studyAsk(StudyChat(id: 'c1', projectId: 'p1'), '条件概率是什么');
      expect(web.webs, [WebMode.deep]);
      expect(web.chats.single.first['content'], WebRelayLlm.searchPrompt);
      expect(web.chats.single.last['content'], contains('条件概率是什么'));
      expect(main.webs, [WebMode.off], reason: '出题模型本身不带联网工具');
      final sys = main.chats.single.first['content']!;
      expect(sys, contains('【联网检索结果】'));
      expect(sys, contains('要点：条件概率定义 [百科]'));
      expect(chat.messages.last['content'], '主模型的回答');
      expect(WebSource.decode(chat.messages.last['sources']).single.url, 'https://example.com/p');
    });

    test('联网检索失败时照常回答，并说明这次没有联网', () async {
      st.llmBaseUrl = 'https://api.moonshot.cn/v1';
      final r = await WebRelayLlm(main, BrokenLlm()).ask([{'role': 'user', 'content': '问'}], web: WebMode.normal);
      expect(r.content, startsWith('主模型的回答'));
      expect(r.content, contains('联网检索失败'));
      expect(r.sources, isEmpty);
    });

    test('JSON 调用（批改 / 导图）：检索结果拼进提示，出题模型仍用 JSON 模式；不联网的调用原样转交', () async {
      final relay = WebRelayLlm(main, web);
      await relay.askJson('批改这道题', web: WebMode.deep);
      expect(main.prompts.single, contains('批改这道题'));
      expect(main.prompts.single, contains('要点：条件概率定义'));
      await relay.askJson('出题', web: WebMode.off);
      expect(main.prompts.last, '出题');
      expect(web.chats.length, 1);
      expect(await relay.chat([{'role': 'user', 'content': 'x'}]), '主模型的回答');
    });
  });
}
