import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'concurrency.dart';
import 'json_utils.dart';

/// AI 联网方式。DeepSeek 服务端联网工具：搜索和读网页都在服务端完成，工具调用本身不计费，结果按 Token 计费。
/// - [normal] 联网搜索：关闭思考，模型按需搜索一次或几次后带引用作答（快、省）。
/// - [deep] 深度搜索：开启思考，模型边推理边搜索、打开网页、页内查找（最多约 20 次工具），更准但更慢、Token 更多。
/// 文档：https://api-docs.deepseek.com/zh-cn/guides/web_tools/
enum WebMode { off, normal, deep }

const webModeNames = {WebMode.normal: '联网搜索', WebMode.deep: '深度搜索'};

/// 回答引用的网页。
class WebSource {
  final String url;
  final String title;
  final String site;
  final bool cited; // 回答里直接引用过（annotations），否则只是搜到过
  const WebSource({required this.url, this.title = '', this.site = '', this.cited = false});
  String get label => title.isNotEmpty && title != url ? title : (Uri.tryParse(url)?.host ?? url);
  String get host => Uri.tryParse(url)?.host ?? '';
  Map<String, dynamic> toJson() => {'url': url, if (title.isNotEmpty) 'title': title, if (site.isNotEmpty) 'site': site, if (cited) 'cited': true};
  factory WebSource.fromJson(Map<String, dynamic> j) =>
      WebSource(url: '${j['url'] ?? ''}', title: '${j['title'] ?? ''}', site: '${j['site'] ?? ''}', cited: j['cited'] == true);

  static String encode(List<WebSource> l) => jsonEncode([for (final x in l) x.toJson()]);
  static List<WebSource> decode(String? s) {
    if (s == null || s.isEmpty) return const [];
    try {
      return [for (final x in jsonDecode(s) as List) WebSource.fromJson((x as Map).cast<String, dynamic>())];
    } catch (_) {
      return const [];
    }
  }
}

/// 一次回答：正文 + 引用来源 + 需要在多轮对话里原样回传的联网记录。
class LlmReply {
  final String content;
  final List<WebSource> sources;
  final List<dynamic> serverToolCalls;
  final String reasoning;
  final bool truncated; // finish_reason = length
  const LlmReply(this.content, {this.sources = const [], this.serverToolCalls = const [], this.reasoning = '', this.truncated = false});

  /// 存进对话记录（`Map<String, String>`）时附带的字段。
  Map<String, String> extras() => {
        if (sources.isNotEmpty) 'sources': WebSource.encode(sources),
        if (serverToolCalls.isNotEmpty) 'tools': jsonEncode(serverToolCalls),
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
      };
}

/// 用户点了「停止」。
class LlmCancelled implements Exception {
  @override
  String toString() => '已停止';
}

/// 取消令牌：传给 [LlmClient.ask]，调用 [cancel] 立即停止接收。
class AiCancel {
  bool _cancelled = false;
  final _c = Completer<void>();
  bool get cancelled => _cancelled;
  Future<void> get whenCancelled => _c.future;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _c.complete();
  }
}

/// 生成过程中的状态（显示在回答上方的小字）。
typedef LlmStatus = void Function(String status);

/// 界面传给 AppState 的流式回调和取消令牌。
class AiIo {
  final void Function(String text)? onDelta;
  final LlmStatus? onStatus;
  final AiCancel? cancel;
  const AiIo({this.onDelta, this.onStatus, this.cancel});
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);
  @override
  String toString() => message;
}

/// OpenAI 兼容的对话接口客户端（DeepSeek、通义千问、Kimi 等）。
class LlmClient {
  final String baseUrl;
  final String apiKey;
  final String model;
  final http.Client client;
  LlmClient({required this.baseUrl, required this.apiKey, required this.model, http.Client? client})
      : client = client ?? http.Client();

  Uri get _endpoint {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/chat/completions')) return Uri.parse(b);
    return Uri.parse('$b/chat/completions');
  }

