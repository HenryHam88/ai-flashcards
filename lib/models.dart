// 数据模型：全部可序列化为 JSON，便于本地存储与日后 WebDAV 同步。

String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    (DateTime.now().hashCode & 0xffff).toRadixString(36);

class Project {
  String id;
  String name;
  DateTime createdAt;
  Map<String, dynamic>? defaultOptions; // GenOptions json
  Project({required this.id, required this.name, DateTime? createdAt, this.defaultOptions})
      : createdAt = createdAt ?? DateTime.now();
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'defaultOptions': defaultOptions,
      };
  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'],
        name: j['name'],
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        defaultOptions: (j['defaultOptions'] as Map?)?.cast<String, dynamic>(),
      );
}

class PdfDoc {
  String id;
  String projectId;
  String name;
  String path; // 本地文件路径
  int pageCount;
  int parsedPages;
  String status; // 未解析 / 解析中 / 已解析 / 部分失败 / 不支持
  String type; // pdf / docx（Word）
  String note; // 给用户看的提示，例如当前解析模型不支持 Word
  PdfDoc({
    required this.id,
    required this.projectId,
    required this.name,
    required this.path,
    this.pageCount = 0,
    this.parsedPages = 0,
    this.status = '未解析',
    this.type = 'pdf',
    this.note = '',
  });
  bool get isWord => type == 'docx';

  /// 资料类型：按扩展名判断。
  static String typeOf(String fileName) => fileName.toLowerCase().endsWith('.docx') ? 'docx' : 'pdf';
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'name': name,
        'path': path,
        'pageCount': pageCount,
        'parsedPages': parsedPages,
        'status': status,
        'type': type,
        'note': note,
      };
  factory PdfDoc.fromJson(Map<String, dynamic> j) => PdfDoc(
        id: j['id'],
        projectId: j['projectId'],
        name: j['name'],
        path: j['path'],
        pageCount: j['pageCount'] ?? 0,
        parsedPages: j['parsedPages'] ?? 0,
        status: j['status'] ?? '未解析',
        type: j['type'] ?? 'pdf', // 旧数据没有 type，一律是 PDF
        note: j['note'] ?? '',
      );
}

/// 解析后的一页文字（1 起始页码），按 docId_page 缓存，永不重复解析。
class PageText {
  String docId;
  String projectId;
  int page;
  String text;
  PageText({required this.docId, required this.projectId, required this.page, required this.text});
  String get id => '${docId}_$page';
  Map<String, dynamic> toJson() =>
      {'id': id, 'docId': docId, 'projectId': projectId, 'page': page, 'text': text};
  factory PageText.fromJson(Map<String, dynamic> j) =>
      PageText(docId: j['docId'], projectId: j['projectId'], page: j['page'], text: j['text'] ?? '');
}

