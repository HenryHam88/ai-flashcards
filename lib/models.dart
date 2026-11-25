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
  String type; // pdf / docx / doc（后两种都是 Word）
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
  bool get isWord => type == 'docx' || type == 'doc';
  /// TXT：在手机上直接读取，按段落切成小节。
  bool get isText => type == 'txt';
  /// 没有真实页码、按「小节」计数的资料（Word、TXT）。
  bool get isSectioned => isWord || isText;

  /// 资料类型：按扩展名判断。
  static String typeOf(String fileName) {
    final l = fileName.toLowerCase();
    if (l.endsWith('.docx')) return 'docx';
    if (l.endsWith('.doc')) return 'doc';
    if (l.endsWith('.txt')) return 'txt';
    return 'pdf';
  }
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
  /// 解析来源（仅用于显示）：deepseek_text / deepseek_rich / kimi / local；旧数据为空。
  String source;
  PageText({required this.docId, required this.projectId, required this.page, required this.text, this.source = ''});
  String get id => '${docId}_$page';
  Map<String, dynamic> toJson() =>
      {'id': id, 'docId': docId, 'projectId': projectId, 'page': page, 'text': text, if (source.isNotEmpty) 'source': source};
  factory PageText.fromJson(Map<String, dynamic> j) => PageText(
      docId: j['docId'], projectId: j['projectId'], page: j['page'], text: j['text'] ?? '', source: j['source'] ?? '');

  /// 解析来源的显示名。
  static String sourceLabel(String s) => switch (s) {
        'deepseek_text' => 'DeepSeek OCR · 文字模式',
        'deepseek_rich' => 'DeepSeek OCR · 版面模式',
        'deepseek' => 'DeepSeek OCR',
        'kimi' => 'Kimi',
        'local' => '本地（PDF 文字层）',
        'txt' => '本地（TXT）',
        _ => '',
      };
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
  bool suspended; // 用户反馈「这张有问题」时可暂停，不再出现在复习里
  String flag; // 最近一次反馈的原因（空 = 没问题）
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
    this.suspended = false,
    this.flag = '',
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
        if (suspended) 'suspended': true,
        if (flag.isNotEmpty) 'flag': flag,
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
        suspended: j['suspended'] == true,
        flag: j['flag'] ?? '',
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
  bool suspended;
  String flag;
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
    this.suspended = false,
    this.flag = '',
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
        if (suspended) 'suspended': true,
        if (flag.isNotEmpty) 'flag': flag,
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
        suspended: j['suspended'] == true,
        flag: j['flag'] ?? '',
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
  bool isNew; // 闪卡：这次是否是第一次学（用于每日新卡上限）
  int grade; // 闪卡：FSRS 评分 1–4（旧记录为 0）
  LogEntry({required this.id, required this.projectId, required this.kind, required this.correct, DateTime? at, this.isNew = false, this.grade = 0})
      : at = at ?? DateTime.now();
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'kind': kind,
        'correct': correct,
        'at': at.toIso8601String(),
        if (isNew) 'isNew': true,
        if (grade > 0) 'grade': grade,
      };
  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
      id: j['id'],
      projectId: j['projectId'] ?? '',
      kind: j['kind'] ?? 'card',
      correct: j['correct'] == true,
      at: DateTime.tryParse(j['at'] ?? ''),
      isNew: j['isNew'] == true,
      grade: j['grade'] ?? 0);
}