  /// DeepSeek 联网工具只支持 deepseek-flash（https://api-docs.deepseek.com/zh-cn/guides/web_tools/）。
  /// 返回 null 表示可以联网，否则返回不能联网的原因。
  static String? webUnavailableReason(String baseUrl, String model) {
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    if (host != 'api.deepseek.com') return '联网搜索用的是 DeepSeek 的服务端联网工具，只在出题模型接口是 DeepSeek（api.deepseek.com）时可用';
    if (!webModels.contains(model.trim())) return 'DeepSeek 联网工具目前只支持 deepseek-flash 模型，当前模型是 ${model.trim().isEmpty ? '（未填写）' : model.trim()}';
    return null;
  }

  static const webModels = {'deepseek-flash', 'deepseek-v4-flash'};

  /// 模型的上下文长度（token）。DeepSeek 官方「模型与价格」页：deepseek-flash / deepseek-v4-pro 都是 1M。
  /// 不认识的模型按 128K 保守估计。
  static int contextTokens(String model) {
    final m = model.trim();
    if (m.startsWith('deepseek-flash') || m.startsWith('deepseek-v4')) return 1000000;
    return 128000;
  }

  /// 图片附件要模型能看图：DeepSeek 只有 deepseek-flash 支持图像理解（https://api-docs.deepseek.com/zh-cn/guides/vision）。
  static String? visionUnavailableReason(String baseUrl, String model) {
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    if (host == 'api.deepseek.com' && {...webModels, 'deepseek-v4-flash-vision-exp'}.contains(model.trim())) return null;
    return '发图片需要模型能看图：请把出题模型设为 DeepSeek 的 deepseek-flash（当前：${model.trim().isEmpty ? '未填写' : model.trim()}）。PDF、Word、TXT 不受影响。';
  }

  /// 发给接口的消息：去掉应用自己存的附加字段；联网时把上一轮的联网记录和思考原样回传。
  static List<Map<String, Object?>> wireMessages(List<Map<String, String>> messages, {bool web = false}) => [
        for (final m in messages)
          {
            'role': m['role'],
            // 带图片的消息：content 是块数组（文字 + image_url，图片用 base64 data URL）
            'content': (m['images'] ?? '').isEmpty
                ? m['content'] ?? ''
                : [
                    {'type': 'text', 'text': m['content'] ?? ''},
                    for (final u in (_tryJson(m['images']!) as List? ?? const []))
                      {
                        'type': 'image_url',
                        'image_url': {'url': '$u'}
                      },
                  ],
            if (web && m['role'] == 'assistant') ...{
              if ((m['tools'] ?? '').isNotEmpty) 'server_tool_calls': _tryJson(m['tools']!),
              'reasoning_content': m['reasoning'] ?? '',
            },
          }
      ];

  static Object? _tryJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> requestBody(List<Map<String, String>> messages,
      {WebMode web = WebMode.off, bool json = false, double temperature = 0.7, bool stream = false}) {
    final on = web != WebMode.off;
    return {
      'model': model,
      'messages': wireMessages(messages, web: on),
      'temperature': temperature,
      'stream': stream,
      if (on) ...{
        // 深度搜索 = 思考模式 + 联网；普通联网 = 关闭思考
        'thinking': {'type': web == WebMode.deep ? 'enabled' : 'disabled'},
        'tools': [
          {'type': 'deepseek_web_search'},
          {'type': 'deepseek_read_url'},
        ],
      },
      // 联网工具不能和 json_object 一起用（返回 400），联网时靠提示词约束 JSON
      if (json && !on) 'response_format': {'type': 'json_object'},
    };
  }

