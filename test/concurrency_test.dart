import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/concurrency.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/ocr.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

/// 假模型：出题时严格按提示里要求的数量给出，并记录每次请求的 (闪卡数, 题目数, 第一个知识点)。
class FakeGenLlm extends LlmClient {
  final calls = <(int, int, String)>[];
  int running = 0, maxRunning = 0;
  /// 每个闪卡正面都一样（用来测跨批次去重）。
  final bool sameFront;
  FakeGenLlm({this.sameFront = false}) : super(baseUrl: '', apiKey: 'k', model: 'm');

  @override
  Future<Map<String, dynamic>> chatJson(String prompt, {String? system, int retries = 3}) async {
    final m = RegExp(r'GEN\|(\d+)\|(\d+)\|\[0\][^\n]*?(KP\d+)').firstMatch(prompt);
    if (m == null) return {};
    final nc = int.parse(m.group(1)!), nq = int.parse(m.group(2)!), kp = m.group(3)!;
    running++;
    if (running > maxRunning) maxRunning = running;
    calls.add((nc, nq, kp));
    await Future.delayed(Duration(milliseconds: 5 + (kp.hashCode % 7)));
    running--;
    final n = calls.length;
    return {
      'flashcards': [
        for (var i = 0; i < nc; i++)
          {'kp_index': 0, 'front': sameFront ? '什么是样本空间' : '$kp 第$n次 卡$i 问题', 'back': '答案$i'}
      ],
      'questions': [
        for (var i = 0; i < nq; i++)
          {'kp_index': 0, 'type': '判断', 'stem': '$kp 第$n次 题$i 是否成立', 'answer': '对'}
      ],
    };
  }
}

/// 假 OCR：按文件名里的页码范围返回「第 n 页」，完成顺序故意打乱；可让某一批第一次失败。
class FakeOcr implements PdfParser {
  final calls = <String>[];
  final failOnce = <int>{};
  int running = 0, maxRunning = 0;
  @override
  Future<OcrResult> parse(Uint8List pdfBytes, String fileName, int pageCount) async {
    final m = RegExp(r'_p(\d+)-(\d+)\.pdf$').firstMatch(fileName)!;
    final from = int.parse(m.group(1)!);
    calls.add('$from');
    running++;
    if (running > maxRunning) maxRunning = running;
    await Future.delayed(Duration(milliseconds: 40 - from % 37));
    running--;
    if (failOnce.remove(from)) throw OcrException('网络错误');
    return OcrResult(pageCount, [for (var i = 0; i < pageCount; i++) OcrPage(i, '第 ${from + i} 页')]);
  }
}

Future<(Repository, Settings)> setup({int concurrency = 1}) async {
  SharedPreferences.setMockInitialValues({});
  final repo = Repository(MemoryDocStore());
  final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
  settings.setPrompt('gen', 'GEN|{{card_count}}|{{question_count}}|{{kps}}');
  settings.concurrency = concurrency;
  await repo.replaceChunks('p', 'd', [
    Chunk(id: 'c1', projectId: 'p', docId: 'd', chapter: '第一章', section: '1.1', pageStart: 1, pageEnd: 1, text: '样本空间 答案'),
  ]);
  return (repo, settings);
}

List<KnowledgePoint> kpsOf(int n) => [
      for (var i = 0; i < n; i++)
        KnowledgePoint(id: 'k$i', projectId: 'p', chapter: '第一章', section: '1.1', title: 'KP$i', content: '内容', page: 1)
    ];

Future<(FakeGenLlm, GenerationResult)> runGen(int concurrency, GenOptions o, int nKps,
    {bool quality = false, bool sameFront = false}) async {
  final (repo, settings) = await setup(concurrency: concurrency);
  final llm = FakeGenLlm(sameFront: sameFront);
  final g = GenerationService(repo, settings, llm, qualityCheck: quality);
  final r = await g.generate('p', o, (_, _) {}, planned: kpsOf(nKps));
  return (llm, r);
}