/// AI 解释缓存（含追问对话）。
/// 同时也是「解释历史」的一条记录。
class ExplainCache {
  String id; // itemId
  String projectId;
  List<Map<String, String>> messages; // role/content，第一条 assistant 为首次解释
  String kind; // card / question（旧记录为空，打开历史时自动补齐）
  String title; // 卡片正面 / 题干，用于列表预览和搜索
  DateTime createdAt;
  DateTime updatedAt;
  bool starred;
  ExplainCache(
      {required this.id,
      required this.projectId,
      required this.messages,
      this.kind = '',
      this.title = '',
      DateTime? createdAt,
      DateTime? updatedAt,
      this.starred = false})
      : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  /// 首次解释内容（不含提示词）。
  String get firstAnswer => messages.length > 1 ? messages[1]['content'] ?? '' : '';
  int get followUps => messages.length > 2 ? (messages.length - 2) ~/ 2 : 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'messages': messages,
        'kind': kind,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'starred': starred,
      };
  factory ExplainCache.fromJson(Map<String, dynamic> j) => ExplainCache(
        id: j['id'],
        projectId: j['projectId'] ?? '',
        messages: ((j['messages'] as List?) ?? [])
            .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v.toString())))
            .toList(),
        kind: j['kind'] ?? '',
        title: j['title'] ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? ''),
        starred: j['starred'] == true,
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
  /// 数量模式：false = 固定数量（默认）；true = 自动（按知识点估算，生成前确认）。
  bool autoCount;
  bool autoCards; // 自动模式下是否出闪卡
  bool autoQuestions; // 自动模式下是否出题目
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
    this.autoCount = false,
    this.autoCards = true,
    this.autoQuestions = true,
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
        if (autoCount) ...{'autoCount': true, 'autoCards': autoCards, 'autoQuestions': autoQuestions},
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
        autoCount: j['autoCount'] == true,
        autoCards: j['autoCards'] != false,
        autoQuestions: j['autoQuestions'] != false,
      );
  GenOptions copy() => GenOptions.fromJson(toJson());
}

/// 一个章节覆盖的页码范围（1 起始、闭区间）。Word 文档的「页」是解析出的小节序号。
class ChapterRange {
  String title;
  int start;
  int end;
  ChapterRange(this.title, this.start, this.end);
  ChapterRange copy() => ChapterRange(title, start, end);
  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};
  factory ChapterRange.fromJson(Map<String, dynamic> j) =>
      ChapterRange(j['title'] ?? '', (j['start'] as num?)?.toInt() ?? 1, (j['end'] as num?)?.toInt() ?? 1);
  @override
  String toString() => '$title[$start-$end]';
}

/// 一份资料的分章方案（每份资料一条，id = docId）。
class ChapterPlan {
  String docId;
  String projectId;
  String source; // outline 书签 / toc 目录页 / heading 标题识别 / ai / fixed 按页数 / manual 手动 / single 全文
  List<ChapterRange> chapters;
  ChapterPlan({required this.docId, required this.projectId, required this.source, required this.chapters});
  String get id => docId;

  /// 某页所属章节标题；页码超出范围时归到最近的章节。
  String titleFor(int page) {
    if (chapters.isEmpty) return '未分章';
    for (final c in chapters) {
      if (page >= c.start && page <= c.end) return c.title;
    }
    return page < chapters.first.start ? chapters.first.title : chapters.last.title;
  }

  Map<String, dynamic> toJson() => {
        'id': docId,
        'docId': docId,
        'projectId': projectId,
        'source': source,
        'chapters': chapters.map((c) => c.toJson()).toList(),
      };
  factory ChapterPlan.fromJson(Map<String, dynamic> j) => ChapterPlan(
        docId: j['docId'],
        projectId: j['projectId'],
        source: j['source'] ?? 'manual',
        chapters: ((j['chapters'] as List?) ?? []).map((e) => ChapterRange.fromJson((e as Map).cast<String, dynamic>())).toList(),
      );
}


