// 新功能界面截图：flutter test test/screenshots_v7_test.dart --update-goldens
import 'dart:io';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/cloud_settings_page.dart';
import 'package:ai_flashcards/ui/favorites_page.dart';
import 'package:ai_flashcards/ui/wrong_book_page.dart';
import 'package:ai_flashcards/services/pdf_export.dart';
import 'package:ai_flashcards/ui/project_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sample_data.dart';
import 'screenshots_test.dart' show loadFonts;

void main() {
  late AppState state;
  late Directory dir;

  setUpAll(loadFonts);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Repository(MemoryDocStore()), Settings(await SharedPreferences.getInstance(), MemorySecretStore()));
    dir = Directory.systemTemp.createTempSync('afc_shots');
    state.appDirOverride = dir;
    await seedSampleData(state.repo);
  });

  Future<void> settle(WidgetTester t, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shoot(WidgetTester t, Widget home, String name, {Future<void> Function()? after}) async {
    t.view.physicalSize = const Size(1170, 2532);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(StudyApp(state: state, fontFamily: 'NotoSansSC', home: home));
    await settle(t);
    if (after != null) await after();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  }

  Future<void> configureCloud() async {
    final st = state.settings;
    st.cloudProvider = 'aliyun';
    st.cloudRegion = 'cn-hangzhou';
    st.cloudBucket = 'my-notes';
    await st.setCloudKeyId('LTAI5tExampleKeyId');
    await st.setCloudSecret('example-secret');
    // 一份已放到云端的资料 + 一份可以释放的资料
    final f = File('${dir.path}/pdfs/d1.pdf')..createSync(recursive: true);
    f.writeAsBytesSync(List.filled(3 * 1024 * 1024, 1));
    final docs = await state.repo.docs('p1');
    final d = docs.first
      ..path = f.path
      ..status = '已解析';
    await state.repo.saveDoc(d);
    await state.repo.saveMedia(MediaAsset(
        id: 'doc_x', projectId: 'p1', kind: 'doc', ownerId: 'x', localPath: '${dir.path}/pdfs/x.pdf', fileName: '线性代数.pdf',
        size: 18 * 1024 * 1024, cloudKey: 'ai-flashcards/doc/p1/doc_x.pdf', offloaded: true));
  }

  testWidgets('云端存储：已配置，显示空间与释放', (t) async {
    await t.runAsync(configureCloud);
    await shoot(t, const CloudSettingsPage(), '50_cloud_settings', after: () async {
      await t.scrollUntilVisible(find.text('释放空间'), 300, scrollable: find.byType(Scrollable).first);
      await settle(t, 3);
    });
  });

  testWidgets('云端存储：未配置', (t) async {
    await shoot(t, const CloudSettingsPage(), '51_cloud_empty');
  });

  testWidgets('释放空间面板', (t) async {
    await t.runAsync(configureCloud);
    await shoot(t, const ProjectPage(projectId: 'p1'), '52_release_sheet', after: () async {
      showReleaseSheet(t.element(find.byType(ProjectPage)), projectId: 'p1');
      await settle(t);
    });
  });

  Future<void> seedFavorites() async {
    final r = state.repo;
    await r.saveKps([
      KnowledgePoint(id: 'kp1', projectId: 'p1', docId: 'd1', chapter: '第一章 随机事件与概率', title: '条件概率',
          content: r'$P(A\mid B)=\dfrac{P(AB)}{P(B)}$，其中 $P(B)>0$', page: 12),
    ]);
    final c = (await r.card('c3'))!..kpId = 'kp1';
    await r.saveCards([c]);
    await r.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'kp', targetId: 'kp1', title: '条件概率'));
    await r.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'card', targetId: 'c3', title: c.front));
    await r.saveFavorite(FavoriteItem(projectId: 'p2', kind: 'question', targetId: 'q1', title: ''));
  }

  testWidgets('收藏页：知识点、闪卡、题目', (t) async {
    await t.runAsync(seedFavorites);
    await shoot(t, const FavoritesPage(), '53_favorites');
  });

  testWidgets('导出错题 PDF 面板；生成后登记为导出文件', (t) async {
    await t.runAsync(() async {
      await state.repo.saveQuestions([
        Question(id: 'q9', projectId: 'p2', chapter: '第二章 一阶微分方程', type: QType.judge, stem: r"方程 $y'=ky^2$ 是线性方程", answer: '错'),
      ]);
      await state.repo.saveWrong(WrongEntry(id: 'q1', projectId: 'p2', questionId: 'q1', lastAnswer: 'A'));
      await state.repo.saveWrong(WrongEntry(id: 'q9', projectId: 'p2', questionId: 'q9', mark: '不确定'));
    });
    state.pdfExporterOverride = () async => PdfExportService(File('assets/fonts/NotoSansSC-Regular-subset.ttf').readAsBytesSync());
    await shoot(t, const WrongBookPage(projectId: 'p2'), '54_wrong_export', after: () async {
      await t.tap(find.text('导出 PDF'));
      await settle(t, 8);
    });
    await t.tap(find.text('全部放在最后'));
    await t.pump();
    await t.tap(find.text('生成 PDF'));
    await settle(t, 20);
    expect(find.textContaining('PDF 已生成'), findsOneWidget);
    final media = await t.runAsync(() => state.repo.media());
    final m = media!.singleWhere((e) => e.kind == 'export');
    expect(m.fileName, startsWith('常微分方程-错题集-'));
    expect(File(m.localPath).readAsBytesSync().take(4), '%PDF'.codeUnits);
  });
}
