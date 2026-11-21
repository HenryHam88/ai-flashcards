import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/chapters.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/services/text_import.dart';
import 'package:charset/charset.dart' show gbk;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows 记事本「ANSI」（GBK）保存的中文，字节由 Python 的 str.encode('gbk') 生成。
const gbkText = '第一章 随机事件与概率\n1.1 样本空间：随机试验所有可能结果组成的集合。\n“概率”的公理化定义〇①';
final gbkBytes = Uint8List.fromList([
  0xb5, 0xda, 0xd2, 0xbb, 0xd5, 0xc2, 0x20, 0xcb, 0xe6, 0xbb, 0xfa, 0xca, 0xc2, 0xbc, 0xfe, 0xd3, 0xeb, 0xb8, 0xc5, 0xc2, //
  0xca, 0x0a, 0x31, 0x2e, 0x31, 0x20, 0xd1, 0xf9, 0xb1, 0xbe, 0xbf, 0xd5, 0xbc, 0xe4, 0xa3, 0xba, 0xcb, 0xe6, 0xbb, 0xfa,
  0xca, 0xd4, 0xd1, 0xe9, 0xcb, 0xf9, 0xd3, 0xd0, 0xbf, 0xc9, 0xc4, 0xdc, 0xbd, 0xe1, 0xb9, 0xfb, 0xd7, 0xe9, 0xb3, 0xc9,
  0xb5, 0xc4, 0xbc, 0xaf, 0xba, 0xcf, 0xa1, 0xa3, 0x0a, 0xa1, 0xb0, 0xb8, 0xc5, 0xc2, 0xca, 0xa1, 0xb1, 0xb5, 0xc4, 0xb9,
  0xab, 0xc0, 0xed, 0xbb, 0xaf, 0xb6, 0xa8, 0xd2, 0xe5, 0xa9, 0x96, 0xa2, 0xd9,
]);

Uint8List utf16(String s, {required bool little, bool bom = true}) {
  final out = <int>[if (bom) ...(little ? [0xFF, 0xFE] : [0xFE, 0xFF])];
  for (final u in s.codeUnits) {
    out.addAll(little ? [u & 0xFF, u >> 8] : [u >> 8, u & 0xFF]);
  }
  return Uint8List.fromList(out);
}

String para(int i, int n) => '第$i段：${'概率论研究随机现象的统计规律。' * (n ~/ 15)}';

