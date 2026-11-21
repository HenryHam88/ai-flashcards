import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_flashcards/services/ocr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('OCR 标记清理', () {
    test('删除 ref/box 定位标记，保留正文', () {
      const raw = '<｜ref｜>title<｜/ref｜><｜box｜>[[12, 30, 400, 60]]<｜/box｜>\n第一章 随机事件\n'
          '<｜ref｜>text<｜/ref｜><｜box｜>[[10,70,500,200]]<｜/box｜>\n设 \$P(B)>0\$。';
      final c = OcrText.clean(raw);
      expect(c, '第一章 随机事件\n\n设 \$P(B)>0\$。');
      expect(c.contains('｜'), isFalse);
      expect(c.contains('[['), isFalse);
    });

    test('插图留占位，半角竖线和 det 变体也能清理', () {
      const raw = '<|ref|>image<|/ref|><|det|>[[1,2,3,4]]<|/det|>\n图 1.1 韦恩图';
      expect(OcrText.clean(raw), '[插图]\n图 1.1 韦恩图');
    });

    test('零散标记与坐标被删除', () {
      expect(OcrText.clean('A<｜/ref｜>B [[1, 2, 3, 4]] C'), 'AB  C');
    });

    test('解析带前导换行的响应 JSON', () {
      const body = '\n\n\n{"page_count":2,"pages":[{"index":1,"text":"第二页","finish_reason":"stop"},'
          '{"index":0,"text":"<｜ref｜>text<｜/ref｜><｜box｜>[[0,0,1,1]]<｜/box｜>第一页","finish_reason":"stop"}]}';
      final r = OcrText.parseDeepSeek(body);
      expect(r.pageCount, 2);
      expect(r.pages.map((p) => p.text).toList(), ['第一页', '第二页']);
    });
  });

  test('DeepSeek OCR 请求：multipart 恰好两个字段 purpose 和 file（模拟接口）', () async {
    late http.BaseRequest captured;
    late String bodyText;
    final mock = MockClient.streaming((req, stream) async {
      captured = req;
      bodyText = latin1.decode(await stream.toBytes());
      return http.StreamedResponse(
          Stream.value(utf8.encode('\n{"page_count":1,"pages":[{"index":0,"text":"\$x^2\$","finish_reason":"stop"}]}')), 200);
    });
    final ocr = DeepSeekOcr(baseUrl: 'https://api.deepseek.com', apiKey: 'sk-test', purpose: 'text_recognition', client: mock);
    final r = await ocr.parse(Uint8List.fromList([37, 80, 68, 70]), 'a.pdf', 1);
    expect(captured.url.toString(), 'https://api.deepseek.com/v1/tools/ocr');
    expect(captured.headers['Authorization'], 'Bearer sk-test');
    expect(RegExp(r'content-disposition: form-data; name="', caseSensitive: false).allMatches(bodyText).length, 2);
    expect(bodyText.contains('name="purpose"'), isTrue);
    expect(bodyText.contains('name="file"; filename="a.pdf"'), isTrue);
    expect(r.pages.single.text, '\$x^2\$');
  });
}
