
import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const t = Settings.ocrText, r = Settings.ocrRich;
final longText = '条件概率的定义与乘法公式，' * 10;

/// 假解析服务：记录并发数，可指定某些文件失败。
class FakeParse extends ParseService {
  final Set<String> failIds;
  int running = 0, maxRunning = 0;
  final List<String> order = [];
  FakeParse(super.repo, super.settings, this.failIds);
  @override
  Future<int> parseDoc(PdfDoc doc, Progress onProgress) async {
    running++;
    maxRunning = running > maxRunning ? running : maxRunning;
    order.add(doc.id);
    onProgress('解析中', 0.5);
    await Future.delayed(const Duration(milliseconds: 20));
    running--;
    if (failIds.contains(doc.id)) throw Exception('网络错误');
    return 0;
  }
}

void main() {
  test('逐页判断：文字少或有图注 → 版面模式，否则文字模式', () {
    expect(pageOcrPurpose(''), r);
    expect(pageOcrPurpose('图 1.2'), r);
    expect(pageOcrPurpose('$longText\n图 1.2 韦恩图\n$longText'), r);
    expect(pageOcrPurpose('$longText\nFigure 3 Venn diagram'), r);
    expect(pageOcrPurpose(longText), t);
    expect(pageOcrPurpose('$longText 如图所示'), t); // 正文提到「图」不算图注
  });

  test('批次计划：相邻同模式合并、不超过每批页数、每页只出现一次', () {
    final purposes = [t, t, t, r, r, t, t, t, t, t];
    final plan = planOcrBatches(purposes, 3);
    expect(plan.map((b) => '$b').toList(), ['1-3:$t', '4-5:$r', '6-8:$t', '9-10:$t']);
    final pages = [for (final b in plan) for (var p = b.from; p <= b.to; p++) p];
    expect(pages, List.generate(10, (i) => i + 1));
  });

  test('旧版单值设置迁移，且至少保留一种模式', () async {
    SharedPreferences.setMockInitialValues({'ocr_mode': r});
    final s = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    expect(s.ocrModes, [r]);
    expect(s.ocrMixed, isFalse);
    s.ocrModes = [r, t];
    expect(s.ocrModes, [t, r]);
    expect(s.ocrMixed, isTrue);
    expect(s.prefs.getString('ocr_mode'), isNull);
    s.ocrModes = [];
    expect(s.ocrModes, [t]);
  });

  test('多文件队列：按并发数同时解析 2–4 份，单个失败不影响其他，可单独重试', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository(MemoryDocStore());
    final settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    final state = AppState(repo, settings);
    final fake = FakeParse(repo, settings, {'d2'});
    state.parserFactory = () => fake;
    final docs = [for (var i = 1; i <= 5; i++) PdfDoc(id: 'd$i', projectId: 'p', name: '资料$i', path: '')];
    state.enqueueParse(docs);
    expect(state.jobs.value.length, 5);
    while (state.jobs.value.values.any((j) => j.active)) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(state.parseConcurrency, 4); // 默认并发数 4
    expect(fake.maxRunning, state.parseConcurrency);
    expect(fake.order, ['d1', 'd2', 'd3', 'd4', 'd5']);
    expect(state.jobs.value['d2']!.state, '失败');
    expect(state.jobs.value['d1']!.state, '完成');
    expect(state.jobs.value['d5']!.state, '完成');
    // 重试失败的那个
    fake.failIds.clear();
    state.enqueueParse([docs[1]]);
    while (state.jobs.value['d2']!.active) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(state.jobs.value['d2']!.state, '完成');
    settings.concurrency = 1;
    expect(state.parseConcurrency, 2); // 并发数 1 时仍同时排 2 份，但全局只发 1 个请求
    settings.concurrency = 2500;
    expect(state.parseConcurrency, 4);
  });
}
