import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/chapter_reparse.dart';
import 'package:ai_flashcards/services/llm.dart';
import 'package:ai_flashcards/services/pipeline.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/ui/chapter_reparse.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按提示词里出现的章节名决定返回什么：[script] 返回 null 表示抛错，返回空列表表示「这一章没有知识点」。
class ScriptedLlm extends LlmClient {
  final List<String>? Function(String prompt) script;
  final calls = <String>[];
  String failWith;
  ScriptedLlm(this.script, {this.failWith = '网络错误'}) : super(baseUrl: 'http://x', apiKey: 'k', model: 'm');
  @override
  Future<Map<String, dynamic>> chatJson(String prompt, {String? system, int retries = 3}) async {
    calls.add(prompt);
    final titles = script(prompt);
    if (titles == null) throw LlmException(failWith);
    return {
      'knowledge_points': [for (final t in titles) {'title': t, 'type': '定义', 'content': '$t 的内容'}]
    };
  }
}

void main() {
  late Repository repo;
  late Settings settings;
  final doc = PdfDoc(id: 'd', projectId: 'p', name: '高数', path: '', type: 'pdf', status: '已解析', pageCount: 4, parsedPages: 4);
  final chapters = [for (var i = 1; i <= 4; i++) ChapterRange('第$i章', i, i)];

  ChapterReparseService svc() => ChapterReparseService(repo, settings, retryDelay: Duration.zero);
  GenerationService gen(ScriptedLlm l) => GenerationService(repo, settings, l, qualityCheck: false);
  Future<List<Chunk>> chunks() async => await repo.chunks('p');
  Future<bool> hasKps(String chapter) async {
    final c = (await chunks()).firstWhere((c) => c.chapter == chapter);
    return (await repo.kps('p')).any((k) => k.id.startsWith('${c.id}_k'));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = Repository(MemoryDocStore());
    settings = Settings(await SharedPreferences.getInstance(), MemorySecretStore());
    await repo.saveDoc(doc);
    await repo.savePages([
      for (var p = 1; p <= 4; p++) PageText(docId: 'd', projectId: 'p', page: p, text: '第 $p 页正文：${'极限与连续。' * 6}', source: 'deepseek_text')
    ]);
    await repo.saveChapterPlan(ChapterPlan(docId: 'd', projectId: 'p', source: 'manual', chapters: chapters));
    await svc().rechunk(doc);
  });

  test('没分析过的项目：每一章都算没分析完', () async {
    final p = await svc().pendingKps('p');
    expect(p.map((e) => e.chapter.title), ['第1章', '第2章', '第3章', '第4章']);
    expect(p.every((e) => e.chunks.length == 1), isTrue);
  });

  test('只分析没分析的章节：分析好的章节不动、不再调用模型', () async {
    // 第 1、2 章已经分析好
    final first = ScriptedLlm((p) => p.contains('第1章') || p.contains('第2章') ? ['已有知识点'] : null);
    await svc().analyzePendingKps('p', gen(first), chapter: chapters[0]);
    await svc().analyzePendingKps('p', gen(first), chapter: chapters[1]);
    final kpsBefore = await repo.kps('p');
    expect(kpsBefore.length, 2);

    final llm = ScriptedLlm((p) => ['新的知识点']);
    final r = await svc().analyzePendingKps('p', gen(llm));
    expect(llm.calls.length, 2); // 只有第 3、4 章
    expect(llm.calls.every((c) => c.contains('第3章') || c.contains('第4章')), isTrue);
    expect(r.doneChapters, ['第3章', '第4章']);
    expect(r.allDone, isTrue);
    expect(r.summary, '已分析 2 章。');
    final after = await repo.kps('p');
    for (final k in kpsBefore) {
      expect(after.firstWhere((x) => x.id == k.id).title, '已有知识点'); // 原来的原样保留
    }
    expect(after.length, 4);
    expect(await svc().pendingKps('p'), isEmpty);
    // 都分析完以后再点：什么也不做
    final again = await svc().analyzePendingKps('p', gen(llm));
    expect(again.nothingToDo, isTrue);
    expect(llm.calls.length, 2);
  });

  test('一章失败不影响其它章；失败的章节下次接着分析', () async {
    final llm = ScriptedLlm((p) => p.contains('第2章') ? null : ['知识点']);
    final r = await svc().analyzePendingKps('p', gen(llm));
    expect(llm.calls.length, 4); // 失败的那段没有挡住后面的
    expect(r.doneChapters, ['第1章', '第3章', '第4章']);
    expect(r.failedChapters, ['第2章']);
    expect(r.error, '网络错误');
    expect(r.summary, contains('已分析 3 章'));
    expect(r.summary, contains('1 章没分析完'));
    expect(await hasKps('第1章'), isTrue);
    expect(await hasKps('第2章'), isFalse);
    expect((await svc().pendingKps('p')).map((e) => e.chapter.title), ['第2章']);

    // 网络恢复后再点：只处理第 2 章
    final ok = ScriptedLlm((p) => ['补上的知识点']);
    final r2 = await svc().analyzePendingKps('p', gen(ok));
    expect(ok.calls.length, 1);
    expect(r2.allDone, isTrue);
    expect(await hasKps('第2章'), isTrue);
  });

  test('密钥无效这类每段都会遇到的错误：提前停下，不再逐段重试', () async {
    settings.concurrency = 1;
    final llm = ScriptedLlm((p) => null, failWith: 'API 密钥无效（401）');
    final r = await svc().analyzePendingKps('p', gen(llm));
    expect(llm.calls.length, 1);
    expect(r.stoppedEarly, isTrue);
    expect(r.summary, contains('密钥无效'));
    expect(r.summary, contains('接着做'));
  });

  test('这一段确实没有知识点（目录、前言）：记下来，不再反复分析', () async {
    final llm = ScriptedLlm((p) => p.contains('第1章') ? <String>[] : ['知识点']);
    final r = await svc().analyzePendingKps('p', gen(llm));
    expect(r.allDone, isTrue);
    expect(r.chunksEmpty, 1);
    expect(await svc().pendingKps('p'), isEmpty);
    final again = await svc().analyzePendingKps('p', gen(llm));
    expect(again.nothingToDo, isTrue);
    expect(llm.calls.length, 4);
    // 出题时的提取也不会再为它花钱
    final chs = await chunks();
    await gen(llm).extractKps('p', chs, (_, _) {});
    expect(llm.calls.length, 4);
    // 覆盖度把它算作已分析
    expect(await svc().kpCoverage(doc, chapters[0]), (1, 1));
  });

  test('模型回的内容里没有知识点列表：算失败，不记成「没有知识点」', () async {
    final bad = _NoListLlm();
    final r = await svc().analyzePendingKps('p', GenerationService(repo, settings, bad, qualityCheck: false), chapter: chapters[0]);
    expect(r.failedChapters, ['第1章']);
    expect((await svc().pendingKps('p', chapter: chapters[0])).length, 1);
  });

  test('这一段的文字变了，「没有知识点」的记录自动失效', () async {
    final llm = ScriptedLlm((p) => <String>[]);
    await svc().analyzePendingKps('p', gen(llm), chapter: chapters[0]);
    expect(await svc().pendingKps('p', chapter: chapters[0]), isEmpty);
    final c = (await chunks()).first;
    c.text = '${c.text} 新增的内容';
    expect(settings.kpEmptyMarked(c), isFalse);
  });

  test('重新分析会清掉「没有知识点」的记录，让这一章重新分析', () async {
    final llm = ScriptedLlm((p) => <String>[]);
    await svc().analyzePendingKps('p', gen(llm), chapter: chapters[0]);
    await svc().clearChapterKps(doc, chapters[0]);
    expect((await svc().pendingKps('p', chapter: chapters[0])).length, 1);
  });


  group('界面', () {
    late AppState app;
    late ScriptedLlm llm;

    Future<void> settle(WidgetTester t, [int n = 10]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    setUp(() async {
      llm = ScriptedLlm((p) => p.contains('第2章') ? null : ['知识点']);
      app = AppState(repo, settings, llmFactory: (_, _) => llm);
      await settings.setLlmKey('sk-test');
    });

    testWidgets('项目里有没分析的章节时出现入口，点一下只分析它们；失败的留着，入口还在', (t) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(StudyApp(state: app, home: const Scaffold(body: KpPendingCard(projectId: 'p'))));
      await settle(t, 3);
      expect(find.text('还有 4 章没分析完'), findsOneWidget);
      await t.tap(find.text('分析未分析的章节'));
      await t.pumpAndSettle();
      expect(find.textContaining('只分析这些，已经分析好的不动；会产生少量费用'), findsOneWidget);
      await t.tap(find.text('开始分析'));
      await settle(t, 15);
      expect(llm.calls.length, 4);
      expect(find.textContaining('已分析 3 章'), findsOneWidget); // 提示条
      expect(find.text('还有 1 章没分析完'), findsOneWidget);
      // 网络恢复，再点：只分析剩下的 1 章
      llm = ScriptedLlm((p) => ['补上']);
      await t.tap(find.text('分析未分析的章节'));
      await t.pumpAndSettle();
      await t.tap(find.text('开始分析'));
      await settle(t, 15);
      expect(llm.calls.length, 1);
      expect(find.textContaining('还有'), findsNothing, reason: '都分析完了，入口消失');
    });

    testWidgets('都分析过的项目不显示入口', (t) async {
      await svc().analyzePendingKps('p', gen(ScriptedLlm((p) => ['x'])));
      await t.pumpWidget(StudyApp(state: app, home: const Scaffold(body: KpPendingCard(projectId: 'p'))));
      await settle(t, 3);
      expect(find.textContaining('没分析完'), findsNothing);
    });

    testWidgets('本章知识点面板：部分段落没分析时，有「分析没分析的 N 段」，不动已有的', (t) async {
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      // 把全文当成一章：一段已分析，其余没有
      llm = ScriptedLlm((p) => ['补上的知识点']);
      await t.runAsync(() async {
        await svc().analyzePendingKps('p', gen(ScriptedLlm((p) => ['已有'])), chapter: chapters[0]);
      });
      final whole = ChapterRange('全文', 1, 4);
      final before = await t.runAsync(() => repo.kps('p'));
      await t.pumpWidget(StudyApp(state: app, home: Scaffold(body: ChapterKpSheet(doc: doc, range: whole, scroll: ScrollController()))));
      await settle(t, 4);
      expect(find.text('分析没分析的 3 段'), findsOneWidget);
      await t.tap(find.text('分析没分析的 3 段'));
      await settle(t, 12);
      expect(llm.calls.length, 3);
      expect(llm.calls.any((c) => c.contains('第1章')), isFalse, reason: '已经分析好的第 1 章不会再发给模型');
      final after = await t.runAsync(() => repo.kps('p'));
      expect(after!.length, before!.length + 3);
      expect(after.firstWhere((k) => k.id == before.first.id).title, '已有');
      expect(find.textContaining('分析没分析的'), findsNothing);
    });
  });

  test('没有分章方案时整份资料算一章「全文」', () async {
    await repo.store.delete('chapters', 'd');
    await svc().rechunk(doc);
    final p = await svc().pendingKps('p');
    expect(p.length, 1);
    expect(p.single.chapter.title, '全文');
    expect(p.single.chapter.start, 1);
    expect(p.single.chapter.end, 4);
  });
}

class _NoListLlm extends LlmClient {
  _NoListLlm() : super(baseUrl: 'http://x', apiKey: 'k', model: 'm');
  @override
  Future<Map<String, dynamic>> chatJson(String prompt, {String? system, int retries = 3}) async => {'ok': true};
}
