import '../models.dart';
import 'doc_store.dart';

/// 业务层仓库接口。UI 只依赖它，不关心底层是 SQLite、内存还是将来的网盘同步。
class Repository {
  final DocStore store;
  Repository(this.store);

  // ---------- 项目 ----------
  Future<List<Project>> projects() async =>
      (await store.list('projects')).map(Project.fromJson).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  Future<Project?> project(String id) async {
    final j = await store.get('projects', id);
    return j == null ? null : Project.fromJson(j);
  }

  Future<void> saveProject(Project p) => store.put('projects', p.id, p.id, p.toJson());
  Future<void> deleteProject(String id) async {
    for (final c in SqliteDocStore.collections) {
      if (c == 'projects') continue;
      await store.deleteWhere(c, projectId: id);
    }
    await store.delete('projects', id);
  }

  // ---------- PDF ----------
  /// docId → 类型（pdf / docx），用于出处显示「第 N 页」还是「标题名」。
  final docTypes = <String, String>{};
  Future<void> loadDocTypes() async {
    for (final j in await store.list('docs')) {
      docTypes[j['id']] = j['type'] ?? 'pdf';
    }
  }

  bool isWordDoc(String docId) => docTypes[docId] == 'docx';

  Future<List<PdfDoc>> docs(String projectId) async {
    final l = (await store.list('docs', projectId: projectId)).map(PdfDoc.fromJson).toList();
    for (final d in l) {
      docTypes[d.id] = d.type;
    }
    return l;
  }

  Future<void> saveDoc(PdfDoc d) {
    docTypes[d.id] = d.type;
    return store.put('docs', d.id, d.projectId, d.toJson());
  }

  Future<void> deletePages(String projectId, String docId) =>
      store.deleteWhere('pages', projectId: projectId, field: 'docId', equals: docId);
  Future<void> deleteDoc(PdfDoc d) async {
    for (final c in ['pages', 'chunks']) {
      await store.deleteWhere(c, projectId: d.projectId, field: 'docId', equals: d.id);
    }
    await store.delete('docs', d.id);
  }

  Future<List<PageText>> pages(String projectId, {String? docId}) async {
    final l = (await store.list('pages', projectId: projectId)).map(PageText.fromJson);
    return l.where((e) => docId == null || e.docId == docId).toList()..sort((a, b) => a.page.compareTo(b.page));
  }

  Future<void> savePages(List<PageText> ps) =>
      store.putAll('pages', ps.map((e) => (e.id, e.projectId, e.toJson())).toList());

  Future<PageText?> page(String docId, int page) async {
    final j = await store.get('pages', '${docId}_$page');
    return j == null ? null : PageText.fromJson(j);
  }

  // ---------- 切块 / 知识点 ----------
  Future<List<Chunk>> chunks(String projectId) async =>
      (await store.list('chunks', projectId: projectId)).map(Chunk.fromJson).toList()
        ..sort((a, b) => a.docId == b.docId ? a.pageStart.compareTo(b.pageStart) : a.docId.compareTo(b.docId));
  Future<void> replaceChunks(String projectId, String docId, List<Chunk> cs) async {
    await store.deleteWhere('chunks', projectId: projectId, field: 'docId', equals: docId);
    await store.putAll('chunks', cs.map((e) => (e.id, e.projectId, e.toJson())).toList());
  }

  Future<List<KnowledgePoint>> kps(String projectId) async =>
      (await store.list('kps', projectId: projectId)).map(KnowledgePoint.fromJson).toList();
  Future<void> saveKps(List<KnowledgePoint> l) =>
      store.putAll('kps', l.map((e) => (e.id, e.projectId, e.toJson())).toList());

  // ---------- 闪卡 / 题目 ----------
  Future<List<Flashcard>> cards({String? projectId}) async =>
      (await store.list('cards', projectId: projectId)).map(Flashcard.fromJson).toList();
  Future<Flashcard?> card(String id) async {
    final j = await store.get('cards', id);
    return j == null ? null : Flashcard.fromJson(j);
  }

  Future<void> saveCards(List<Flashcard> l) =>
      store.putAll('cards', l.map((e) => (e.id, e.projectId, e.toJson())).toList());
  Future<void> deleteCard(String id) => store.delete('cards', id);

  Future<List<Question>> questions({String? projectId}) async =>
      (await store.list('questions', projectId: projectId)).map(Question.fromJson).toList();
  Future<Question?> question(String id) async {
    final j = await store.get('questions', id);
    return j == null ? null : Question.fromJson(j);
  }

  Future<void> saveQuestions(List<Question> l) =>
      store.putAll('questions', l.map((e) => (e.id, e.projectId, e.toJson())).toList());
  Future<void> deleteQuestion(String id) => store.delete('questions', id);

  // ---------- 错题本 ----------
  Future<List<WrongEntry>> wrong({String? projectId}) async =>
      (await store.list('wrong', projectId: projectId)).map(WrongEntry.fromJson).toList()
        ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
  Future<WrongEntry?> wrongEntry(String id) async {
    final j = await store.get('wrong', id);
    return j == null ? null : WrongEntry.fromJson(j);
  }

  Future<void> saveWrong(WrongEntry w) => store.put('wrong', w.id, w.projectId, w.toJson());
  Future<void> deleteWrong(String id) => store.delete('wrong', id);

  /// 提高知识点的复习优先级：priority+1，并让关联闪卡立即到期。
  Future<void> boostKp(String projectId, String kpId) async {
    if (kpId.isEmpty) return;
    final j = await store.get('kps', kpId);
    if (j != null) {
      final kp = KnowledgePoint.fromJson(j)..priority += 1;
      await store.put('kps', kp.id, kp.projectId, kp.toJson());
    }
    final cs = (await cards(projectId: projectId)).where((c) => c.kpId == kpId).toList();
    final now = DateTime.now();
    for (final c in cs) {
      if (c.due.isAfter(now)) c.due = now;
    }
    await saveCards(cs);
  }

  // ---------- 日志 / 解释缓存 ----------
  Future<void> log(LogEntry e) => store.put('logs', e.id, e.projectId, e.toJson());
  Future<void> deleteLog(String id) => store.delete('logs', id);
  Future<LogEntry?> logEntry(String id) async {
    final j = await store.get('logs', id);
    return j == null ? null : LogEntry.fromJson(j);
  }
  Future<List<LogEntry>> logs({String? projectId}) async =>
      (await store.list('logs', projectId: projectId)).map(LogEntry.fromJson).toList();

  Future<ExplainCache?> explain(String itemId) async {
    final j = await store.get('explain', itemId);
    return j == null ? null : ExplainCache.fromJson(j);
  }

  Future<void> saveExplain(ExplainCache c) => store.put('explain', c.id, c.projectId, c.toJson());
}
