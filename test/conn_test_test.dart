import 'dart:async';
import 'dart:convert';

import 'package:ai_flashcards/services/conn_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

http.Response json(int code, Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), code, headers: {'content-type': 'application/json'});

const okBody = {
  'choices': [
    {'message': {'role': 'assistant', 'content': '好'}}
  ]
};

Future<TestResult> llm(MockClient c, {String key = 'sk-test', String model = 'deepseek-flash', String base = 'https://api.deepseek.com', bool keyOptional = false}) =>
    ConnTest.llm(baseUrl: base, apiKey: key, model: model, keyOptional: keyOptional, client: c);

void main() {
  group('对话模型测试', () {
    test('成功：发的是很短的请求，带密钥和模型名', () async {
      late http.Request seen;
      final r = await llm(MockClient((req) async {
        seen = req;
        return json(200, okBody);
      }));
      expect(r.ok, isTrue);
      expect(r.message, contains('可以用'));
      expect(seen.url.toString(), 'https://api.deepseek.com/chat/completions');
      expect(seen.headers['Authorization'], 'Bearer sk-test');
      final b = jsonDecode(seen.body) as Map;
      expect(b['model'], 'deepseek-flash');
      expect(b['max_tokens'], lessThanOrEqualTo(32));
      expect(b['stream'], false);
      expect((b['messages'] as List).length, 1);
    });

    test('接口地址已经写到 /chat/completions 或带斜杠都能用', () async {
      final urls = <String>[];
      final c = MockClient((req) async {
        urls.add(req.url.toString());
        return json(200, okBody);
      });
      await llm(c, base: 'https://x.com/v1/');
      await llm(c, base: 'https://x.com/v1/chat/completions');
      expect(urls, ['https://x.com/v1/chat/completions', 'https://x.com/v1/chat/completions']);
    });

    test('密钥不对（401）', () async {
      final r = await llm(MockClient((_) async => json(401, {'error': {'message': 'Authentication Fails'}})));
      expect(r.ok, isFalse);
      expect(r.message, contains('密钥不对'));
      expect(r.message, contains('401'));
    });

    test('余额不足（402）', () async {
      final r = await llm(MockClient((_) async => json(402, {'error': {'message': 'Insufficient Balance'}})));
      expect(r.message, contains('余额不足'));
    });

    test('模型不存在：DeepSeek 返回 400、OpenAI 返回 404 都认得出来', () async {
      final a = await llm(MockClient((_) async => json(400, {'error': {'message': 'Model Not Exist'}})), model: 'nope');
      expect(a.message, contains('找不到这个模型'));
      final b = await llm(MockClient((_) async => json(404, {'error': {'message': 'The model `gpt-9` does not exist', 'code': 'model_not_found'}})));
      expect(b.message, contains('找不到这个模型'));
    });

    test('地址不对：404 但和模型无关', () async {
      final r = await llm(MockClient((_) async => http.Response('<html>Not Found</html>', 404)));
      expect(r.message, contains('接口地址不对'));
      expect(r.message, isNot(contains('找不到这个模型')));
    });

    test('地址返回的是网页：不是模型接口', () async {
      final r = await llm(MockClient((_) async => http.Response('<html>hello</html>', 200)));
      expect(r.ok, isFalse);
      expect(r.message, contains('不是模型接口'));
    });

    test('200 但带 error 字段', () async {
      final r = await llm(MockClient((_) async => json(200, {'error': {'message': 'quota exceeded'}})));
      expect(r.ok, isFalse);
      expect(r.message, contains('quota exceeded'));
    });

    test('429、500、403', () async {
      expect((await llm(MockClient((_) async => json(429, {'error': 'slow down'})))).message, contains('429'));
      expect((await llm(MockClient((_) async => http.Response('oops', 503)))).message, contains('暂时出了问题'));
      expect((await llm(MockClient((_) async => json(403, {'error': {'message': 'forbidden'}})))).message, contains('没有权限'));
    });

    test('超时、连不上', () async {
      final t = await llm(MockClient((_) async => throw TimeoutException('x')));
      expect(t.message, contains('超时'));
      final n = await llm(MockClient((_) async => throw http.ClientException('Failed host lookup: api.x.com')));
      expect(n.message, contains('连不上服务器'));
    });

    test('填写不完整时不发请求', () async {
      var sent = 0;
      final c = MockClient((_) async {
        sent++;
        return json(200, okBody);
      });
      expect((await llm(c, key: '')).message, contains('密钥'));
      expect((await llm(c, model: ' ')).message, contains('模型'));
      expect((await llm(c, base: '')).message, contains('接口地址'));
      expect((await llm(c, base: 'api.deepseek.com')).message, contains('格式'));
      expect(sent, 0);
    });

    test('本地服务（Ollama）可以不填密钥，不发 Authorization', () async {
      late http.Request seen;
      final r = await llm(MockClient((req) async {
        seen = req;
        return json(200, okBody);
      }), key: '', keyOptional: true, base: 'http://127.0.0.1:11434/v1');
      expect(r.ok, isTrue);
      expect(seen.headers.containsKey('Authorization'), isFalse);
    });

    test('只认 max_completion_tokens 的模型：自动换个参数再试一次', () async {
      var n = 0;
      final r = await llm(MockClient((req) async {
        n++;
        final b = jsonDecode(req.body) as Map;
        if (b.containsKey('max_tokens')) {
          return json(400, {'error': {'message': "Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead."}});
        }
        return json(200, okBody);
      }));
      expect(r.ok, isTrue);
      expect(n, 2);
    });

    test('错误说明里不会带出完整密钥', () async {
      final r = await llm(MockClient((_) async => json(401, {'error': {'message': 'Incorrect API key provided: sk-test'}})), key: 'sk-test-full-secret-key');
      expect(r.message.contains('sk-test-full-secret-key'), isFalse);
    });
  });

  group('OCR / 文件解析测试', () {
    test('测试用的小 PDF 是合法的一页文件，带一行文字', () {
      final bytes = ConnTest.tinyPdf();
      final d = PdfDocument(inputBytes: bytes);
      expect(d.pages.count, 1);
      expect(PdfTextExtractor(d).extractText(), contains('Test'));
      d.dispose();
    });

    test('DeepSeek OCR：传 PDF 和用途，成功', () async {
      late http.BaseRequest seen;
      final r = await ConnTest.deepseekOcr(
        baseUrl: 'https://api.deepseek.com/v1/',
        apiKey: 'sk-ocr',
        purpose: 'rich_layout_recognition',
        client: MockClient.streaming((req, body) async {
          seen = req;
          return http.StreamedResponse(Stream.value(utf8.encode('\n{"page_count":1,"pages":[]}')), 200);
        }),
      );
      expect(r.ok, isTrue);
      expect(seen.url.toString(), 'https://api.deepseek.com/v1/tools/ocr');
      expect(seen.headers['Authorization'], 'Bearer sk-ocr');
      expect(seen, isA<http.MultipartRequest>());
      final m = seen as http.MultipartRequest;
      expect(m.fields['purpose'], 'rich_layout_recognition');
      expect(m.files.single.filename, 'test.pdf');
    });

    Future<TestResult> ocr(int code, [String body = '']) => ConnTest.deepseekOcr(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'k',
        client: MockClient.streaming((req, b) async => http.StreamedResponse(Stream.value(utf8.encode(body)), code)));

    test('DeepSeek OCR：密钥不对、地址不对、余额不足、服务出错', () async {
      expect((await ocr(401, '{"error":"bad key"}')).message, contains('密钥不对'));
      expect((await ocr(404)).message, contains('不支持 OCR'));
      expect((await ocr(402)).message, contains('余额不足'));
      expect((await ocr(500)).message, contains('暂时出了问题'));
      expect((await ocr(400, '{"error":{"message":"purpose invalid"}}')).message, contains('purpose invalid'));
    });

    test('DeepSeek OCR：没填密钥不发请求；超时有提示', () async {
      var sent = 0;
      final c = MockClient.streaming((req, b) async {
        sent++;
        throw TimeoutException('x');
      });
      expect((await ConnTest.deepseekOcr(baseUrl: 'https://api.deepseek.com', apiKey: '', client: c)).message, contains('密钥'));
      expect(sent, 0);
      expect((await ConnTest.deepseekOcr(baseUrl: 'https://api.deepseek.com', apiKey: 'k', client: c)).message, contains('超时'));
    });

    test('Kimi：上传小文件成功后删除，不占文件配额', () async {
      final deleted = Completer<String>();
      late http.MultipartRequest up;
      final c = MockClient.streaming((req, b) async {
        if (req.method == 'DELETE') {
          deleted.complete(req.url.toString());
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
        }
        up = req as http.MultipartRequest;
        return http.StreamedResponse(Stream.value(utf8.encode('{"id":"file-1"}')), 200);
      });
      final r = await ConnTest.kimiFile(baseUrl: 'https://api.moonshot.cn/v1', apiKey: 'sk-k', client: c);
      expect(r.ok, isTrue);
      expect(up.url.toString(), 'https://api.moonshot.cn/v1/files');
      expect(up.fields['purpose'], 'file-extract');
      expect(up.headers['Authorization'], 'Bearer sk-k');
      expect(await deleted.future.timeout(const Duration(seconds: 2)), 'https://api.moonshot.cn/v1/files/file-1');
    });

    test('Kimi：密钥不对、地址不对、没填密钥', () async {
      Future<TestResult> kimi(int code, {String key = 'k'}) => ConnTest.kimiFile(
          baseUrl: 'https://api.moonshot.cn/v1',
          apiKey: key,
          client: MockClient.streaming((req, b) async => http.StreamedResponse(Stream.value(utf8.encode('{"error":{"message":"Invalid Authentication"}}')), code)));
      expect((await kimi(401)).message, contains('密钥不对'));
      expect((await kimi(404)).message, contains('接口地址不对'));
      expect((await kimi(200, key: '')).message, contains('密钥'));
    });
  });
}