/// 用户对一张卡 / 一道题的反馈（「这张有问题」）。
class FeedbackEntry {
  String id;
  String projectId;
  String itemId;
  String kind; // card / question
  String reason; // 答案错误 / 太简单 / 重复 / 超纲 / 表述不清 / 其他 / AI出错了
  String note;
  String itemText; // 反馈时的题面，便于生成「避免清单」
  DateTime at;
  FeedbackEntry({
    required this.id,
    required this.projectId,
    required this.itemId,
    required this.kind,
    required this.reason,
    this.note = '',
    this.itemText = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();
  static const reasons = ['答案错误', '太简单', '重复', '超纲', '表述不清', '其他'];
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'itemId': itemId,
        'kind': kind,
        'reason': reason,
        'note': note,
        'itemText': itemText,
        'at': at.toIso8601String(),
      };
  factory FeedbackEntry.fromJson(Map<String, dynamic> j) => FeedbackEntry(
        id: j['id'],
        projectId: j['projectId'] ?? '',
        itemId: j['itemId'] ?? '',
        kind: j['kind'] ?? 'card',
        reason: j['reason'] ?? '其他',
        note: j['note'] ?? '',
        itemText: j['itemText'] ?? '',
        at: DateTime.tryParse(j['at'] ?? ''),
      );
}

/// 一次学习会话的时长（用于统计「学习时长」）。
class StudySession {
  String id;
  String projectId;
  String kind; // review / quiz
  DateTime start;
  int seconds;
  StudySession({required this.id, required this.projectId, required this.kind, required this.start, this.seconds = 0});
  Map<String, dynamic> toJson() =>
      {'id': id, 'projectId': projectId, 'kind': kind, 'start': start.toIso8601String(), 'seconds': seconds};
  factory StudySession.fromJson(Map<String, dynamic> j) => StudySession(
      id: j['id'],
      projectId: j['projectId'] ?? '',
      kind: j['kind'] ?? 'review',
      start: DateTime.tryParse(j['start'] ?? '') ?? DateTime.now(),
      seconds: (j['seconds'] as num?)?.toInt() ?? 0);
}

// ============================================================ v7：收藏 / 导图 / 学习对话 / 笔记 / 云端文件

/// 收藏：知识点、闪卡、题目。id = kind_targetId，同一对象只收藏一次。
class FavoriteItem {
  String projectId;
  String kind; // kp / card / question
  String targetId;
  String title; // 收藏时的标题快照（对象被删后仍能显示）
  DateTime createdAt;
  FavoriteItem({required this.projectId, required this.kind, required this.targetId, this.title = '', DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();
  String get id => idFor(kind, targetId);
  static String idFor(String kind, String targetId) => '${kind}_$targetId';
  static const kinds = ['kp', 'card', 'question'];
  static const kindNames = {'kp': '知识点', 'card': '闪卡', 'question': '题目'};
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'kind': kind,
        'targetId': targetId,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
      };
  factory FavoriteItem.fromJson(Map<String, dynamic> j) => FavoriteItem(
        projectId: j['projectId'] ?? '',
        kind: j['kind'] ?? 'kp',
        targetId: j['targetId'] ?? '',
        title: j['title'] ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
      );
}

/// 思维导图节点（树）。text 支持 $...$ 公式。
class MindNode {
  String id;
  String text; // 短标题，可含 $...$ 公式
  String note; // 详细说明（点节点时显示）
  int page; // 教材页码（0 = 未知）
  String kpId; // 对应的知识点
  List<MindNode> children;
  MindNode({String? id, required this.text, this.note = '', this.page = 0, this.kpId = '', List<MindNode>? children})
      : id = id ?? newId(),
        children = children ?? [];
  int get count => 1 + children.fold(0, (a, c) => a + c.count);
  int get depth => 1 + children.fold(0, (a, c) => a > c.depth ? a : c.depth);
  MindNode? find(String nodeId) {
    if (id == nodeId) return this;
    for (final c in children) {
      final r = c.find(nodeId);
      if (r != null) return r;
    }
    return null;
  }

