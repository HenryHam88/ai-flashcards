// 新功能界面截图：flutter test test/screenshots_v7_test.dart --update-goldens
import 'dart:io';

import 'package:ai_flashcards/app_state.dart';
import 'package:ai_flashcards/data/doc_store.dart';
import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/main.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/settings.dart';
import 'package:ai_flashcards/ui/cloud_settings_page.dart';
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
}
