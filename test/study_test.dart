import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/services/study.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';

class FakeLlm extends LlmClient {
  final Map<String, dynamic> json;
  final String answer;
  final prompts = <String>[];
  final chats = <List<Map<String, String>>>[];
  final webs = <WebMode>[];
  FakeLlm({this.json = const {}, this.answer = '## 条件概率\n就是在 \$B\$ 发生的前提下 \$A\$ 的概率。'}) : super(baseUrl: 'http://x', apiKey: 'k', model: 'm');
  @override
  Future<Map<String, dynamic>> chatJson(String prompt, {String? system, int retries = 3}) async {
    prompts.add(prompt);
    return json;
  }

  @override
  Future<Map<String, dynamic>> askJson(String prompt, {String? system, WebMode web = WebMode.off, int retries = 3}) async {
    webs.add(web);
    return chatJson(prompt, system: system);
  }

  @override
  Future<String> chat(List<Map<String, String>> messages, {bool json = false, double temperature = 0.7, int retries = 3}) async {
    chats.add(messages);
    return answer;
  }

  @override
  Future<LlmReply> ask(List<Map<String, String>> messages,
      {WebMode web = WebMode.off, bool json = false, double temperature = 0.7, int retries = 3, void Function(String text)? onDelta, LlmStatus? onStatus, AiCancel? cancel}) async {
    chats.add(messages);
    webs.add(web);
    onDelta?.call(answer);
    return LlmReply(answer, sources: web == WebMode.off ? const [] : const [WebSource(url: 'https://example.com/p', title: '条件概率 - 百科', cited: true)]);
  }
}

const mapJson = {
  'title': '随便写的标题',
  'children': [
    {
      'title': r'条件概率 $P(A\mid B)$',
      'note': r'$P(B)>0$ 时成立',
      'kp_index': 0,
      'children': [
        {'title': '乘法公式', 'page': 12, 'children': [
          {'title': '第三层', 'children': [
            {'title': '第四层', 'children': [
              {'title': '第五层（应被截掉）'}
            ]}
          ]}
        ]},
      ],
    },
    {'title': '', 'kp_index': 1},
    {'title': '   '},
  ],
};