  MindNode? parentOf(String nodeId) {
    for (final c in children) {
      if (c.id == nodeId) return this;
      final r = c.parentOf(nodeId);
      if (r != null) return r;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (note.isNotEmpty) 'note': note,
        if (page > 0) 'page': page,
        if (kpId.isNotEmpty) 'kpId': kpId,
        if (children.isNotEmpty) 'children': [for (final c in children) c.toJson()],
      };
  factory MindNode.fromJson(Map<String, dynamic> j) => MindNode(
        id: j['id']?.toString(),
        text: '${j['text'] ?? j['title'] ?? ''}',
        note: '${j['note'] ?? ''}',
        page: j['page'] is int ? j['page'] : int.tryParse('${j['page'] ?? ''}') ?? 0,
        kpId: '${j['kpId'] ?? j['kp_id'] ?? ''}',
        children: [for (final c in (j['children'] as List?) ?? const []) if (c is Map) MindNode.fromJson(c.cast<String, dynamic>())],
      );
}

/// 一章的思维导图（按需生成，可手动编辑）。id = docId|章节名。
class ChapterMindMap {
  String projectId;
  String docId;
  String chapter;
  MindNode root;
  DateTime updatedAt;
  bool edited; // 生成后是否手动改过
  ChapterMindMap({required this.projectId, required this.docId, required this.chapter, required this.root, DateTime? updatedAt, this.edited = false})
      : updatedAt = updatedAt ?? DateTime.now();
  String get id => idFor(docId, chapter);
  static String idFor(String docId, String chapter) => '$docId|$chapter';
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'docId': docId,
        'chapter': chapter,
        'root': root.toJson(),
        'updatedAt': updatedAt.toIso8601String(),
        if (edited) 'edited': true,
      };
  factory ChapterMindMap.fromJson(Map<String, dynamic> j) => ChapterMindMap(
        projectId: j['projectId'] ?? '',
        docId: j['docId'] ?? '',
        chapter: j['chapter'] ?? '',
        root: MindNode.fromJson(((j['root'] as Map?) ?? {'text': j['chapter'] ?? ''}).cast<String, dynamic>()),
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? ''),
        edited: j['edited'] == true,
      );
}

/// 学习对话里选中的一段已解析资料：某份资料的某一章，或一段页码。
class MaterialRef {
  String docId;
  String chapter; // 非空 = 按章
  int pageFrom;
  int pageTo;
  MaterialRef({required this.docId, this.chapter = '', this.pageFrom = 0, this.pageTo = 0});
  Map<String, dynamic> toJson() => {'docId': docId, if (chapter.isNotEmpty) 'chapter': chapter, 'pageFrom': pageFrom, 'pageTo': pageTo};
  factory MaterialRef.fromJson(Map<String, dynamic> j) =>
      MaterialRef(docId: j['docId'] ?? '', chapter: j['chapter'] ?? '', pageFrom: j['pageFrom'] ?? 0, pageTo: j['pageTo'] ?? 0);
}

/// 伴学对话里用户上传的附件（文件本身登记为 MediaAsset，kind = chat_file）。
/// 文档抽出的文字随对话保存，之后每轮不用重新解析；图片每轮直接发给模型看。
class ChatAttachment {
  String id; // MediaAsset id
  String name;
  String kind; // pdf / word / txt / image
  int size;
  String text; // 抽出的文字（已截到上限）
  int chars; // 原文总字数
  int pages; // PDF 页数（其他为 0）
  ChatAttachment({required this.id, required this.name, required this.kind, this.size = 0, this.text = '', this.chars = 0, this.pages = 0});
  bool get isImage => kind == 'image';
  bool get truncated => !isImage && chars > text.length;
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'kind': kind, 'size': size, if (text.isNotEmpty) 'text': text, 'chars': chars, if (pages > 0) 'pages': pages};
  factory ChatAttachment.fromJson(Map<String, dynamic> j) => ChatAttachment(
      id: j['id'] ?? '',
      name: j['name'] ?? '',
      kind: j['kind'] ?? 'txt',
      size: j['size'] ?? 0,
      text: j['text'] ?? '',
      chars: j['chars'] ?? 0,
      pages: j['pages'] ?? 0);
}

