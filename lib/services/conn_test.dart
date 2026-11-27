import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 「测试」按钮的结果：成功，或一句能看懂的原因。
class TestResult {
  final bool ok;
  final String message;
  const TestResult(this.ok, this.message);
  const TestResult.ok(this.message) : ok = true;
  const TestResult.fail(this.message) : ok = false;
}

/// 给模型和文档解析服务发一个很小的请求，看能不能用。不保存任何东西。
class ConnTest {
  static const llmTimeout = Duration(seconds: 25);
  static const ocrTimeout = Duration(seconds: 45);

  static String? _checkUrl(String baseUrl) {
    final u = Uri.tryParse(baseUrl.trim());
    if (baseUrl.trim().isEmpty) return '还没有填写接口地址';
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
      return '接口地址格式不对，应该以 https:// 开头';
    }
    return null;
  }

  static String _trimSlash(String s) {
    var b = s.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  /// 服务端返回的错误说明（取一小段，方便对照）。
  static String detail(String body) {
    var s = body.trim();
    try {
      final j = jsonDecode(s);
      final e = j is Map ? j['error'] : null;
      if (e is Map && e['message'] != null) {
        s = '${e['message']}';
      } else if (e is String) {
        s = e;
      } else if (j is Map && j['message'] != null) {
        s = '${j['message']}';
      }
    } catch (_) {}
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 100 ? '${s.substring(0, 100)}…' : s;
  }

  static final _modelMissing = RegExp(
      r'model.{0,40}(not exist|not found|does not exist|not supported|invalid|unknown|no such|unavailable)|(not exist|not found|unknown|invalid|no such).{0,20}model|model_not_found|模型.{0,10}(不存在|无效|不可用|未开通)',
      caseSensitive: false);

  /// 把一次失败的 HTTP 回应翻译成原因。[model] 为 true 表示请求里带了模型名。
  static TestResult explain(int code, String body, {bool model = true}) {
    final hint = detail(body);
    final more = hint.isEmpty ? '' : '（$hint）';
    if (code == 401) return TestResult.fail('密钥不对，或者已经失效（401）$more');
    if (code == 402) return TestResult.fail('账户余额不足（402）');
    if (code == 403) {
      if (model && _modelMissing.hasMatch(body)) return const TestResult.fail('这个密钥没有用这个模型的权限（403）');
      return TestResult.fail('密钥没有权限（403），检查密钥是否属于这个服务商$more');
    }
    if (code == 404 || code == 400 || code == 422) {
      if (model && _modelMissing.hasMatch(body)) return TestResult.fail('找不到这个模型，检查模型名有没有写对（$code）');
      if (code == 404) return const TestResult.fail('接口地址不对（404）。一般要写到 /v1 这一级，比如 https://api.xxx.com/v1');
      return TestResult.fail('服务商拒绝了请求（$code）$more');
    }
    if (code == 429) return TestResult.fail('请求太频繁，或额度用完了（429），稍后再试$more');
    if (code >= 500) return TestResult.fail('服务商那边暂时出了问题（$code），稍后再试');
    return TestResult.fail('请求失败（$code）$more');
  }

  /// 网络层的错误。
  static TestResult network(Object e) {
    if (e is TimeoutException) return const TestResult.fail('等了很久没有回应（超时），检查接口地址和网络');
    final t = '$e';
    if (t.contains('HandshakeException') || t.contains('CERTIFICATE') || t.contains('TlsException')) {
      return const TestResult.fail('安全连接失败，检查地址是 https 还是 http');
    }
    if (t.contains('SocketException') || t.contains('Failed host lookup') || t.contains('Connection refused') || t.contains('ClientException')) {
      return const TestResult.fail('连不上服务器，检查接口地址和网络');
    }
    if (e is FormatException || e is ArgumentError) return const TestResult.fail('接口地址格式不对');
    return TestResult.fail('测试失败：$t');
  }

  /// 对话模型：发一句「你好」，只要很短的回答。
  static Future<TestResult> llm({
    required String baseUrl,
    required String apiKey,
    required String model,
    bool keyOptional = false,
    http.Client? client,
  }) async {
    final bad = _checkUrl(baseUrl);
    if (bad != null) return TestResult.fail(bad);
    if (model.trim().isEmpty) return const TestResult.fail('还没有填写模型名称');
    if (apiKey.trim().isEmpty && !keyOptional) return const TestResult.fail('还没有填写 API 密钥');
    var b = _trimSlash(baseUrl);
    final url = Uri.parse(b.endsWith('/chat/completions') ? b : '$b/chat/completions');
    final c = client ?? http.Client();
    final started = DateTime.now();
    try {
      Future<http.Response> send(String limitKey) => c
          .post(url,
              headers: {
                if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'model': model.trim(),
                'messages': [
                  {'role': 'user', 'content': '你好，回复一个字就行。'}
                ],
                limitKey: 16,
                'stream': false,
              }))
          .timeout(llmTimeout);
      var r = await send('max_tokens');
      // 个别新模型只认 max_completion_tokens
      if (r.statusCode == 400 && utf8.decode(r.bodyBytes, allowMalformed: true).contains('max_completion_tokens')) {
        r = await send('max_completion_tokens');
      }
      final body = utf8.decode(r.bodyBytes, allowMalformed: true);
      if (r.statusCode != 200) return explain(r.statusCode, body);
      Object? j;
      try {
        j = jsonDecode(body);
      } catch (_) {}
      if (j is Map && j['error'] != null) {
        final err = TestResult.fail('服务商返回了错误：${detail(body)}');
        return _modelMissing.hasMatch(body) ? const TestResult.fail('找不到这个模型，检查模型名有没有写对') : err;
      }
      if (j is! Map || j['choices'] is! List) {
        return const TestResult.fail('这个地址返回的不是模型接口的内容，检查地址是否写到 /v1 这一级');
      }
      final secs = (DateTime.now().difference(started).inMilliseconds / 100).round() / 10;
      return TestResult.ok('可以用，用时 $secs 秒');
    } catch (e) {
      return network(e);
    } finally {
      if (client == null) c.close();
    }
  }

  /// 一页很小的 PDF，用来试 OCR（内容是一行字）。
  static Uint8List tinyPdf() {
    const stream = 'BT /F1 18 Tf 20 100 Td (Test 1+1=2) Tj ET';
    final objs = <String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 160] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
      '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ];
    final out = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[];
    for (var i = 0; i < objs.length; i++) {
      offsets.add(out.length);
      out.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
    }
    final xref = out.length;
    out.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
    for (final o in offsets) {
      out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
    }
    out.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
    return Uint8List.fromList(utf8.encode(out.toString()));
  }

  /// DeepSeek OCR：传一页很小的 PDF。
  static Future<TestResult> deepseekOcr({
    required String baseUrl,
    required String apiKey,
    String purpose = 'text_recognition',
    http.Client? client,
  }) async {
    final bad = _checkUrl(baseUrl);
    if (bad != null) return TestResult.fail(bad);
    if (apiKey.trim().isEmpty) return const TestResult.fail('还没有填写密钥（OCR 密钥留空时用出题模型的密钥，那边也没填）');
    var b = _trimSlash(baseUrl);
    if (b.endsWith('/v1')) b = b.substring(0, b.length - 3);
    final c = client ?? http.Client();
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$b/v1/tools/ocr'))
        ..headers['Authorization'] = 'Bearer ${apiKey.trim()}'
        ..fields['purpose'] = purpose
        ..files.add(http.MultipartFile.fromBytes('file', tinyPdf(), filename: 'test.pdf'));
      final streamed = await c.send(req).timeout(ocrTimeout);
      final r = await http.Response.fromStream(streamed).timeout(ocrTimeout);
      final body = utf8.decode(r.bodyBytes, allowMalformed: true);
      if (r.statusCode == 200) return const TestResult.ok('可以用，OCR 服务正常');
      if (r.statusCode == 404) return const TestResult.fail('接口地址不对，或者这个地址不支持 OCR（404）。DeepSeek 官方地址是 https://api.deepseek.com');
      return explain(r.statusCode, body, model: false);
    } catch (e) {
      return network(e);
    } finally {
      if (client == null) c.close();
    }
  }

  /// Kimi 文件解析：传一个很小的文本文件，成功后马上删掉。
  static Future<TestResult> kimiFile({required String baseUrl, required String apiKey, http.Client? client}) async {
    final bad = _checkUrl(baseUrl);
    if (bad != null) return TestResult.fail(bad);
    if (apiKey.trim().isEmpty) return const TestResult.fail('还没有填写 Kimi 密钥');
    final b = _trimSlash(baseUrl);
    final c = client ?? http.Client();
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$b/files'))
        ..headers['Authorization'] = 'Bearer ${apiKey.trim()}'
        ..fields['purpose'] = 'file-extract'
        ..files.add(http.MultipartFile.fromBytes('file', utf8.encode('测试 1+1=2'), filename: 'test.txt'));
      final streamed = await c.send(req).timeout(ocrTimeout);
      final r = await http.Response.fromStream(streamed).timeout(ocrTimeout);
      final body = utf8.decode(r.bodyBytes, allowMalformed: true);
      if (r.statusCode == 404) return const TestResult.fail('接口地址不对（404）。Kimi 官方地址是 https://api.moonshot.cn/v1');
      if (r.statusCode != 200) return explain(r.statusCode, body, model: false);
      // 用完即删，不占 Kimi 的文件配额
      try {
        final id = jsonDecode(body)['id'];
        if (id != null) {
          unawaited(c.delete(Uri.parse('$b/files/$id'), headers: {'Authorization': 'Bearer ${apiKey.trim()}'}).then((_) {}, onError: (_) {}));
        }
      } catch (_) {}
      return const TestResult.ok('可以用，文件解析服务正常');
    } catch (e) {
      return network(e);
    } finally {
      // 删除请求还在路上时不能马上关闭 client；传入的 client 由调用方管理，这里只关自己建的
      if (client == null) {
        Future.delayed(const Duration(seconds: 5), c.close);
      }
    }
  }
}