class Chunk {
  String id;
  String projectId;
  String docId;
  String chapter;
  String section;
  int pageStart;
  int pageEnd;
  String text;
  Chunk({
    required this.id,
    required this.projectId,
    required this.docId,
    required this.chapter,
    required this.section,
    required this.pageStart,
    required this.pageEnd,
    required this.text,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'docId': docId,
        'chapter': chapter,
        'section': section,
        'pageStart': pageStart,
        'pageEnd': pageEnd,
        'text': text,
      };
  factory Chunk.fromJson(Map<String, dynamic> j) => Chunk(
        id: j['id'],
        projectId: j['projectId'],
        docId: j['docId'],
        chapter: j['chapter'] ?? '',
        section: j['section'] ?? '',
        pageStart: j['pageStart'] ?? 0,
        pageEnd: j['pageEnd'] ?? 0,
        text: j['text'] ?? '',
      );
}

class KnowledgePoint {
  String id;
  String projectId;
  String docId;
  String chapter;
  String section;
  String title;
  String type; // 定义/定理/公式/方法/例题
  String content;
  int page;
  int priority; // 错题会提高
  KnowledgePoint({
    required this.id,
    required this.projectId,
    this.docId = '',
    this.chapter = '',
    this.section = '',
    required this.title,
    this.type = '',
    this.content = '',
    this.page = 0,
    this.priority = 0,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'docId': docId,
        'chapter': chapter,
        'section': section,
        'title': title,
        'type': type,
        'content': content,
        'page': page,
        'priority': priority,
      };
  factory KnowledgePoint.fromJson(Map<String, dynamic> j) => KnowledgePoint(
        id: j['id'],
        projectId: j['projectId'],
        docId: j['docId'] ?? '',
        chapter: j['chapter'] ?? '',
        section: j['section'] ?? '',
        title: j['title'] ?? '',
        type: j['type'] ?? '',
        content: j['content'] ?? '',
        page: j['page'] ?? 0,
        priority: j['priority'] ?? 0,
      );
}

class Flashcard {
  String id;
  String projectId;
  String kpId;
  String docId;
  String chapter;
  String section;
  String front;
  String back;
  String explanation;
  int page;
  // FSRS 状态
  double stability;
  double difficulty;
  int reps;
  int lapses;
  DateTime due;
  DateTime? lastReview;
  Flashcard({
    required this.id,
    required this.projectId,
    this.kpId = '',
    this.docId = '',
    this.chapter = '',
    this.section = '',
    required this.front,
    required this.back,
    this.explanation = '',
    this.page = 0,
    this.stability = 0,
    this.difficulty = 0,
    this.reps = 0,
    this.lapses = 0,
    DateTime? due,
    this.lastReview,
  }) : due = due ?? DateTime.now();
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'kpId': kpId,
        'docId': docId,
        'chapter': chapter,
        'section': section,
        'front': front,
        'back': back,
        'explanation': explanation,
        'page': page,
        'stability': stability,
        'difficulty': difficulty,
        'reps': reps,
        'lapses': lapses,
        'due': due.toIso8601String(),
        'lastReview': lastReview?.toIso8601String(),
      };
  factory Flashcard.fromJson(Map<String, dynamic> j) => Flashcard(
        id: j['id'],
        projectId: j['projectId'],
        kpId: j['kpId'] ?? '',
        docId: j['docId'] ?? '',
        chapter: j['chapter'] ?? '',
        section: j['section'] ?? '',
        front: j['front'] ?? '',
        back: j['back'] ?? '',
        explanation: j['explanation'] ?? '',
        page: j['page'] ?? 0,
        stability: (j['stability'] ?? 0).toDouble(),
        difficulty: (j['difficulty'] ?? 0).toDouble(),
        reps: j['reps'] ?? 0,
        lapses: j['lapses'] ?? 0,
        due: DateTime.tryParse(j['due'] ?? ''),
        lastReview: j['lastReview'] == null ? null : DateTime.tryParse(j['lastReview']),
      );
}

class QType {
  static const single = '单选';
  static const multi = '多选';
  static const judge = '判断';
  static const fill = '填空';
  static const short = '简答';
  static const calc = '计算';
  static const all = [single, multi, judge, fill, short, calc];
  static bool isObjective(String t) => t != short && t != calc;
}

class Question {
  String id;
  String projectId;
  String kpId;
  String docId;
  String chapter;
  String section;
  String type;
  String stem;
  List<String> options;
  String answer; // 单选 "B"；多选 "AC"；判断 "对/错"；填空 多个可接受答案用 | 分隔
  String explanation;
  String difficulty;
  int page;
  Question({
    required this.id,
    required this.projectId,
    this.kpId = '',
    this.docId = '',
    this.chapter = '',
    this.section = '',
    required this.type,
    required this.stem,
    this.options = const [],
    required this.answer,
    this.explanation = '',
    this.difficulty = '中等',
    this.page = 0,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'kpId': kpId,
        'docId': docId,
        'chapter': chapter,
        'section': section,
        'type': type,
        'stem': stem,
        'options': options,
        'answer': answer,
        'explanation': explanation,
        'difficulty': difficulty,
        'page': page,
      };
  factory Question.fromJson(Map<String, dynamic> j) => Question(
        id: j['id'],
        projectId: j['projectId'],
        kpId: j['kpId'] ?? '',
        docId: j['docId'] ?? '',
        chapter: j['chapter'] ?? '',
        section: j['section'] ?? '',
        type: j['type'] ?? QType.single,
        stem: j['stem'] ?? '',
        options: ((j['options'] as List?) ?? []).map((e) => e.toString()).toList(),
        answer: j['answer']?.toString() ?? '',
        explanation: j['explanation'] ?? '',
        difficulty: j['difficulty'] ?? '中等',
        page: j['page'] ?? 0,
      );
}

class WrongEntry {
  String id; // = questionId 或 'card_'+cardId
  String projectId;
  String questionId;
  String cardId;
  String kpId;
  String mark; // 答错 / 不确定 / AI出错了
  int streak; // 连续答对次数
  String lastAnswer;
  DateTime addedAt;
  WrongEntry({
    required this.id,
    required this.projectId,
    this.questionId = '',
    this.cardId = '',
    this.kpId = '',
    this.mark = '答错',
    this.streak = 0,
    this.lastAnswer = '',
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'questionId': questionId,
        'cardId': cardId,
        'kpId': kpId,
        'mark': mark,
        'streak': streak,
        'lastAnswer': lastAnswer,
        'addedAt': addedAt.toIso8601String(),
      };
  factory WrongEntry.fromJson(Map<String, dynamic> j) => WrongEntry(
        id: j['id'],
        projectId: j['projectId'],
        questionId: j['questionId'] ?? '',
        cardId: j['cardId'] ?? '',
        kpId: j['kpId'] ?? '',
        mark: j['mark'] ?? '答错',
        streak: j['streak'] ?? 0,
        lastAnswer: j['lastAnswer'] ?? '',
        addedAt: DateTime.tryParse(j['addedAt'] ?? ''),
      );
}

/// 一次复习或答题记录，用于统计。
class LogEntry {
  String id;
  String projectId;
  String kind; // card / quiz
  bool correct;
  DateTime at;
  LogEntry({required this.id, required this.projectId, required this.kind, required this.correct, DateTime? at})
      : at = at ?? DateTime.now();
  Map<String, dynamic> toJson() =>
      {'id': id, 'projectId': projectId, 'kind': kind, 'correct': correct, 'at': at.toIso8601String()};
  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
      id: j['id'],
      projectId: j['projectId'] ?? '',
      kind: j['kind'] ?? 'card',
      correct: j['correct'] == true,
      at: DateTime.tryParse(j['at'] ?? ''));
}

/// AI 解释缓存（含追问对话）。
class ExplainCache {
  String id; // itemId
  String projectId;
  List<Map<String, String>> messages; // role/content，第一条 assistant 为首次解释
  ExplainCache({required this.id, required this.projectId, required this.messages});
  Map<String, dynamic> toJson() => {'id': id, 'projectId': projectId, 'messages': messages};
  factory ExplainCache.fromJson(Map<String, dynamic> j) => ExplainCache(
        id: j['id'],
        projectId: j['projectId'] ?? '',
        messages: ((j['messages'] as List?) ?? [])
            .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v.toString())))
            .toList(),
      );
}

