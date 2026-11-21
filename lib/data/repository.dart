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
  /// docId → 类型（pdf / docx / doc），用于出处显示「第 N 页」还是「标题名」。
  final docTypes = <String, String>{};
  Future<void> loadDocTypes() async {
    for (final j in await store.list('docs')) {
      docTypes[j['id']] = j['type'] ?? 'pdf';
    }
  }

  bool isWordDoc(String docId) => docTypes[docId] == 'docx' || docTypes[docId] == 'doc';
  bool isTextDoc(String docId) => docTypes[docId] == 'txt';

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
  // ---------- 分章方案 ----------
  Future<ChapterPlan?> chapterPlan(String docId) async {
    final j = await store.get('chapters', docId);
    return j == null ? null : ChapterPlan.fromJson(j);
  }

  Future<void> saveChapterPlan(ChapterPlan p) => store.put('chapters', p.id, p.projectId, p.toJson());

  Future<void> deleteDoc(PdfDoc d) async {
    await store.delete('chapters', d.id);
    for (final c in ['pages', 'chunks', 'reparse']) {
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
  Future<void> deleteKps(List<String> ids) async {
    for (final id in ids) {
      await store.delete('kps', id);
    }
  }

  Future<void> deletePage(String docId, int page) => store.delete('pages', '${docId}_$page');

  // ---------- 按章重新解析的快照（恢复上次解析） ----------
  Future<Map<String, dynamic>?> reparseSnapshot(String id) => store.get('reparse', id);
  Future<void> saveReparseSnapshot(String id, String projectId, Map<String, dynamic> j) =>
      store.put('reparse', id, projectId, j);
  Future<void> deleteReparseSnapshot(String id) => store.delete('reparse', id);

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
  Future<void> deleteExplain(String id) => store.delete('explain', id);

  /// 解释历史，最新在前。旧版缓存（没有类型 / 标题）在这里补齐并写回，相当于一次惰性迁移。
  Future<List<ExplainCache>> explainHistory({String? projectId}) async {
    final l = (await store.list('explain', projectId: projectId)).map(ExplainCache.fromJson).toList();
    for (final e in l.where((e) => e.kind.isEmpty || e.title.isEmpty)) {
      final c = await card(e.id);
      final q = c == null ? await question(e.id) : null;
      if (c == null && q == null) {
        e.kind = e.kind.isEmpty ? 'gone' : e.kind;
      } else {
        e.kind = c != null ? 'card' : 'question';
        e.title = c?.front ?? q!.stem;
      }
      if (e.title.isEmpty) e.title = _titleFromPrompt(e.messages.isEmpty ? '' : e.messages.first['content'] ?? '');
      await saveExplain(e);
    }
    return l.where((e) => e.messages.length >= 2).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  static String _titleFromPrompt(String p) {
    final m = RegExp(r'(?:闪卡问题|题)：(.+)').firstMatch(p);
    return (m?.group(1) ?? '').trim();
  }

  // ---------- 反馈 ----------
  Future<void> saveFeedback(FeedbackEntry f) => store.put('feedback', f.id, f.projectId, f.toJson());
  Future<List<FeedbackEntry>> feedback({String? projectId}) async =>
      (await store.list('feedback', projectId: projectId)).map(FeedbackEntry.fromJson).toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  // ---------- 学习时长 ----------
  Future<void> saveSession(StudySession x) => store.put('sessions', x.id, x.projectId, x.toJson());
  Future<List<StudySession>> sessions({String? projectId}) async =>
      (await store.list('sessions', projectId: projectId)).map(StudySession.fromJson).toList();

  // ---------- 待审核（生成后先审核） ----------
  Future<List<Flashcard>> inboxCards({String? projectId}) async =>
      (await store.list('inbox_cards', projectId: projectId)).map(Flashcard.fromJson).toList();
  Future<List<Question>> inboxQuestions({String? projectId}) async =>
      (await store.list('inbox_questions', projectId: projectId)).map(Question.fromJson).toList();
  Future<void> saveInbox(List<Flashcard> cs, List<Question> qs) async {
    await store.putAll('inbox_cards', cs.map((e) => (e.id, e.projectId, e.toJson())).toList());
    await store.putAll('inbox_questions', qs.map((e) => (e.id, e.projectId, e.toJson())).toList());
  }

  Future<void> deleteInbox(String id) async {
    await store.delete('inbox_cards', id);
    await store.delete('inbox_questions', id);
  }

  /// 收下：从待审核移到正式卡片 / 题目。
  Future<void> acceptInbox(List<Flashcard> cs, List<Question> qs) async {
    await saveCards(cs);
    await saveQuestions(qs);
    for (final c in cs) {
      await store.delete('inbox_cards', c.id);
    }
    for (final q in qs) {
      await store.delete('inbox_questions', q.id);
    }
  }
}