void main() {
  late AppState s;
  late FakeLlm llm;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    llm = FakeLlm(json: mapJson);
    s = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()), llmFactory: (_, _) => llm);
    await seedSampleData(s.repo);
    await seedChapterPages(s.repo);
    await s.repo.saveKps([
      KnowledgePoint(id: 'kp1', projectId: 'p1', docId: 'd1', chapter: '第一章 随机事件与概率', title: '条件概率', content: 'P(A|B)', page: 12),
      KnowledgePoint(id: 'kp2', projectId: 'p1', docId: 'd1', chapter: '第一章 随机事件与概率', title: '概率的性质', page: 11),
    ]);
  });

  test('章节来自已解析资料和分章方案，统计知识点和字数', () async {
    final l = await s.study.chapters('p1');
    expect(l.map((c) => c.title), ['第一章 随机事件与概率'], reason: '没有文字的章节不显示');
    final c1 = l[0];
    expect(c1.kpCount, 2);
    expect(c1.chars, greaterThan(100));
    expect(c1.map, isNull);
  });

  test('选中资料：按章 / 按页码取原文，超出预算时截断', () async {
    final m = await s.study.material('p1', [MaterialRef(docId: 'd1', chapter: '第一章 随机事件与概率', pageFrom: 11, pageTo: 13)]);
    expect(m.text, contains('【《概率论与数理统计》第 11 页】'));
    expect(m.text, contains('条件概率'));
    expect(m.pages, 3);
    expect(m.truncated, isFalse);
    final only12 = await s.study.material('p1', [MaterialRef(docId: 'd1', pageFrom: 12, pageTo: 12)]);
    expect(only12.text, isNot(contains('第 11 页')));
    final small = await s.study.material('p1', [MaterialRef(docId: 'd1', pageFrom: 11, pageTo: 13)], limit: 150);
    expect(small.truncated, isTrue);
    expect(small.chars, m.chars);
    expect(StudyService.refLabel(MaterialRef(docId: 'd1', chapter: '第一章', pageFrom: 11, pageTo: 13), null), '第一章（第 11–13 页）');
  });

  test('生成导图：只在调用时请求一次，根节点是章节名，最多 4 层，kp_index 对应知识点，空标题用知识点标题', () async {
    final c = (await s.study.chapters('p1'))[0];
    final m = await s.generateMindMap(c);
    expect(llm.prompts.single, contains('第一章 随机事件与概率'));
    expect(llm.prompts.single, contains('0. 条件概率'));
    expect(m.root.text, '第一章 随机事件与概率');
    expect(m.root.children.length, 2);
    final n = m.root.children.first;
    expect(n.kpId, 'kp1');
    expect(n.page, 12, reason: '没有 page 时用知识点的页码');
    expect(m.root.children[1].text, '概率的性质');
    expect(m.root.depth, 4);
    final saved = await s.repo.mindMap('d1', '第一章 随机事件与概率');
    expect(saved!.root.count, m.root.count);
    expect((await s.study.chapters('p1'))[0].map, isNotNull);
    expect(llm.webs.single, WebMode.deep, reason: '导图跟随全局联网设置（默认深度搜索）');
  });

  test('没有文字的章节不能生成；AI 返回空树时报错', () async {
    final doc = (await s.repo.docs('p1')).first;
    expect(() => s.generateMindMap(StudyChapter(doc, ChapterRange('前置内容', 1, 10))), throwsA(isA<LlmException>()));
    llm = FakeLlm(json: {'title': 'x', 'children': []});
    final c = (await s.study.chapters('p1'))[0];
    expect(() => s.generateMindMap(c), throwsA(isA<LlmException>()));
  });

  test('AI 伴学：系统提示带上选中资料的原文，对话只保存可见内容，自动起标题', () async {
    final chat = StudyChat(id: 'c1', projectId: 'p1', scope: [MaterialRef(docId: 'd1', chapter: '第一章 随机事件与概率', pageFrom: 11, pageTo: 13)]);
    final r = await s.studyAsk(chat, '为什么条件概率要求 P(B)>0？');
    final sent = llm.chats.single;
    expect(sent.first['role'], 'system');
    expect(sent.first['content'], contains('称'));
    expect(sent.first['content'], contains('第一章 随机事件与概率（第 11–13 页）'));
    expect(sent.last['content'], '为什么条件概率要求 P(B)>0？');
    expect(r.messages.length, 2);
    expect(r.messages.every((m) => m['role'] != 'system'), isTrue);
    expect(r.title, '为什么条件概率要求 P(B)>0？');
    await s.studyAsk(r, '再举个例子');
    expect(llm.chats.last.length, 4, reason: 'system + 上一轮两条 + 新问题');
    expect((await s.repo.studyChats('p1')).single.messages.length, 4);
    // 默认联网：回答保存了参考网页；系统提示里写明以资料为准
    expect(llm.webs, [WebMode.deep, WebMode.deep]);
    expect(sent.first['content'], contains('必须以学生自己的教材'));
    expect(WebSource.decode(r.messages[1]['sources']).single.title, '条件概率 - 百科');
  });

  test('AI 伴学：对话可以单独切换普通联网或关闭联网，并随对话保存', () async {
    final chat = StudyChat(id: 'c2', projectId: 'p1', web: true, webMode: 'normal');
    await s.studyAsk(chat, '问题一');
    expect(llm.webs.last, WebMode.normal);
    chat.web = false;
    final r = await s.studyAsk(chat, '问题二');
    expect(llm.webs.last, WebMode.off);
    expect(llm.chats.last.first['content'], isNot(contains('联网搜索')));
    expect(r.messages[3]['sources'], isNull);
    final saved = (await s.repo.studyChats('p1')).firstWhere((c) => c.id == 'c2');
    expect((saved.web, saved.webMode), (false, 'normal'));
    // 全局关掉后，跟随全局的对话不联网
    s.settings.webSearch = false;
    await s.studyAsk(StudyChat(id: 'c3', projectId: 'p1'), '问题三');
    expect(llm.webs.last, WebMode.off);
  });

  test('主观题批改跟随全局联网设置', () async {
    await s.gradeSubjective(Question(id: 'q', projectId: 'p1', type: '简答', stem: '题', answer: '答'), '我的答案');
    expect(llm.webs.last, WebMode.deep);
    s.settings.webSearch = false;
    await s.gradeSubjective(Question(id: 'q', projectId: 'p1', type: '简答', stem: '题', answer: '答'), '我的答案');
    expect(llm.webs.last, WebMode.off);
  });

  test('导图节点 JSON 往返（含说明、页码、知识点）', () {
    final n = MindNode(text: 'a', note: 'b', page: 3, kpId: 'k', children: [MindNode(text: 'c')]);
    final r = MindNode.fromJson(n.toJson());
    expect((r.text, r.note, r.page, r.kpId, r.children.single.text), ('a', 'b', 3, 'k', 'c'));
    expect(MindNode.fromJson({'title': 'x', 'kp_id': 'y', 'page': '5'}).page, 5);
  });
}