/// 学习板块的 AI 对话（基于用户选定的资料范围）。
class StudyChat {
  String id;
  String projectId;
  String title;
  List<MaterialRef> scope;
  List<Map<String, String>> messages; // 只存可见对话（user / assistant），资料原文每次发送时拼进系统提示
  /// 这个对话的联网设置：null = 跟随「我的 → 出题模型」里的全局设置。
  bool? web;
  String? webMode; // 'deep' / 'normal'
  List<ChatAttachment> attachments;
  /// 最近一次计算的上下文分配（不保存）：附件实际发送了多少字、丢掉了几条较早的对话。
  ContextPlan? plan;
  DateTime createdAt;
  DateTime updatedAt;
  StudyChat(
      {required this.id,
      required this.projectId,
      this.title = '',
      List<MaterialRef>? scope,
      List<Map<String, String>>? messages,
      this.web,
      this.webMode,
      List<ChatAttachment>? attachments,
      DateTime? createdAt,
      DateTime? updatedAt})
      : scope = scope ?? [],
        attachments = attachments ?? [],
        messages = messages ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? createdAt ?? DateTime.now();
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'title': title,
        'scope': [for (final r in scope) r.toJson()],
        'messages': messages,
        if (web != null) 'web': web,
        if (webMode != null) 'webMode': webMode,
        if (attachments.isNotEmpty) 'attachments': [for (final a in attachments) a.toJson()],
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
  factory StudyChat.fromJson(Map<String, dynamic> j) => StudyChat(
        id: j['id'],
        projectId: j['projectId'] ?? '',
        title: j['title'] ?? '',
        scope: [for (final r in (j['scope'] as List?) ?? const []) MaterialRef.fromJson((r as Map).cast<String, dynamic>())],
        messages: [for (final m in (j['messages'] as List?) ?? const []) (m as Map).map((k, v) => MapEntry('$k', '$v'))],
        web: j['web'] is bool ? j['web'] : null,
        webMode: j['webMode'] is String ? j['webMode'] : null,
        attachments: [for (final a in (j['attachments'] as List?) ?? const []) ChatAttachment.fromJson((a as Map).cast<String, dynamic>())],
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? ''),
      );
}

/// 笔记里引用的一段已解析原文。
class NoteQuote {
  String docId;
  int page;
  String text;
  NoteQuote({required this.docId, this.page = 0, required this.text});
  Map<String, dynamic> toJson() => {'docId': docId, 'page': page, 'text': text};
  factory NoteQuote.fromJson(Map<String, dynamic> j) => NoteQuote(docId: j['docId'] ?? '', page: j['page'] ?? 0, text: j['text'] ?? '');
}