class GenOptions {
  String scope; // whole / chapters / pages
  List<String> chapters;
  int pageFrom;
  int pageTo;
  int cardCount;
  int questionCount;
  List<String> types;
  String difficulty; // 基础/中等/拔高/混合
  List<String> focus;
  String custom;
  GenOptions({
    this.scope = 'whole',
    List<String>? chapters,
    this.pageFrom = 1,
    this.pageTo = 30,
    this.cardCount = 20,
    this.questionCount = 10,
    List<String>? types,
    this.difficulty = '混合',
    List<String>? focus,
    this.custom = '',
  })  : chapters = chapters ?? [],
        types = types ?? [QType.single, QType.judge, QType.fill],
        focus = focus ?? ['概念定义', '公式定理'];
  Map<String, dynamic> toJson() => {
        'scope': scope,
        'chapters': chapters,
        'pageFrom': pageFrom,
        'pageTo': pageTo,
        'cardCount': cardCount,
        'questionCount': questionCount,
        'types': types,
        'difficulty': difficulty,
        'focus': focus,
        'custom': custom,
      };
  factory GenOptions.fromJson(Map<String, dynamic> j) => GenOptions(
        scope: j['scope'] ?? 'whole',
        chapters: ((j['chapters'] as List?) ?? []).map((e) => e.toString()).toList(),
        pageFrom: j['pageFrom'] ?? 1,
        pageTo: j['pageTo'] ?? 30,
        cardCount: j['cardCount'] ?? 20,
        questionCount: j['questionCount'] ?? 10,
        types: ((j['types'] as List?) ?? []).map((e) => e.toString()).toList(),
        difficulty: j['difficulty'] ?? '混合',
        focus: ((j['focus'] as List?) ?? []).map((e) => e.toString()).toList(),
        custom: j['custom'] ?? '',
      );
  GenOptions copy() => GenOptions.fromJson(toJson());
}
