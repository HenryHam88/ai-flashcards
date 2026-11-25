import 'dart:async';
import 'dart:convert';

import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

LlmClient client(http.Client c, {String model = 'deepseek-flash'}) =>
    LlmClient(baseUrl: 'https://api.deepseek.com', apiKey: 'k', model: model, client: c);

const toolCalls = [
  {
    'index': 0,
    'calls': [
      {
        'index': 0,
        'id': 'srvtoolu_s_00',
        'type': 'deepseek_web_search',
        'kind': 'search',
        'action': {'type': 'search', 'queries': ['条件概率 定义']},
        'status': 'completed',
        'sources': [
          {'type': 'url', 'url': 'https://a.example/1', 'title': '条件概率 - 百科', 'site_name': '百科'},
          {'type': 'url', 'url': 'https://b.example/2', 'title': '讲义', 'site_name': 'B 大学'},
        ],
      }
    ]
  }
];

void main() {
  test('请求体：联网时声明 DeepSeek 联网工具，深度搜索开思考、普通联网关思考；联网时不用 json_object', () {
    final c = client(MockClient((_) async => http.Response('', 500)));
    final msgs = [
      {'role': 'user', 'content': '你好'},
      {'role': 'assistant', 'content': '你好！', 'tools': jsonEncode(toolCalls), 'reasoning': '想了想', 'sources': '[]'},
    ];
    final off = c.requestBody(msgs, json: true);
    expect(off.containsKey('tools'), isFalse);
    expect(off.containsKey('thinking'), isFalse, reason: '不联网时保持旧版行为');
    expect(off['response_format'], {'type': 'json_object'});
    final wire = (off['messages'] as List).last as Map;
    expect(wire.keys, unorderedEquals(['role', 'content']), reason: '不联网时不回传联网记录，也不带应用自己的字段');

    final deep = c.requestBody(msgs, web: WebMode.deep, json: true);
    expect(deep['thinking'], {'type': 'enabled'});
    expect(deep['tools'], [
      {'type': 'deepseek_web_search'},
      {'type': 'deepseek_read_url'},
    ]);
    expect(deep.containsKey('response_format'), isFalse, reason: '联网工具 + json_object 会返回 400');
    final last = (deep['messages'] as List).last as Map;
    expect(last['server_tool_calls'], toolCalls, reason: '多轮对话要原样回传联网记录');
    expect(last['reasoning_content'], '想了想');
    expect(last.containsKey('sources'), isFalse);

    final normal = c.requestBody(msgs, web: WebMode.normal);
    expect(normal['thinking'], {'type': 'disabled'});
  });

  test('只有 DeepSeek 接口 + deepseek-flash 能联网；设置默认开启、默认深度搜索，对话可单独关闭或切换', () async {
    expect(LlmClient.webUnavailableReason('https://api.deepseek.com', 'deepseek-flash'), isNull);
    expect(LlmClient.webUnavailableReason('https://api.deepseek.com/v1', 'deepseek-v4-flash'), isNull);
    expect(LlmClient.webUnavailableReason('https://api.deepseek.com', 'deepseek-v4-pro'), contains('deepseek-flash'));
    expect(LlmClient.webUnavailableReason('https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus'), contains('DeepSeek'));

    SharedPreferences.setMockInitialValues({});
    final st = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    expect(st.webSearch, isTrue);
    expect(st.webMode, WebMode.deep);
    expect(st.web(), WebMode.deep);
    expect(st.web(chatOn: false), WebMode.off);
    expect(st.web(chatMode: WebMode.normal), WebMode.normal);
    st.webMode = WebMode.normal;
    expect(st.web(), WebMode.normal);
    st.webSearch = false;
    expect(st.web(), WebMode.off);
    expect(st.web(chatOn: true, chatMode: WebMode.deep), WebMode.deep, reason: '对话可以单独打开');
    st.webSearch = true;
    st.llmModel = 'deepseek-v4-pro';
    expect(st.web(chatOn: true), WebMode.off, reason: '模型不支持时一律不联网');
  });

  test('非流式：解析正文、引用来源（先引用过的，再搜到的，去重）和联网记录', () async {
    late Map body;
    final c = client(MockClient((r) async {
      body = jsonDecode(r.body);
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'role': 'assistant',
                  'content': '条件概率是……',
                  'reasoning_content': '查一下',
                  'annotations': [
                    {'type': 'url_citation', 'url_citation': {'url': 'https://b.example/2', 'title': 'https://b.example/2', 'start_index': 0, 'end_index': 3}},
                  ],
                  'server_tool_calls': toolCalls,
                }
              }
            ]
          })),
          200);
    }));
    final r = await c.ask([
      {'role': 'user', 'content': '什么是条件概率'}
    ], web: WebMode.deep);
    expect(body['tools'], isNotEmpty);
    expect(r.content, '条件概率是……');
    expect(r.sources.map((e) => e.url), ['https://b.example/2', 'https://a.example/1']);
    expect(r.sources.first.cited, isTrue);
    expect(r.sources.first.title, '讲义', reason: 'title 是 URL 时用搜索结果里的标题');
    expect(r.serverToolCalls, toolCalls);
    final ex = r.extras();
    expect(WebSource.decode(ex['sources']).length, 2);
    expect(jsonDecode(ex['tools']!), toolCalls);
    expect(ex['reasoning'], '查一下');
  });

  String sse(List<Map<String, dynamic>> chunks) => '${chunks.map((c) => 'data: ${jsonEncode(c)}\n\n').join()}data: [DONE]\n\n';

  test('流式：逐段收到正文、显示搜索进度，最后一块带来引用', () async {
    final chunks = [
      {
        'choices': [
          {'delta': {'reasoning_content': '想'}}
        ]
      },
      {
        'choices': [
          {
            'delta': {},
            'server_tool_event': {
              'type': 'call_started',
              'step': 0,
              'call': {'action': {'type': 'search', 'queries': ['条件概率']}}
            }
          }
        ]
      },
      {
        'choices': [
          {'delta': {'content': '条件'}}
        ]
      },
      {
        'choices': [
          {'delta': {'content': '概率'}}
        ]
      },
      {
        'choices': [
          {
            'delta': {'server_tool_calls': toolCalls},
            'finish_reason': 'stop'
          }
        ]
      },
    ];
    // 故意从中间切开，检查跨块的行能拼回来
    final text = sse(chunks);
    final bytes = utf8.encode(text);
    final c = client(MockClient.streaming((req, body) async {
      expect(jsonDecode(await body.bytesToString())['stream'], isTrue);
      return http.StreamedResponse(Stream.fromIterable([bytes.sublist(0, 37), bytes.sublist(37, 200), bytes.sublist(200)]), 200);
    }));
    final deltas = <String>[];
    final status = <String>[];
    final r = await c.ask([
      {'role': 'user', 'content': 'q'}
    ], web: WebMode.deep, onDelta: deltas.add, onStatus: status.add);
    expect(deltas, ['条件', '条件概率']);
    expect(status, ['正在思考…', '正在搜索：条件概率']);
    expect(r.content, '条件概率');
    expect(r.reasoning, '想');
    expect(r.sources.length, 2);
  });

  test('停止：取消后立刻结束，抛 LlmCancelled，不再重试', () async {
    var calls = 0;
    final ctl = StreamController<List<int>>();
    final c = client(MockClient.streaming((req, _) async {
      calls++;
      return http.StreamedResponse(ctl.stream, 200);
    }));
    final cancel = AiCancel();
    final got = <String>[];
    final f = c.ask([
      {'role': 'user', 'content': 'q'}
    ], onDelta: (t) {
      got.add(t);
      cancel.cancel();
    }, cancel: cancel);
    ctl.add(utf8.encode('data: ${jsonEncode({'choices': [{'delta': {'content': '一半'}}]})}\n\n'));
    await expectLater(f, throwsA(isA<LlmCancelled>()));
    expect(got, ['一半']);
    expect(calls, 1);
    await ctl.close();
  });

  test('联网版 JSON：不带 json_object，靠提示词约束后本地解析', () async {
    late Map body;
    final c = client(MockClient((r) async {
      body = jsonDecode(r.body);
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'choices': [
              {'message': {'content': '```json\n{"score": 8, "comment": "好"}\n```'}}
            ]
          })),
          200);
    }));
    final j = await c.askJson('批改', web: WebMode.normal);
    expect(j['score'], 8);
    expect(body.containsKey('response_format'), isFalse);
    expect(body['thinking'], {'type': 'disabled'});
  });
}
