import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'json_utils.dart';

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
        final r = await client
            .post(_endpoint,
                headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
                body: jsonEncode(body))
            .timeout(const Duration(seconds: 180));
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
