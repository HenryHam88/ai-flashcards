import 'dart:convert';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/conn_test.dart';
import 'package:ai_flashcards/services/providers.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/explain_sheet.dart';
import 'package:ai_flashcards/ui/llm_settings_page.dart';
import 'package:ai_flashcards/ui/snippet_bar.dart';
import 'package:ai_flashcards/ui/study_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';
import 'study_test.dart' show FakeLlm;

void main() {
  late Settings st;
  late AppState state;
  late FakeLlm llm;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    st = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    llm = FakeLlm(answer: '好的，讲给你听。');
    state = AppState(Repository(MemoryDocStore()), st, llmFactory: (_, _) => llm);
    await state.settings.setLlmKey('sk-test');
    await seedSampleData(state.repo);
  });

  group('模型显示名称', () {
    test('保存、读取；旧数据没有名称字段也能读', () {
      final p = LlmProvider(id: 'a', kind: 'custom', name: '自定义', baseUrl: 'https://x/v1', models: ['m1', 'm2']);
      p.setModelName('m1', '  我的 DeepSeek ');
      expect(p.labelOf('m1'), '我的 DeepSeek');
      expect(p.labelOf('m2'), 'm2', reason: '没起名字就显示模型 ID');
      final back = LlmProvider.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.labelOf('m1'), '我的 DeepSeek');
      expect(back.models, ['m1', 'm2']);
      final old = LlmProvider.fromJson({'id': 'o', 'kind': 'custom', 'name': 'n', 'baseUrl': 'u', 'models': ['x']});
      expect(old.labelOf('x'), 'x');
      expect(old.toJson().containsKey('modelNames'), isFalse);
    });

    test('名称留空或和 ID 一样就是清除', () {
      final p = LlmProvider(id: 'a', kind: 'custom', name: 'n', baseUrl: 'u', models: ['m1']);
      p.setModelName('m1', '起个名');
      p.setModelName('m1', '');
      expect(p.modelNames, isEmpty);
      p.setModelName('m1', 'm1');
      expect(p.modelNames, isEmpty);
    });

    test('Settings.modelLabel：起过名的显示名称，没有就显示 ID；服务商不存在时也不出错', () {
      final p = st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://x/v1');
      p.models.add('qwen-max-0125');
      p.setModelName('qwen-max-0125', '千问');
      st.upsertProvider(p);
      expect(st.modelLabel(p.id, 'qwen-max-0125'), '千问');
      expect(st.modelLabel(p.id, 'other'), 'other');
      expect(st.modelLabel('missing', 'z'), 'z');
      expect(st.modelLabel(null, 'z'), 'z');
    });

    test('删除模型：名称一起去掉；正在用它的功能改回跟随（出题改用别的模型）', () {
      final p = st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://x/v1');
      p.models.addAll(['a', 'b']);
      p.setModelName('a', 'A 名');
      st.upsertProvider(p);
      st.setAssignment(LlmUse.generate, ModelChoice(providerId: p.id, modelId: 'a'));
      st.setAssignment(LlmUse.explain, ModelChoice(providerId: p.id, modelId: 'a'));
      st.setAssignment(LlmUse.study, ModelChoice(providerId: p.id, modelId: 'b'));
      st.removeModel(p.id, 'a');
      final after = st.providerById(p.id)!;
      expect(after.models, ['b']);
      expect(after.modelNames, isEmpty);
      expect(st.assignment(LlmUse.generate).modelId, 'b');
      expect(st.assignment(LlmUse.explain).follow, isTrue);
      expect(st.assignment(LlmUse.study).modelId, 'b');
    });

    testWidgets('选模型的列表、伴学上的小标签都显示名称（没有名称显示 ID）', (t) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final p = st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://x/v1');
      p.models.addAll(['qwen-max-0125', 'plain-model']);
      p.setModelName('qwen-max-0125', '我的千问');
      st.upsertProvider(p);
      st.setAssignment(LlmUse.generate, ModelChoice(providerId: p.id, modelId: 'qwen-max-0125'));
      await t.pumpWidget(StudyApp(state: state, home: Scaffold(body: Builder(builder: (ctx) => TextButton(onPressed: () => showModelPicker(ctx, st, use: LlmUse.explain, allowFollow: true), child: const Text('open'))))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('我的千问'), findsOneWidget);
      expect(find.text('qwen-max-0125'), findsOneWidget, reason: '名称下面小字写着模型 ID');
      expect(find.text('plain-model'), findsOneWidget);
    });

    testWidgets('AI 模型页：「出题」一栏显示名称，不显示一长串模型 ID', (t) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final p = st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://x/v1');
      p.models.add('ep-20250101-abcdef');
      p.setModelName('ep-20250101-abcdef', '豆包 Pro');
      st.upsertProvider(p);
      st.setAssignment(LlmUse.generate, ModelChoice(providerId: p.id, modelId: 'ep-20250101-abcdef'));
      await t.pumpWidget(StudyApp(state: state, home: const LlmSettingsPage()));
      await t.pumpAndSettle();
      expect(find.text('豆包 Pro'), findsWidgets);
      expect(find.text('ep-20250101-abcdef'), findsNothing);
      expect(find.text('管理、改名、测试'), findsWidgets);
    });

    Widget sheetHost(LlmProvider p, {String? modelId, required void Function(ModelEditResult?) onResult, LlmTester? tester}) => StudyApp(
        state: state,
        home: Scaffold(
            body: Builder(
                builder: (ctx) => TextButton(
                    onPressed: () async => onResult(await showModalBottomSheet<ModelEditResult>(
                        context: ctx, isScrollControlled: true, builder: (c) => SizedBox(height: 700, child: ModelEditSheet(st: st, provider: p, modelId: modelId, tester: tester)))),
                    child: const Text('open')))));

    testWidgets('添加模型：填 ID 和显示名称，点测试看到结果，再添加', (t) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final p = st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://x/v1');
      await st.setProviderKey(p.id, 'sk-abc');
      ModelEditResult? got;
      final asked = <String>[];
      await t.pumpWidget(sheetHost(p, onResult: (r) => got = r, tester: ({required baseUrl, required apiKey, required model, keyOptional = false}) async {
        asked.add('$baseUrl|$apiKey|$model');
        return const TestResult.fail('找不到这个模型，检查模型名有没有写对（404）');
      }));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, '模型 ID'), 'my-model');
      await t.enterText(find.widgetWithText(TextField, '显示名称（可不填）'), '我的模型');
      await t.tap(find.text('测试'));
      await t.pumpAndSettle();
      expect(asked, ['https://x/v1|sk-abc|my-model']);
      expect(find.textContaining('找不到这个模型'), findsOneWidget);
      // 改了模型 ID，上一次的结果不再算数
      await t.enterText(find.widgetWithText(TextField, '模型 ID'), 'my-model-2');
      await t.pump();
      expect(find.textContaining('找不到这个模型'), findsNothing);
      await t.tap(find.text('添加'));
      await t.pumpAndSettle();
      expect(got?.id, 'my-model-2');
      expect(got?.name, '我的模型');
      expect(got?.delete, isFalse);
    });

    testWidgets('测试成功显示「可以用」；没填模型 ID 不让添加', (t) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final p = st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://x/v1');
      ModelEditResult? got;
      await t.pumpWidget(sheetHost(p, onResult: (r) => got = r, tester: ({required baseUrl, required apiKey, required model, keyOptional = false}) async => const TestResult.ok('可以用，用时 0.4 秒')));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('添加'));
      await t.pump();
      expect(find.text('先填写模型 ID'), findsOneWidget);
      expect(got, isNull);
      await t.enterText(find.widgetWithText(TextField, '模型 ID'), 'm');
      await t.tap(find.text('测试'));
      await t.pumpAndSettle();
      expect(find.text('可以用，用时 0.4 秒'), findsOneWidget);
    });

    testWidgets('编辑已有模型：改名、删除；模型 ID 不能改', (t) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final p = st.addPreset(ProviderPreset.of('custom'), baseUrl: 'https://x/v1');
      p.models.add('m1');
      p.setModelName('m1', '旧名字');
      ModelEditResult? got;
      await t.pumpWidget(sheetHost(p, modelId: 'm1', onResult: (r) => got = r));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.widgetWithText(TextField, '模型 ID'), findsNothing);
      expect(find.text('m1'), findsOneWidget);
      expect(find.widgetWithText(TextField, '显示名称（可不填）'), findsOneWidget);
      expect(find.text('旧名字'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, '显示名称（可不填）'), '新名字');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect((got?.id, got?.name, got?.delete), ('m1', '新名字', false));

      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('删除这个模型'));
      await t.pumpAndSettle();
      expect((got?.id, got?.delete), ('m1', true));
    });
  });

  group('项目提示词', () {
    test('拼接：没选原样返回；选了接在问题后面；只选提示词也能发', () {
      PromptSnippet s(String t) => PromptSnippet(id: t, text: t);
      expect(PromptSnippet.compose('  讲讲贝叶斯 ', []), '讲讲贝叶斯');
      expect(PromptSnippet.compose('', []), '');
      expect(PromptSnippet.compose('讲讲贝叶斯', [s('多举例子')]), '讲讲贝叶斯\n\n要求：多举例子');
      expect(PromptSnippet.compose('讲讲贝叶斯', [s('多举例子'), s('别推导')]), '讲讲贝叶斯\n\n要求：\n1. 多举例子\n2. 别推导');
      expect(PromptSnippet.compose('', [s('多举例子')]), '多举例子');
      expect(PromptSnippet.compose('', [s('多举例子'), s('别推导')]), '请按下面的要求来：\n1. 多举例子\n2. 别推导');
      expect(PromptSnippet.compose('问题', [PromptSnippet(id: 'x', text: '  ')]), '问题', reason: '空内容的提示词不带');
    });

    test('按钮上的文字：有名字用名字，否则取内容开头', () {
      expect(PromptSnippet(id: '1', name: '考研', text: '按考研数学的角度讲').label, '考研');
      expect(PromptSnippet(id: '1', text: '按考研数学的角度讲，多举例子，少说废话').label, '按考研数学的角度讲，多举…');
      expect(PromptSnippet(id: '1', text: '短').label, '短');
    });

    test('随项目保存；旧项目没有这个字段也能读；空的不写', () {
      final p = Project(id: 'p', name: 'n', snippets: [PromptSnippet(id: 'a', name: '考研', text: '多举例'), PromptSnippet(id: 'b', text: '别推导')]);
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.snippets.map((e) => (e.id, e.name, e.text)), [('a', '考研', '多举例'), ('b', '', '别推导')]);
      expect(Project(id: 'p', name: 'n').toJson().containsKey('snippets'), isFalse);
      expect(Project.fromJson({'id': 'p', 'name': 'n'}).snippets, isEmpty);
    });

    test('每个项目各管各的；可以有多条，增删改互不影响', () async {
      final a = SnippetPicker(state, 'p1')..addListener(() {});
      final b = SnippetPicker(state, 'p2');
      await a.load();
      expect(a.all, isEmpty);
      await a.upsert(PromptSnippet(id: 's1', name: '考研', text: '按考研数学的角度讲'));
      await a.upsert(PromptSnippet(id: 's2', text: '多举例子'));
      await a.upsert(PromptSnippet(id: 's3', text: '只讲结论'));
      await a.upsert(PromptSnippet(id: 's2', text: '多举两个例子'));
      await b.load();
      expect(b.all, isEmpty, reason: '换个项目是另一套');
      final fresh = SnippetPicker(state, 'p1');
      await fresh.load();
      expect(fresh.all.map((e) => e.text), ['按考研数学的角度讲', '多举两个例子', '只讲结论']);
      await a.remove('s1');
      await fresh.load();
      expect(fresh.all.map((e) => e.id), ['s2', 's3']);
      expect((await state.repo.project('p1'))!.name, '概率论 第3章', reason: '其它字段不受影响');
    });

    test('选中状态：可多选；删掉的提示词自动取消选中；发送后清空', () async {
      final a = SnippetPicker(state, 'p1');
      await a.upsert(PromptSnippet(id: 's1', text: '多举例子'));
      await a.upsert(PromptSnippet(id: 's2', text: '别推导'));
      expect(a.compose('讲讲'), '讲讲', reason: '没点就和平时一样');
      a.toggle('s2');
      a.toggle('s1');
      expect(a.picked.map((e) => e.id), ['s1', 's2'], reason: '按添加顺序');
      expect(a.compose('讲讲'), '讲讲\n\n要求：\n1. 多举例子\n2. 别推导');
      a.toggle('s1');
      expect(a.compose('讲讲'), '讲讲\n\n要求：别推导');
      await a.remove('s2');
      expect(a.hasPicked, isFalse);
      a.toggle('s1');
      a.clearSelection();
      expect(a.hasPicked, isFalse);
    });

    Future<void> settle(WidgetTester t, [int n = 8]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> phone(WidgetTester t) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
    }

    testWidgets('提示词条：点一下选中、再点取消；还没有提示词时只有一个「常用提示词」入口', (t) async {
      await phone(t);
      final picker = SnippetPicker(state, 'p1');
      await t.runAsync(() => picker.upsert(PromptSnippet(id: 's1', name: '考研视角', text: '按考研数学的角度讲')));
      await t.pumpWidget(StudyApp(state: state, home: Scaffold(body: SnippetBar(picker: picker))));
      await settle(t, 2);
      expect(find.text('考研视角'), findsOneWidget);
      expect(find.text('管理'), findsOneWidget);
      await t.tap(find.text('考研视角'));
      await t.pump();
      expect(picker.selected, {'s1'});
      await t.tap(find.text('考研视角'));
      await t.pump();
      expect(picker.selected, isEmpty);

      final empty = SnippetPicker(state, 'p2');
      await t.pumpWidget(StudyApp(state: state, home: Scaffold(body: SnippetBar(picker: empty))));
      await settle(t, 2);
      expect(find.text('常用提示词'), findsOneWidget);
    });

    testWidgets('在面板里添加、编辑、删除提示词', (t) async {
      await phone(t);
      final picker = SnippetPicker(state, 'p1');
      await t.pumpWidget(StudyApp(state: state, home: Scaffold(body: SnippetBar(picker: picker))));
      await settle(t, 2);
      await t.tap(find.text('常用提示词'));
      await settle(t);
      expect(find.textContaining('只在「概率论 第3章」里用'), findsOneWidget);
      await t.tap(find.text('添加提示词'));
      await settle(t);
      await t.enterText(find.widgetWithText(TextField, '名称（可不填）'), '考研');
      await t.enterText(find.widgetWithText(TextField, '内容'), '按考研数学的角度讲');
      await t.tap(find.text('保存'));
      await settle(t);
      expect(picker.all.map((e) => (e.name, e.text)), [('考研', '按考研数学的角度讲')]);
      // 再加一条
      await t.tap(find.text('添加提示词'));
      await settle(t);
      await t.enterText(find.widgetWithText(TextField, '内容'), '多举例子');
      await t.tap(find.text('保存'));
      await settle(t);
      expect(picker.all.length, 2);
      // 编辑第一条
      await t.tap(find.text('考研').last);
      await settle(t);
      await t.enterText(find.widgetWithText(TextField, '内容'), '按考研数学一的角度讲');
      await t.tap(find.text('保存'));
      await settle(t);
      expect(picker.all.first.text, '按考研数学一的角度讲');
      // 删除第二条
      await t.tap(find.text('多举例子').last);
      await settle(t);
      await t.tap(find.text('删除'));
      await settle(t);
      expect(picker.all.map((e) => e.text), ['按考研数学一的角度讲']);
      // 空内容不保存
      await t.tap(find.text('添加提示词'));
      await settle(t);
      await t.tap(find.text('保存'));
      await settle(t, 2);
      expect(find.text('先写内容'), findsOneWidget);
      expect(picker.all.length, 1);
    });

    testWidgets('AI 解释追问：点了提示词就带上；没点和平时一样；仍可自己输入', (t) async {
      await phone(t);
      final card = Flashcard(id: 'cx', projectId: 'p1', docId: 'd1', front: '什么是条件概率？', back: 'P(A|B)', page: 12);
      final p = (await state.repo.project('p1'))!
        ..snippets = [PromptSnippet(id: 's1', name: '考研', text: '按考研数学的角度讲'), PromptSnippet(id: 's2', name: '例子', text: '多举例子')];
      await t.runAsync(() => state.repo.saveProject(p));
      await t.pumpWidget(StudyApp(state: state, home: Scaffold(body: Builder(builder: (ctx) => TextButton(onPressed: () => showExplainSheet(ctx, card: card), child: const Text('open'))))));
      await t.tap(find.text('open'));
      await settle(t);
      expect(find.text('考研'), findsOneWidget);
      expect(llm.chats.length, 1, reason: '首次解释和以前一样，自动生成');
      expect(llm.chats.first.last['content'], isNot(contains('按考研数学的角度讲')));

      // 没点提示词：只发自己输入的
      await t.enterText(find.byType(TextField).last, '再讲简单点');
      await t.tap(find.byIcon(Icons.send_rounded));
      await settle(t);
      var last = llm.chats.last.last['content']!;
      expect(last, startsWith('再讲简单点'));
      expect(last, isNot(contains('要求')));

      // 点了两条 + 自己输入
      await t.tap(find.text('考研'));
      await t.tap(find.text('例子'));
      await t.pump();
      await t.enterText(find.byType(TextField).last, '讲讲贝叶斯');
      await t.tap(find.byIcon(Icons.send_rounded));
      await settle(t);
      last = llm.chats.last.last['content']!;
      expect(last, contains('讲讲贝叶斯'));
      expect(last, contains('1. 按考研数学的角度讲'));
      expect(last, contains('2. 多举例子'));
      // 发完后选择清空，下一条恢复平常
      await t.enterText(find.byType(TextField).last, '谢谢');
      await t.tap(find.byIcon(Icons.send_rounded));
      await settle(t);
      expect(llm.chats.last.last['content'], isNot(contains('按考研数学的角度讲')));

      // 只点提示词、不输入：也能发
      final n = llm.chats.length;
      await t.tap(find.text('例子'));
      await t.pump();
      await t.tap(find.byIcon(Icons.send_rounded));
      await settle(t);
      expect(llm.chats.length, n + 1);
      expect(llm.chats.last.last['content'], contains('多举例子'));
    });

    testWidgets('AI 伴学：同样可以点提示词；对话标题只取自己的提问', (t) async {
      await phone(t);
      final p = (await state.repo.project('p1'))!..snippets = [PromptSnippet(id: 's1', name: '考研', text: '按考研数学的角度讲')];
      await t.runAsync(() => state.repo.saveProject(p));
      StudyChat? chat;
      await t.pumpWidget(StudyApp(
          state: state,
          home: Scaffold(
              body: StudyChatSheet(projectId: 'p1', chapters: const [], scope: const [], controller: ScrollController(), onChanged: (c, _) => chat = c))));
      await settle(t);
      await t.tap(find.text('考研'));
      await t.pump();
      await t.enterText(find.byType(TextField).last, '为什么要这样定义');
      await t.tap(find.byIcon(Icons.send_rounded));
      await settle(t);
      final sent = llm.chats.last.last;
      expect(sent['role'], 'user');
      expect(sent['content'], contains('为什么要这样定义'));
      expect(sent['content'], contains('按考研数学的角度讲'));
      expect(chat?.title, '为什么要这样定义');

      // 没点：原样
      await t.enterText(find.byType(TextField).last, '再问一个');
      await t.tap(find.byIcon(Icons.send_rounded));
      await settle(t);
      expect(llm.chats.last.last['content'], '再问一个');
    });
  });
}
