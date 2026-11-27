import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/providers.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'study_test.dart' show FakeLlm;

void main() {
  late Settings st;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    st = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
  });

  test('内置服务商都有接口地址（自定义除外）', () {
    expect(ProviderPreset.all.map((p) => p.kind).toList(),
        ['deepseek', 'qwen', 'zhipu', 'kimi', 'doubao', 'siliconflow', 'openrouter', 'ollama', 'custom']);
    for (final p in ProviderPreset.all) {
      if (p.kind == 'custom') {
        expect(p.baseUrl, isEmpty);
      } else {
        expect(p.baseUrl, startsWith('http'));
      }
    }
    expect(ProviderPreset.of('ollama').keyOptional, isTrue);
  });

  test('从旧的接口、模型、密钥字段自动迁移；解释未填则跟随出题', () async {
    SharedPreferences.setMockInitialValues({
      'llm_base': 'https://api.deepseek.com',
      'llm_model': 'deepseek-v4-pro',
      'explain_model': 'kimi-k2',
      'explain_base': 'https://api.moonshot.cn/v1',
      'web_model': 'deepseek-flash',
    });
    final secrets = MemorySecretStore();
    await secrets.write('llm_key', 'sk-old');
    await secrets.write('explain_key', 'sk-exp');
    st = Settings(await SharedPreferences.getInstance(), secrets);
    await st.ensureMigrated();
    expect(st.llmModel, 'deepseek-v4-pro');
    expect(st.providers.map((p) => p.kind), containsAll(['deepseek', 'kimi']));
    expect(st.assignment(LlmUse.explain).follow, isFalse);
    expect(st.explain.model, 'kimi-k2');
    expect(st.study.custom, isFalse);
    expect(st.study.model, 'deepseek-v4-pro');
    expect(await st.llmKey(), 'sk-old');
    expect(await st.explainKey(), 'sk-exp');
    expect(await st.studyKey(), 'sk-old');
  });

  test('拉取模型：解析 /models 列表；失败时提示可以手动添加', () async {
    final ok = MockClient((r) async {
      expect(r.url.toString(), 'https://api.deepseek.com/models');
      expect(r.headers['Authorization'], 'Bearer sk-test');
      return http.Response('{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}', 200);
    });
    expect((await ModelCatalog.fetch('https://api.deepseek.com', 'sk-test', client: ok)).map((e) => e.id), ['deepseek-flash', 'deepseek-v4-pro']);
    expect(ModelCatalog.modelsUrl('https://api.deepseek.com/v1/'), Uri.parse('https://api.deepseek.com/v1/models'));
    expect(ModelCatalog.modelsUrl('https://api.deepseek.com/chat/completions'), Uri.parse('https://api.deepseek.com/models'));

    final bad = MockClient((r) async => http.Response('nope', 401));
    expect(() => ModelCatalog.fetch('https://api.deepseek.com', 'x', client: bad), throwsA(isA<FetchModelsException>()));
    try {
      await ModelCatalog.fetch('https://api.deepseek.com', 'x', client: bad);
    } on FetchModelsException catch (e) {
      expect('$e', contains('手动添加'));
    }
  });

  test('各模型家族只显示文档里真正不同的思考档位；不认识的模型没有选项', () {
    List<String> ids(String kind, String model) => Reasoning.of(kind, model)?.levels.map((l) => l.id).toList() ?? const [];
    expect(ids('deepseek', 'deepseek-flash'), ['none', 'low', 'high', 'max']);
    expect(Reasoning.of('deepseek', 'deepseek-flash')!.levels.map((l) => l.label).toList(), ['关闭', '较低', '较高', '最高']);
    expect(ids('qwen', 'qwen4-max'), ['none', 'low', 'high', 'xhigh']);
    expect(ids('qwen', 'qwen3.8-plus'), ['none', 'low', 'medium', 'xhigh']);
    expect(ids('qwen', 'qwen3-max'), ['none', 'budget_short', 'budget_mid', 'budget_long']);
    expect(ids('zhipu', 'glm-4.6'), ['none', 'enabled']);
    expect(ids('zhipu', 'glm-5.2'), ['none', 'high', 'max']);
    expect(ids('zhipu', 'glm-5.3'), ['low', 'high', 'max']);
    expect(ids('zhipu', 'glm-4.7'), isEmpty, reason: '强制思考，没有可选项');
    expect(ids('kimi', 'kimi-k2.6'), ['none', 'enabled']);
    expect(ids('kimi', 'kimi-k2.7-code'), isEmpty);
    expect(ids('kimi', 'kimi-k3'), ['low', 'high', 'max']);
    expect(ids('doubao', 'doubao-seed-2.1'), ['minimal', 'low', 'medium', 'high']);
    expect(ids('openrouter', 'deepseek/deepseek-flash'), ['none', 'low', 'high', 'max']);
    expect(ids('siliconflow', 'some-unknown-model'), isEmpty);
    expect(ids('custom', 'gpt-mystery'), isEmpty);
    expect(Reasoning.of('deepseek', 'deepseek-flash'), isNotNull);
  });

  test('思考档位按功能 + 模型分别记住；没选过时不往请求里加字段', () {
    final p = st.providers.first;
    st.setReasoning(LlmUse.generate, p.id, 'deepseek-flash', 'low');
    st.setReasoning(LlmUse.study, p.id, 'deepseek-flash', 'max');
    expect(st.reasoningOf(LlmUse.generate, providerId: p.id, model: 'deepseek-flash'), 'low');
    expect(st.reasoningOf(LlmUse.study, providerId: p.id, model: 'deepseek-flash'), 'max');
    expect(st.reasoningOf(LlmUse.explain, providerId: p.id, model: 'deepseek-flash'), isNull);

    final c = LlmClient(baseUrl: 'https://api.deepseek.com', apiKey: 'k', model: 'deepseek-flash', kind: 'deepseek');
    final off = c.requestBody([
      {'role': 'user', 'content': 'hi'}
    ]);
    expect(off.containsKey('thinking'), isFalse);
    expect(off.containsKey('reasoning_effort'), isFalse);

    final chosen = LlmClient(baseUrl: 'https://api.deepseek.com', apiKey: 'k', model: 'deepseek-flash', kind: 'deepseek', reasoning: 'low');
    final body = chosen.requestBody([
      {'role': 'user', 'content': 'hi'}
    ]);
    expect(body['thinking'], {'type': 'enabled'});
    expect(body['reasoning_effort'], 'low');

    final deep = chosen.requestBody([
      {'role': 'user', 'content': 'hi'}
    ], web: WebMode.deep);
    expect(deep['thinking'], {'type': 'enabled'});
    expect(deep['reasoning_effort'], 'low');
    expect(deep['tools'], isNotEmpty);

    final closed = LlmClient(baseUrl: 'https://api.deepseek.com', apiKey: 'k', model: 'deepseek-flash', kind: 'deepseek', reasoning: 'none');
    final forced = closed.requestBody([
      {'role': 'user', 'content': 'hi'}
    ], web: WebMode.deep);
    expect(forced['thinking'], {'type': 'enabled'}, reason: '深度搜索不能关闭思考');
    expect(forced.containsKey('reasoning_effort'), isFalse);

    final qwen = LlmClient(baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', apiKey: 'k', model: 'qwen3-max', kind: 'qwen', reasoning: 'budget_short');
    final qb = qwen.requestBody([
      {'role': 'user', 'content': 'hi'}
    ]);
    expect(qb['enable_thinking'], isTrue);
    expect(qb['thinking_budget'], 4096);
  });

  test('联网选择只允许 DeepSeek 的 flash 模型', () {
    final ds = st.providers.firstWhere((p) => p.isDeepSeek);
    expect(ds.models, contains('deepseek-flash'));
    st.setAssignment(LlmUse.web, ModelChoice(providerId: ds.id, modelId: 'deepseek-flash'));
    expect(st.webModel, 'deepseek-flash');
    expect(st.webUnavailable, isNull);
  });

  test('看图能力按模型名判断', () {
    expect(ModelCatalog.canSeeImages('deepseek-flash'), isTrue);
    expect(ModelCatalog.canSeeImages('deepseek-v4-pro'), isFalse);
    expect(ModelCatalog.canSeeImages('qwen3-vl-plus'), isTrue);
    expect(LlmClient.visionUnavailableReason('https://api.deepseek.com', 'deepseek-v4-pro'), isNotNull);
    expect(LlmClient.visionUnavailableReason('https://api.deepseek.com', 'deepseek-flash'), isNull);
  });

  test('伴学可以按对话换模型', () async {
    final gen = FakeLlm(answer: '默认回答');
    final study = FakeLlm(answer: '指定模型的回答');
    final qwen = st.addPreset(ProviderPreset.of('qwen'));
    qwen.models.add('qwen-plus');
    st.upsertProvider(qwen);
    st.setAssignment(LlmUse.study, ModelChoice(providerId: qwen.id, modelId: 'qwen-plus'));
    final s = AppState(Repository(MemoryDocStore()), st, llmFactory: (_, _) => gen, studyLlmFactory: (_, _) => study);
    final chat = StudyChat(id: 'c1', projectId: 'p1', llmProvider: qwen.id, llmModel: 'qwen-plus');
    expect(s.studyEndpoint(chat).model, 'qwen-plus');
    expect(s.studyEndpoint(chat).custom, isTrue);
    expect(s.studyEndpoint().model, 'qwen-plus');
    st.setAssignment(LlmUse.study, const ModelChoice());
    expect(s.studyEndpoint().model, 'deepseek-flash');
    expect(s.studyEndpoint(chat).model, 'qwen-plus', reason: '对话自己的选择优先');
  });

  test('拉取模型：接口给了更好认的名字才当昵称，不凭 ID 编，也不覆盖已起的名', () async {
    expect(ModelCatalog.niceName('gpt-4o', 'GPT-4o'), 'GPT-4o');
    expect(ModelCatalog.niceName('ep-20250101-abcdef', '豆包 Pro'), '豆包 Pro');
    expect(ModelCatalog.niceName('m1', 'm1'), isNull, reason: '跟 ID 一样就不用');
    expect(ModelCatalog.niceName('m1', '  '), isNull);
    expect(ModelCatalog.niceName('m1', null), isNull);
    expect(ModelCatalog.niceName('foo', 'ep-20250101-abcdef'), isNull, reason: '另一个模型 ID 不算好认的名字');
    expect(ModelCatalog.niceName('foo', 'deepseek-flash'), isNull);

    final parsed = ModelCatalog.parse(
        '{"data":[{"id":"ep-1","display_name":"豆包 Pro"},{"id":"gpt-4o","name":"GPT-4o"},{"id":"plain"},{"name":"only-name"},{"id":"m","displayName":"m"},{"id":"a","name":"ep-xxxx-yyyy"}]}');
    expect(parsed.map((e) => (e.id, e.name)).toList(), [
      ('ep-1', '豆包 Pro'),
      ('gpt-4o', 'GPT-4o'),
      ('plain', null),
      ('only-name', null),
      ('m', null),
      ('a', null),
    ]);

    final p = LlmProvider(id: 'x', kind: 'custom', name: '火山引擎', baseUrl: 'https://x/v1');
    p.setModelName('ep-1', '我起的名');
    p.applyFetched(parsed);
    expect(p.models, ['ep-1', 'gpt-4o', 'plain', 'only-name', 'm', 'a']);
    expect(p.labelOf('ep-1'), '我起的名', reason: '已经起过的不覆盖');
    expect(p.labelOf('gpt-4o'), 'GPT-4o');
    expect(p.labelOf('plain'), 'plain');
    expect(p.modelNames.containsKey('plain'), isFalse);

    final ok = MockClient((_) async => http.Response('{"data":[{"id":"ep-1","display_name":"Doubao Pro"}]}', 200));
    final list = await ModelCatalog.fetch('https://api.example.com/v1', '', client: ok);
    expect(list.single.id, 'ep-1');
    expect(list.single.name, 'Doubao Pro');
  });

  test('服务商可以改名；改接口地址不会把名字改回去；旧数据保持原来的名字', () {
    final p = st.providers.first;
    expect(p.name, 'DeepSeek');
    st.renameProvider(p.id, '  我的 DeepSeek  ');
    expect(st.providerById(p.id)!.name, '我的 DeepSeek');
    st.renameProvider(p.id, '   ');
    expect(st.providerById(p.id)!.name, '我的 DeepSeek', reason: '空名字不改');

    final custom = st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://x/v1', name: '火山引擎');
    expect(custom.name, '火山引擎');
    expect(st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://y/v1').name, '自定义', reason: '没填名字就还叫自定义');

    st.llmBaseUrl = 'https://api.moonshot.cn/v1';
    final after = st.providerById(p.id)!;
    expect(after.kind, 'kimi');
    expect(after.baseUrl, 'https://api.moonshot.cn/v1');
    expect(after.name, '我的 DeepSeek');

    final old = LlmProvider.fromJson({'id': 'o', 'kind': 'custom', 'name': '公司接口', 'baseUrl': 'https://z/v1', 'models': []});
    expect(old.name, '公司接口');
  });
}