void main() {
  group('编码识别', () {
    test('UTF-8 / UTF-8 BOM / UTF-16LE / UTF-16BE / 无 BOM UTF-16 / GBK', () {
      const s = '第一章 Python 入门\nprint("你好") 😀';
      var d = decodeTextBytes(Uint8List.fromList(utf8.encode(s)));
      expect((d.text, d.encoding), (s, 'UTF-8'));
      d = decodeTextBytes(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(s)]));
      expect((d.text, d.encoding), (s, 'UTF-8 BOM'));
      d = decodeTextBytes(utf16(s, little: true));
      expect((d.text, d.encoding), (s, 'UTF-16LE'));
      d = decodeTextBytes(utf16(s, little: false));
      expect((d.text, d.encoding), (s, 'UTF-16BE'));
      const en = 'Chapter 1 Introduction\nThe quick brown fox jumps over the lazy dog.';
      d = decodeTextBytes(utf16(en, little: true, bom: false));
      expect((d.text, d.encoding), (en, 'UTF-16LE'));
      d = decodeTextBytes(gbkBytes);
      expect((d.text, d.encoding), (gbkText, 'GBK'));
    });

    test('清理：统一换行，去掉 NUL / 控制字符 / BOM，保留 Tab', () {
      expect(cleanImportedText('\uFEFFa\r\nb\rc\u0000d\u0007e\tf  \n\n\n\n\ng'), 'a\nb\ncde\tf\n\n\ng');
    });

    test('空文件、只有空白的文件', () {
      expect(decodeTextBytes(Uint8List(0)).text, '');
      expect(splitTextPages(cleanImportedText('')), isEmpty);
      expect(splitTextPages(cleanImportedText(' \r\n\u0000\n ')), isEmpty);
    });
  });

  group('切成小节', () {
    test('在段落之间断开，每节约 1800–2400 字，内容不丢', () {
      final paras = [for (var i = 0; i < 40; i++) para(i, 300)];
      final text = paras.join('\n\n');
      final pages = splitTextPages(text);
      expect(pages.length, greaterThan(4));
      for (final p in pages.take(pages.length - 1)) {
        expect(p.length, inInclusiveRange(1700, 2400));
        expect(paras.any((x) => p.endsWith(x)), isTrue, reason: '应在段落末尾断开');
      }
      expect(pages.join('\n\n').replaceAll(RegExp(r'\s'), ''), text.replaceAll(RegExp(r'\s'), ''));
    });

    test('章标题总是从新的一节开始', () {
      final text = '第一章 随机事件\n${para(1, 300)}\n\n第二章 随机变量\n${para(2, 300)}\n\n# 第三章 数字特征\n${para(3, 300)}';
      final pages = splitTextPages(text);
      expect(pages.map((p) => p.split('\n').first), ['第一章 随机事件', '第二章 随机变量', '# 第三章 数字特征']);
    });

    test('没有换行的超长段落：按句子断开，每节不超过上限', () {
      final line = '这是一个很长的句子，用来测试超长行的切分。' * 2000; // 4 万字、只有一行
      final pages = splitTextPages(line);
      expect(pages.length, greaterThan(15));
      expect(pages.every((p) => p.length <= 2400), isTrue);
      expect(pages.take(pages.length - 1).every((p) => p.endsWith('。')), isTrue);
      expect(pages.join(), line);
      // 连标点都没有：硬切，也不超过上限，不拆开 emoji
      final raw = '😀字' * 5000;
      final ps = splitTextPages(raw);
      expect(ps.every((p) => p.length <= 2400), isTrue);
      expect(ps.join(), raw);
      for (final p in ps) {
        expect(() => utf8.encode(p), returnsNormally);
        expect(p.runes.contains(0xFFFD), isFalse);
      }
    });
  });

  test('资料类型与来源名称', () {
    expect(PdfDoc.typeOf('笔记.TXT'), 'txt');
    final d = PdfDoc(id: 'x', projectId: 'p', name: 'n', path: '', type: 'txt');
    expect((d.isText, d.isSectioned, d.isWord), (true, true, false));
    expect(PdfDoc.typeOf('a.pdf'), 'pdf');
    expect(PageText.sourceLabel('txt'), '本地（TXT）');
  });

  group('读取整份 TXT（不联网）', () {
    late Repository repo;
    late Settings settings;
    late Directory dir;
    var httpCalls = 0;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repo = Repository(MemoryDocStore());
      settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
      dir = await Directory.systemTemp.createTemp('txt_test');
      httpCalls = 0;
    });
    tearDown(() => dir.delete(recursive: true));

    Future<(PdfDoc, int)> parse(List<int> bytes) async {
      final f = File('${dir.path}/a.txt')..writeAsBytesSync(bytes);
      final doc = PdfDoc(id: 't1', projectId: 'p', name: '课堂笔记', path: f.path, type: 'txt');
      await repo.saveProject(Project(id: 'p', name: '概率论'));
      await repo.saveDoc(doc);
      final client = MockClient((_) async {
        httpCalls++;
        return http.Response('no', 500);
      });
      final svc = ParseService(repo, settings,
          httpClient: client, chapters: ChapterService(repo, settings, llm: () async => null));
      final failed = await svc.parseDoc(doc, (_, _) {});
      return (doc, failed);
    }

    test('GBK 教材：按标题识别章节，出处用「第 N 节」，来源为本地（TXT）', () async {
      final text = [
        '概率论与数理统计 课堂笔记',
        for (final (i, ch) in [(1, '第一章 随机事件与概率'), (2, '第二章 随机变量及其分布'), (3, '第三章 多维随机变量')]) ...[
          ch,
          '$i.1 基本概念',
          for (var k = 0; k < 8; k++) para(k, 300),
        ],
      ].join('\r\n\r\n');
      final (doc, failed) = await parse(gbk.encode(text));
      expect(failed, 0);
      expect(httpCalls, 0); // 不联网、不花钱
      expect(doc.status, '已解析');
      expect(doc.pageCount, greaterThan(6));
      final pages = await repo.pages('p', docId: 't1');
      expect(pages.length, doc.pageCount);
      expect(pages.every((p) => p.source == 'txt'), isTrue);
      expect(pages.any((p) => p.text.contains('\r')), isFalse);
      final plan = (await repo.chapterPlan('t1'))!;
      expect(plan.source, 'heading');
      expect(plan.chapters.map((c) => c.title).where((t) => t.startsWith('第')).toList(),
          ['第一章 随机事件与概率', '第二章 随机变量及其分布', '第三章 多维随机变量']);
      final chunks = await repo.chunks('p');
      expect(chunks.map((c) => c.chapter).toSet(), containsAll(['第一章 随机事件与概率', '第三章 多维随机变量']));
      expect(chunks.any((c) => c.section.contains('2.1 基本概念')), isTrue);

      final state = AppState(repo, settings);
      await repo.docs('p'); // 刷新资料类型缓存
      final c = chunks.firstWhere((c) => c.chapter.startsWith('第二章'));
      expect(state.sourceLabel('t1', c.pageStart, c.chapter), '第二章 随机变量及其分布 · 第 ${c.pageStart} 节');
    });

    test('空文件：标记为部分失败并说明原因', () async {
      final (doc, failed) = await parse([]);
      expect(failed, 1);
      expect((doc.status, doc.note), ('部分失败', '文件里没有文字'));
      expect(httpCalls, 0);
    });
  });
}