  /// 从回答里取出引用来源：先是正文直接引用的，再是搜到过的，按 URL 去重。
  static List<WebSource> parseSources(Map<String, dynamic>? message, {int max = 12}) {
    if (message == null) return const [];
    final out = <String, WebSource>{};
    final info = <String, (String, String)>{};
    final steps = message['server_tool_calls'];
    if (steps is List) {
      for (final st in steps) {
        final calls = st is Map ? st['calls'] : null;
        if (calls is! List) continue;
        for (final c in calls) {
          if (c is! Map) continue;
          final srcs = c['sources'];
          if (srcs is List) {
            for (final x in srcs) {
              if (x is Map && '${x['url'] ?? ''}'.isNotEmpty) info.putIfAbsent('${x['url']}', () => ('${x['title'] ?? ''}', '${x['site_name'] ?? ''}'));
            }
          }
          final pg = c['page'];
          if (pg is Map && '${pg['url'] ?? ''}'.isNotEmpty) info.putIfAbsent('${pg['url']}', () => ('${pg['title'] ?? ''}', ''));
        }
      }
    }
    final ann = message['annotations'];
    if (ann is List) {
      for (final a in ann) {
        final u = a is Map ? a['url_citation'] : null;
        if (u is! Map) continue;
        final url = '${u['url'] ?? ''}';
        if (url.isEmpty || out.containsKey(url)) continue;
        final i = info[url];
        final t = '${u['title'] ?? ''}';
        out[url] = WebSource(url: url, title: t.isNotEmpty && t != url ? t : (i?.$1 ?? ''), site: i?.$2 ?? '', cited: true);
      }
    }
    for (final e in info.entries) {
      if (out.length >= max) break;
      out.putIfAbsent(e.key, () => WebSource(url: e.key, title: e.value.$1, site: e.value.$2));
    }
    return out.values.where((x) => x.url.startsWith('http')).take(max).toList();
  }

  static String _statusOf(Map ev) {
    final call = ev['call'];
    final action = call is Map ? call['action'] : null;
    if (action is! Map) return '';
    switch ('${action['type']}') {
      case 'search':
        final q = action['queries'];
        final words = q is List ? q.take(2).join('、') : '';
        return words.isEmpty ? '正在搜索网页…' : '正在搜索：$words';
      case 'open_page':
      case 'read_link':
        final host = Uri.tryParse('${action['url'] ?? ''}')?.host ?? '';
        return host.isEmpty ? '正在阅读网页…' : '正在阅读 $host';
      case 'find_in_page':
        return '正在网页里查找…';
    }
    return '';
  }