void main() {
  tearDown(() => requestLimiter.max = defaultConcurrency);

  group('Limiter', () {
    test('同时持有数不超过上限，先来先得', () async {
      final l = Limiter(3);
      final order = <int>[];
      await Future.wait([
        for (var i = 0; i < 20; i++)
          l.run(() async {
            order.add(i);
            await Future.delayed(const Duration(milliseconds: 2));
          })
      ]);
      expect(l.peak, 3);
      expect(order, List.generate(20, (i) => i));
      expect((l.active, l.waiting), (0, 0));
    });

    test('上限限制在 1–2500，调大后立即放行排队的', () async {
      expect(Limiter(0).max, 1);
      expect(Limiter(99999).max, 2500);
      final l = Limiter(1);
      final c = Completer<void>();
      final f1 = l.run(() => c.future);
      var second = false;
      final f2 = l.run(() async => second = true);
      await Future.delayed(Duration.zero);
      expect(second, isFalse);
      l.max = 2;
      await f2;
      expect(second, isTrue);
      c.complete();
      await f1;
    });
  });

  group('runPool', () {
    test('结果按序号排列，与完成顺序无关；同时运行数不超过并发数', () async {
      var running = 0, peak = 0;
      final dones = <int>[];
      final r = await runPool<int>(30, 5, (i) async {
        running++;
        if (running > peak) peak = running;
        await Future.delayed(Duration(milliseconds: (30 - i) % 7));
        running--;
        return i * i;
      }, onDone: (d, total) => dones.add(d));
      expect(r, [for (var i = 0; i < 30; i++) i * i]);
      expect(peak, 5);
      expect(dones, List.generate(30, (i) => i + 1));
    });

    test('并发数 1 时按顺序逐个执行', () async {
      final log = <String>[];
      await runPool<void>(4, 1, (i) async {
        log.add('start$i');
        await Future.delayed(const Duration(milliseconds: 1));
        log.add('end$i');
      });
      expect(log, ['start0', 'end0', 'start1', 'end1', 'start2', 'end2', 'start3', 'end3']);
    });

    test('出错后不再开始新任务，抛出第一个错误', () async {
      final started = <int>[];
      await expectLater(
          runPool<void>(10, 2, (i) async {
            started.add(i);
            await Future.delayed(const Duration(milliseconds: 2));
            if (i == 1) throw StateError('坏了');
          }),
          throwsA(isA<StateError>()));
      expect(started.length, lessThan(10));
      expect(await runPool<int>(0, 4, (i) async => i), isEmpty);
    });
  });

  group('429 退避重试', () {
    setUp(() => RateLimitBackoff.delay = (_) => Duration.zero);
    tearDown(() => RateLimitBackoff.delay = RateLimitBackoff.defaultDelay);

    test('遇到 429 自动重试，成功后返回结果', () async {
      var n = 0;
      final client = MockClient((req) async {
        n++;
        if (n <= 3) return http.Response('rate limited', 429);
        return http.Response.bytes(
            utf8.encode(jsonEncode({
              'choices': [
                {
                  'message': {'content': '好'}
                }
              ]
            })),
            200);
      });
      final llm = LlmClient(baseUrl: 'https://x', apiKey: 'k', model: 'm', client: client);
      expect(await llm.chat([
        {'role': 'user', 'content': 'hi'}
      ]), '好');
      expect(n, 4);
    });

    test('一直 429：退避重试用完后交给原有重试，最终报错', () async {
      var n = 0;
      final client = MockClient((req) async {
        n++;
        return http.Response('rate limited', 429);
      });
      final llm = LlmClient(baseUrl: 'https://x', apiKey: 'k', model: 'm', client: client);
      // 原有重试的等待（2、4 秒）在测试里用较短的 retries 控制
      await expectLater(
          llm.chat([
            {'role': 'user', 'content': 'hi'}
          ], retries: 1),
          throwsA(isA<LlmException>()));
      expect(n, RateLimitBackoff.maxRetries + 1);
    });

    test('退避时间指数增长，带抖动，最长 30 秒', () {
      for (var a = 0; a < 8; a++) {
        final base = (1000 * (1 << a)).clamp(0, 30000);
        final d = RateLimitBackoff.defaultDelay(a).inMilliseconds;
        expect(d, inInclusiveRange(base, base * 1.5));
      }
    });

    test('每次请求都在全局限流里，退避等待时不占名额', () async {
      final l = Limiter(2);
      var inFlight = 0, peak = 0;
      Future<int> Function() sender() {
        var n = 0;
        return () async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future.delayed(const Duration(milliseconds: 2));
          inFlight--;
          return ++n < 3 ? 429 : 200; // 前两次 429，第三次成功
        };
      }

      final r = await Future.wait([
        for (var i = 0; i < 6; i++) sendWithBackoff<int>(sender(), rateLimited: (s) => s == 429, limiter: l)
      ]);
      expect(r, everyElement(200));
      expect(peak, lessThanOrEqualTo(2));
      expect(l.peak, 2);
    });
  });

  group('出题分批', () {
    test('allocateBatches 与顺序循环的分配一致：固定数量', () {
      expect(allocateBatches([8, 8, 8], 20, 10), [(7, 4), (7, 3), (6, 3)]);
      expect(allocateBatches([8, 8, 8, 8], 2, 0), [(1, 0), (1, 0), (0, 0), (0, 0)]);
      expect(allocateBatches([8], 1500, 1500), [(1500, 1500)]);
    });

    test('allocateBatches：自动数量按知识点个数分配，最后一批补齐', () {
      final a = allocateBatches([8, 8, 4], 20, 40, auto: true);
      expect(a, [(8, 16), (8, 16), (4, 8)]);
      final b = allocateBatches([8, 8, 8], 1, 0, auto: true);
      expect(b.fold<int>(0, (s, e) => s + e.$1), 1);
    });

    for (final auto in [false, true]) {
      test('并发出题与顺序出题的每批数量完全一致（${auto ? '自动' : '固定'}数量）', () async {
        final o = GenOptions(cardCount: 37, questionCount: 23, types: [QType.judge], autoCount: auto);
        final (seq, r1) = await runGen(1, o, 43);
        final (par, r2) = await runGen(8, o, 43);
        Set<(int, int, String)> s(FakeGenLlm l) => l.calls.toSet();
        expect(s(par), s(seq));
        expect(seq.maxRunning, 1);
        expect(par.maxRunning, greaterThan(1));
        expect((r1.cards, r1.questions), (37, 23));
        expect((r2.cards, r2.questions), (37, 23));
        final sizes = [8, 8, 8, 8, 8, 3];
        final alloc = allocateBatches(sizes, 37, 23, auto: auto);
        expect([for (final c in seq.calls) (c.$1, c.$2)], [for (final a in alloc) if (a.$1 > 0 || a.$2 > 0) a]);
      });
    }

    test('并发出题：保存顺序按批次，不受完成顺序影响', () async {
      final o = GenOptions(cardCount: 24, questionCount: 0, types: [QType.judge]);
      final (repo, settings) = await setup(concurrency: 6);
      final g = GenerationService(repo, settings, FakeGenLlm(), qualityCheck: false);
      final r = await g.generate('p', o, (_, _) {}, planned: kpsOf(24));
      final cards = await repo.cards(projectId: 'p');
      expect(cards.length, 24);
      final kpOrder = [for (final id in r.cardIds) cards.firstWhere((c) => c.id == id).kpId];
      expect(kpOrder, [for (final k in ['k0', 'k8', 'k16']) ...List.filled(8, k)]);
    });

    test('并发出题：跨批次再去重一次', () async {
      final o = GenOptions(cardCount: 6, questionCount: 0, types: [QType.judge]);
      final (_, r) = await runGen(4, o, 24, quality: true, sameFront: true);
      expect(r.cards, 1); // 各批的闪卡正面相同，只留一张
      expect(r.quality.deduped, greaterThanOrEqualTo(5));
    });
  });

  group('PDF 分批解析', () {
    Future<(Repository, FakeOcr, int, List<String>)> parse(int concurrency, {Set<int> cachedPages = const {}, Set<int> failOnce = const {}}) async {
      final (repo, settings) = await setup(concurrency: concurrency);
      settings.ocrProvider = OcrProvider.deepseek;
      settings.ocrModes = [Settings.ocrText];
      settings.ocrBatchPages = 5;
      final pdf = sf.PdfDocument();
      for (var i = 0; i < 40; i++) {
        pdf.pages.add();
      }
      final dir = await Directory.systemTemp.createTemp('pool');
      final f = File('${dir.path}/a.pdf')..writeAsBytesSync(await pdf.save());
      pdf.dispose();
      final doc = PdfDoc(id: 'd', projectId: 'p', name: '资料', path: f.path);
      await repo.savePages([
        for (final pg in cachedPages) PageText(docId: 'd', projectId: 'p', page: pg, text: '缓存 $pg', source: 'local')
      ]);
      final ocr = FakeOcr()..failOnce.addAll(failOnce);
      final msgs = <String>[];
      final failed = await ParseService(repo, settings, parserOverride: ocr).parseDoc(doc, (m, _) => msgs.add(m));
      return (repo, ocr, failed, msgs);
    }

    test('并发解析：每页按页码保存，结果与顺序解析相同；进度显示已完成/总批数', () async {
      final (r1, o1, f1, _) = await parse(1);
      final (r4, o4, f4, msgs) = await parse(4, failOnce: {11});
      expect((f1, f4), (0, 0));
      expect(o1.maxRunning, 1);
      expect(o4.maxRunning, 4);
      expect(o1.calls, ['1', '6', '11', '16', '21', '26', '31', '36']);
      Future<List<(int, String)>> pages(Repository r) async =>
          [for (final p in (await r.pages('p', docId: 'd'))..sort((a, b) => a.page.compareTo(b.page))) (p.page, p.text)];
      expect(await pages(r4), await pages(r1));
      expect((await pages(r4)).length, 40);
      expect(msgs, contains('已完成 8/8 批'));
      expect(msgs.any((m) => m.contains('第 11–15 页失败，重试中')), isTrue);
    });

    test('并发解析：已解析的页跳过（断点续传不变）', () async {
      final (repo, ocr, failed, _) = await parse(8, cachedPages: {for (var p = 1; p <= 10; p++) p});
      expect(failed, 0);
      expect(ocr.calls.toSet(), {'11', '16', '21', '26', '31', '36'});
      final ps = await repo.pages('p', docId: 'd');
      expect(ps.firstWhere((p) => p.page == 3).text, '缓存 3');
      expect(ps.length, 40);
    });
  });
}