/// 笔记：挂在一个知识点下（kpId 可为空 = 未关联知识点）。
class StudyNote {
  String id;
  String projectId;
  String kpId;
  String chapter;
  String title;
  String own; // 自己的理解（Markdown + 公式）
  String ai; // AI 解释
  String aiSources; // AI 讲解引用的网页（WebSource.encode）
  List<NoteQuote> quotes;
  List<String> questionIds;
  List<String> photoIds; // MediaAsset id
  DateTime createdAt;
  DateTime updatedAt;
  StudyNote({
    required this.id,
    required this.projectId,
    this.kpId = '',
    this.chapter = '',
    this.title = '',
    this.own = '',
    this.ai = '',
    this.aiSources = '',
    List<NoteQuote>? quotes,
    List<String>? questionIds,
    List<String>? photoIds,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : quotes = quotes ?? [],
        questionIds = questionIds ?? [],
        photoIds = photoIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? createdAt ?? DateTime.now();
  bool get isEmpty => own.trim().isEmpty && ai.trim().isEmpty && quotes.isEmpty && questionIds.isEmpty && photoIds.isEmpty;
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'kpId': kpId,
        'chapter': chapter,
        'title': title,
        'own': own,
        'ai': ai,
        if (aiSources.isNotEmpty) 'aiSources': aiSources,
        'quotes': [for (final q in quotes) q.toJson()],
        'questionIds': questionIds,
        'photoIds': photoIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
  factory StudyNote.fromJson(Map<String, dynamic> j) => StudyNote(
        id: j['id'],
        projectId: j['projectId'] ?? '',
        kpId: j['kpId'] ?? '',
        chapter: j['chapter'] ?? '',
        title: j['title'] ?? '',
        own: j['own'] ?? '',
        ai: j['ai'] ?? '',
        aiSources: j['aiSources'] ?? '',
        quotes: [for (final q in (j['quotes'] as List?) ?? const []) NoteQuote.fromJson((q as Map).cast<String, dynamic>())],
        questionIds: [for (final x in (j['questionIds'] as List?) ?? const []) '$x'],
        photoIds: [for (final x in (j['photoIds'] as List?) ?? const []) '$x'],
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? ''),
      );
}

/// 可以放到云端省空间的大文件（原始资料、笔记照片、导出的 PDF、备份）。
/// 资料文件的 id = `doc_<docId>`；本地路径就是原来的位置，释放空间后删除本地文件，用到时再下载回同一位置。
class MediaAsset {
  String id;
  String projectId;
  String kind; // doc / photo / export / backup
  String ownerId; // 资料 id、笔记 id……
  String localPath;
  String fileName;
  int size;
  String sha256;
  String cloudKey; // 非空 = 云端已有一份
  bool offloaded; // true = 本地文件已删除，只在云端
  bool cached; // true = 从云端下载回来的临时副本，超过缓存上限时可以自动删掉（云端仍保留）
  String thumbPath; // 照片的本机小缩略图（原图放到云端后仍可预览）
  DateTime createdAt;
  DateTime lastAccess;
  MediaAsset({
    required this.id,
    required this.projectId,
    required this.kind,
    this.ownerId = '',
    required this.localPath,
    this.fileName = '',
    this.size = 0,
    this.sha256 = '',
    this.cloudKey = '',
    this.offloaded = false,
    this.cached = false,
    this.thumbPath = '',
    DateTime? createdAt,
    DateTime? lastAccess,
  })  : createdAt = createdAt ?? DateTime.now(),
        lastAccess = lastAccess ?? createdAt ?? DateTime.now();
  static String docId(String id) => 'doc_$id';
  bool get inCloud => cloudKey.isNotEmpty;

  /// 状态文字：仅本机 / 本机 + 云端 / 仅云端。
  String get stateLabel => offloaded ? '仅云端' : (inCloud ? '本机 + 云端' : '仅本机');
  static const kindNames = {'doc': '原始资料', 'photo': '笔记照片', 'chat_file': '伴学附件', 'export': '导出的 PDF', 'backup': '备份'};
  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'kind': kind,
        'ownerId': ownerId,
        'localPath': localPath,
        'fileName': fileName,
        'size': size,
        'sha256': sha256,
        'cloudKey': cloudKey,
        'offloaded': offloaded,
        if (cached) 'cached': true,
        if (thumbPath.isNotEmpty) 'thumbPath': thumbPath,
        'createdAt': createdAt.toIso8601String(),
        'lastAccess': lastAccess.toIso8601String(),
      };
  factory MediaAsset.fromJson(Map<String, dynamic> j) => MediaAsset(
        id: j['id'],
        projectId: j['projectId'] ?? '',
        kind: j['kind'] ?? 'doc',
        ownerId: j['ownerId'] ?? '',
        localPath: j['localPath'] ?? '',
        fileName: j['fileName'] ?? '',
        size: j['size'] ?? 0,
        sha256: j['sha256'] ?? '',
        cloudKey: j['cloudKey'] ?? '',
        offloaded: j['offloaded'] == true,
        cached: j['cached'] == true,
        thumbPath: j['thumbPath'] ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        lastAccess: DateTime.tryParse(j['lastAccess'] ?? ''),
      );
}

/// 一次提问的上下文分配：按模型上下文长度扣掉系统提示、资料、对话、回答预留和安全余量后，剩下的给附件。
class ContextPlan {
  final int context; // 模型上下文长度（token）
  final int attachChars; // 附件文字总字数
  final int attachSent; // 这次实际发送的附件字数
  final int historyDropped; // 为了腾地方没有发送的较早消息条数
  const ContextPlan({required this.context, required this.attachChars, required this.attachSent, this.historyDropped = 0});
  bool get attachCut => attachSent < attachChars;
}