  /// 通用调用：支持联网、流式输出（[onDelta] 收到累计正文）和取消。
  /// [web] 为 off 时与旧版 [chat] 行为一致。
  Future<LlmReply> ask(List<Map<String, String>> messages,
      {WebMode web = WebMode.off,
      bool json = false,
      double temperature = 0.7,
      int retries = 3,
      void Function(String text)? onDelta,
      LlmStatus? onStatus,
      AiCancel? cancel}) async {
    if (apiKey.isEmpty) throw LlmException('还没有填写出题模型的 API 密钥，请到「我的 → 出题模型」填写');
    final stream = onDelta != null;
    Object? lastErr;
    for (var attempt = 0; attempt < retries; attempt++) {
      if (cancel?.cancelled == true) throw LlmCancelled();
      var gotText = false;
      try {
        final body = jsonEncode(requestBody(messages, web: web, json: json, temperature: temperature, stream: stream));
        final headers = {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'};
        // 深度搜索可能检索十几次，给更长的等待时间
        final wait = Duration(seconds: web == WebMode.deep ? 420 : (web == WebMode.normal ? 240 : 180));
        if (!stream) {
          final fut = sendWithBackoff(() => client.post(_endpoint, headers: headers, body: body).timeout(wait), rateLimited: (r) => r.statusCode == 429);
          final r = await _orCancel(fut, cancel);
          _checkStatus(r.statusCode, () => utf8.decode(r.bodyBytes));
          if (r.statusCode == 429 || r.statusCode >= 500) {
            lastErr = LlmException('服务繁忙（${r.statusCode}）');
            await Future.delayed(Duration(seconds: 2 << attempt));
            continue;
          }
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          final ch = j['choices']?[0];
          final msg = (ch?['message'] as Map?)?.cast<String, dynamic>();
          final content = '${msg?['content'] ?? ''}';
          if (content.trim().isEmpty) {
            if (ch?['finish_reason'] == 'content_filter') throw LlmException('请求失败：内容审核未通过，换个问法试试');
            lastErr = LlmException('模型返回了空内容');
            continue;
          }
          return LlmReply(content,
              sources: parseSources(msg),
              serverToolCalls: (msg?['server_tool_calls'] as List?) ?? const [],
              reasoning: '${msg?['reasoning_content'] ?? ''}',
              truncated: ch?['finish_reason'] == 'length');
        }
        // 流式：SSE
        final req = http.Request('POST', _endpoint)
          ..headers.addAll(headers)
          ..body = body;
        final resp = await _orCancel(requestLimiter.run(() => client.send(req)).timeout(wait), cancel);
        if (resp.statusCode != 200) {
          final text = await resp.stream.bytesToString(utf8).timeout(const Duration(seconds: 30), onTimeout: () => '');
          _checkStatus(resp.statusCode, () => text);
          lastErr = LlmException('服务繁忙（${resp.statusCode}）');
          await Future.delayed(Duration(seconds: 2 << attempt));
          continue;
        }
        final buf = StringBuffer();
        final reasoning = StringBuffer();
        Map<String, dynamic>? finalDelta;
        String? finish;
        final done = Completer<void>();
        var pendingLine = '';
        late StreamSubscription<String> sub;
        void handle(String line) {
          line = line.trim();
          if (!line.startsWith('data:')) return;
          final data = line.substring(5).trim();
          if (data.isEmpty || data == '[DONE]') return;
          final j = jsonDecode(data);
          final ch = (j['choices'] as List?)?.firstOrNull;
          if (ch is! Map) return;
          final d = ch['delta'];
          if (d is Map) {
            final c = d['content'];
            if (c is String && c.isNotEmpty) {
              buf.write(c);
              gotText = true;
              onDelta(buf.toString());
            }
            final rc = d['reasoning_content'];
            if (rc is String && rc.isNotEmpty) {
              if (reasoning.isEmpty && buf.isEmpty) onStatus?.call('正在思考…');
              reasoning.write(rc);
            }
            if (d.containsKey('server_tool_calls') || d.containsKey('annotations')) finalDelta = d.cast<String, dynamic>();
          }
          final ev = ch['server_tool_event'];
          if (ev is Map && ev['type'] == 'call_started') {
            final st = _statusOf(ev);
            if (st.isNotEmpty) onStatus?.call(st);
          }
          if (ch['finish_reason'] != null) finish = '${ch['finish_reason']}';
        }

        sub = resp.stream.transform(utf8.decoder).timeout(wait).listen((chunk) {
          final all = pendingLine + chunk;
          final lines = all.split('\n');
          pendingLine = lines.removeLast();
          try {
            for (final l in lines) {
              handle(l);
            }
          } catch (e) {
            if (!done.isCompleted) done.completeError(e);
            sub.cancel();
          }
        }, onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        }, onDone: () {
          try {
            handle(pendingLine);
          } catch (_) {}
          if (!done.isCompleted) done.complete();
        }, cancelOnError: true);
        cancel?.whenCancelled.then((_) {
          sub.cancel();
          if (!done.isCompleted) done.completeError(LlmCancelled());
        });
        await done.future;
        final content = buf.toString();
        if (content.trim().isEmpty) {
          if (finish == 'content_filter') throw LlmException('请求失败：内容审核未通过，换个问法试试');
          lastErr = LlmException('模型返回了空内容');
          continue;
        }
        final fd = finalDelta;
        return LlmReply(content,
            sources: parseSources(fd),
            serverToolCalls: (fd?['server_tool_calls'] as List?) ?? const [],
            reasoning: reasoning.toString(),
            truncated: finish == 'length');
      } on LlmCancelled {
        rethrow;
      } on LlmException catch (e) {
        if (e.message.contains('401') || e.message.contains('402') || e.message.contains('请求失败')) rethrow;
        lastErr = e;
      } on TimeoutException {
        lastErr = LlmException('请求超时');
      } catch (e) {
        lastErr = e;
      }
      // 已经显示出一部分回答时不再重试（避免内容闪回）
      if (gotText) throw LlmException('回答中断了：$lastErr');
    }
    throw LlmException('多次重试仍失败：$lastErr');
  }

