import 'dart:convert';
import 'dart:io';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const wordText = '# 第一章 随机事件与概率\n概率的公理化定义。\n'
    r'## 1.1 条件概率' '\n'
    r'$$P(A\mid B)=\frac{P(AB)}{P(B)}$$' '\n'
    '## 1.2 全概率公式\n'
    r'若 $B_1,\dots,B_n$ 构成完备事件组……' '\n'
    '# 第二章 随机变量\n' r'分布函数 $F(x)=P(X\le x)$。';

void main() {
  late Repository repo;
  late Settings settings;
  late PdfDoc doc;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    repo = Repository(MemoryDocStore());
    final f = File('${Directory.systemTemp.createTempSync('w').path}/讲义.docx')..writeAsBytesSync([0x50, 0x4B, 3, 4, 1, 2, 3]);
    doc = PdfDoc(id: 'w1', projectId: 'p1', name: '讲义', path: f.path, type: PdfDoc.typeOf('讲义.docx'));
    await repo.saveDoc(doc);
  });

  test('类型字段：旧数据默认 PDF，.docx 识别为 Word', () {
    expect(PdfDoc.fromJson({'id': 'a', 'projectId': 'p', 'name': 'n', 'path': ''}).type, 'pdf');
    expect(PdfDoc.typeOf('A.DOCX'), 'docx');
    expect(PdfDoc.typeOf('a.pdf'), 'pdf');
    expect(PdfDoc.typeOf('旧讲义.DOC'), 'doc');
    expect(PdfDoc(id: 'x', projectId: 'p', name: 'n', path: '', type: 'doc').isWord, isTrue);
    expect(Settings.supportsWord(OcrProvider.deepseek), isTrue);
    expect(Settings.supportsWord(OcrProvider.kimi), isTrue);
    expect(Settings.supportsWord(OcrProvider.local), isFalse);
  });

  test('DeepSeek OCR：整份 .docx 直接上传，按标题切小节并识别章节', () async {
    settings.ocrProvider = OcrProvider.deepseek;
    await settings.setOcrKey('sk-test');
    final calls = <http.Request>[];
    final client = MockClient((req) async {
      calls.add(req);
      return http.Response.bytes(
          utf8.encode('\n\n${jsonEncode({'page_count': 1, 'pages': [{'index': 0, 'text': wordText, 'finish_reason': 'stop'}]})}'), 200);
    });
    final failed = await ParseService(repo, settings, httpClient: client).parseDoc(doc, (_, _) {});
    expect(failed, 0);
    expect(calls, hasLength(1));
    expect(calls.single.url.path, '/v1/tools/ocr');
    final body = latin1.decode(calls.single.bodyBytes);
    expect(body, contains('.docx"'));
    expect(body, contains('content-type: application/vnd.openxmlformats-officedocument.wordprocessingml.document'));
    expect(body, contains('text_recognition'));
    expect(doc.status, '已解析');
    expect(doc.pageCount, 4); // 每个章/节标题开一个小节：第一章、1.1、1.2、第二章
    final chunks = await repo.chunks('p1');
    expect(chunks.map((c) => c.chapter).toSet(), {'第一章 随机事件与概率', '第二章 随机变量'});
    expect(chunks.map((c) => c.section), contains('1.1 条件概率'));
    final st = AppState(repo, settings);
    expect(st.sourceLabel('w1', 2, '第一章 随机事件与概率', '1.1 条件概率'), '第一章 随机事件与概率 · 1.1 条件概率');
    expect(st.sourceLabel('pdf1', 12, '第一章'), '第 12 页');
  });

  test('Kimi：.docx 上传为 file-extract 并取回内容', () async {
    settings.ocrProvider = OcrProvider.kimi;
    await settings.setKimiKey('sk-kimi');
    final paths = <String>[];
    var uploadBody = '';
    final client = MockClient((req) async {
      paths.add('${req.method} ${req.url.path}');
      if (req.method == 'POST') {
        uploadBody = latin1.decode(req.bodyBytes);
        return http.Response(jsonEncode({'id': 'file-1'}), 200);
      }
      if (req.url.path.endsWith('/content')) return http.Response.bytes(utf8.encode(jsonEncode({'content': wordText})), 200);
      return http.Response('{}', 200);
    });
    final failed = await ParseService(repo, settings, httpClient: client).parseDoc(doc, (_, _) {});
    expect(failed, 0);
    expect(uploadBody, contains('file-extract'));
    expect(uploadBody, contains('.docx"'));
    expect(paths.first, endsWith('/files'));
    expect(doc.status, '已解析');
    expect((await repo.pages('p1', docId: 'w1')).first.text, startsWith('# 第一章'));
  });

  test('本地提取不支持 Word：显示提示，不发任何网络请求，也不本地解析', () async {
    settings.ocrProvider = OcrProvider.local;
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    });
    String? msg;
    final failed = await ParseService(repo, settings, httpClient: client).parseDoc(doc, (m, _) => msg = m);
    expect(failed, 1);
    expect(calls, 0);
    expect(doc.status, '不支持');
    expect(doc.note, contains('当前解析模型不支持 Word'));
    expect(doc.note, contains('另存为 PDF'));
    expect(msg, doc.note);
    expect(await repo.pages('p1', docId: 'w1'), isEmpty);
    expect((await repo.docs('p1')).single.note, contains('不支持 Word'));
  });

  test('小节切分：超长无标题文字按段落切开', () {
    final long = List.generate(40, (i) => '${'段落内容' * 30}\n').join('\n');
    final parts = splitWordSections(long, maxChars: 1000);
    expect(parts.length, greaterThan(3));
    expect(parts.every((p) => p.length < 2000), isTrue);
  });

  group('旧版 .doc', () {
    late PdfDoc legacy;
    setUp(() async {
      final f = File('${Directory.systemTemp.createTempSync('d').path}/旧讲义.doc')..writeAsBytesSync([0xD0, 0xCF, 0x11, 0xE0]);
      legacy = PdfDoc(id: 'd1', projectId: 'p1', name: '旧讲义', path: f.path, type: PdfDoc.typeOf('旧讲义.doc'));
      await repo.saveDoc(legacy);
    });

    test('DeepSeek OCR：.doc 以 application/msword 上传', () async {
      settings.ocrProvider = OcrProvider.deepseek;
      await settings.setOcrKey('sk-test');
      var body = '';
      final client = MockClient((req) async {
        body = latin1.decode(req.bodyBytes);
        return http.Response.bytes(utf8.encode(jsonEncode({'page_count': 1, 'pages': [{'index': 0, 'text': wordText}]})), 200);
      });
      expect(await ParseService(repo, settings, httpClient: client).parseDoc(legacy, (_, _) {}), 0);
      expect(body, contains('.doc"'));
      expect(body, contains('content-type: application/msword'));
      expect(legacy.status, '已解析');
      expect(repo.isWordDoc('d1'), isTrue);
    });

    test('Kimi：.doc 以 application/msword 上传', () async {
      settings.ocrProvider = OcrProvider.kimi;
      await settings.setKimiKey('sk-kimi');
      var body = '';
      final client = MockClient((req) async {
        if (req.method == 'POST') {
          body = latin1.decode(req.bodyBytes);
          return http.Response(jsonEncode({'id': 'f'}), 200);
        }
        return http.Response.bytes(utf8.encode(jsonEncode({'content': wordText})), 200);
      });
      expect(await ParseService(repo, settings, httpClient: client).parseDoc(legacy, (_, _) {}), 0);
      expect(body, contains('file-extract'));
      expect(body, contains('content-type: application/msword'));
      expect(legacy.status, '已解析');
    });

    test('本地提取：.doc 同样提示不支持，不联网', () async {
      settings.ocrProvider = OcrProvider.local;
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('{}', 200);
      });
      expect(await ParseService(repo, settings, httpClient: client).parseDoc(legacy, (_, _) {}), 1);
      expect(calls, 0);
      expect(legacy.status, '不支持');
      expect(legacy.note, ParseService.wordUnsupported);
    });
  });
}