  void _checkStatus(int code, String Function() body) {
    if (code == 401) throw LlmException('API 密钥无效（401）');
    if (code == 402) throw LlmException('账户余额不足（402）');
    if (code == 200 || code == 429 || code >= 500) return;
    throw LlmException('请求失败（$code）：${body()}');
  }

  static Future<T> _orCancel<T>(Future<T> f, AiCancel? c) {
    if (c == null) return f;
    return Future.any([f, c.whenCancelled.then<T>((_) => throw LlmCancelled())]);
  }

  /// 联网版 JSON 调用：联网时不能用 json_object，改为提示词约束 + 本地解析。
  Future<Map<String, dynamic>> askJson(String prompt, {String? system, WebMode web = WebMode.off, int retries = 3}) async {
    if (web == WebMode.off) return chatJson(prompt, system: system, retries: retries);
    Object? lastErr;
    for (var i = 0; i < retries; i++) {
      final r = await ask([
        {'role': 'system', 'content': '${system ?? '你只输出合法的 json 对象，不要输出其他内容。'}\n可以联网查资料作补充，但最终只输出一个 json 对象，不要 Markdown 代码块以外的任何文字。'},
        {'role': 'user', 'content': prompt},
      ], web: web);
      try {
        return parseModelJson(r.content);
      } catch (e) {
        lastErr = e;
      }
    }
    throw LlmException('模型返回的 JSON 无法解析：$lastErr');
  }

  Future<String> chat(List<Map<String, String>> messages, {bool json = false, double temperature = 0.7, int retries = 3}) async {
    if (apiKey.isEmpty) throw LlmException('还没有填写出题模型的 API 密钥，请到「我的 → 出题模型」填写');
    Object? lastErr;
    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        final body = {
          'model': model,
          'messages': messages,
          'temperature': temperature,
          'stream': false,
          if (json) 'response_format': {'type': 'json_object'},
        };
        final r = await sendWithBackoff(
            () => client
                .post(_endpoint,
                    headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
                    body: jsonEncode(body))
                .timeout(const Duration(seconds: 180)),
            rateLimited: (r) => r.statusCode == 429);
        if (r.statusCode == 401) throw LlmException('API 密钥无效（401）');
        if (r.statusCode == 402) throw LlmException('账户余额不足（402）');
        if (r.statusCode == 429 || r.statusCode >= 500) {
          lastErr = LlmException('服务繁忙（${r.statusCode}）');
          await Future.delayed(Duration(seconds: 2 << attempt));
          continue;
        }
        if (r.statusCode != 200) throw LlmException('请求失败（${r.statusCode}）：${utf8.decode(r.bodyBytes)}');
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        final content = (j['choices']?[0]?['message']?['content'] ?? '').toString();
        if (content.trim().isEmpty) {
          lastErr = LlmException('模型返回了空内容');
          continue; // 空内容：重试
        }
        return content;
      } on LlmException catch (e) {
        if (e.message.contains('401') || e.message.contains('402') || e.message.contains('请求失败')) rethrow;
        lastErr = e;
      } on TimeoutException {
        lastErr = LlmException('请求超时');
      } catch (e) {
        lastErr = e;
      }
    }
    throw LlmException('多次重试仍失败：$lastErr');
  }

  /// 要求返回 JSON 对象；解析失败也会重试。
  Future<Map<String, dynamic>> chatJson(String prompt, {String? system, int retries = 3}) async {
    Object? lastErr;
    for (var i = 0; i < retries; i++) {
      final text = await chat([
        {'role': 'system', 'content': system ?? '你只输出合法的 json 对象，不要输出其他内容。'},
        {'role': 'user', 'content': prompt},
      ], json: true);
      try {
        return parseModelJson(text);
      } catch (e) {
        lastErr = e;
      }
    }
    throw LlmException('模型返回的 JSON 无法解析：$lastErr');
  }
}
