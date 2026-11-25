import 'dart:io';

import 'package:ai_flashcards/data/repository.dart';
import 'package:ai_flashcards/models.dart';
import 'package:ai_flashcards/services/llm.dart' show WebSource;

import 'sample_data.dart';

/// 导出到 Obsidian / Notion 的示例数据：示例项目 + 笔记（带照片）、伴学对话（带附件）、解释、收藏、错题。
/// 返回 mediaId → 本机文件，供导出时读取照片和附件。
Future<Map<String, File>> seedKbData(Repository repo, Directory dir) async {
  final now = DateTime(2026, 11, 25, 21, 30);
  await seedSampleData(repo, now: now);
  final files = <String, File>{};
  Future<void> media(String id, String name, List<int> bytes, String kind, String owner) async {
    final f = File('${dir.path}/media/$name')..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    files[id] = f;
    await repo.saveMedia(MediaAsset(id: id, projectId: 'p1', kind: kind, ownerId: owner, localPath: f.path, fileName: name, size: bytes.length));
  }

  // 1×1 PNG
  const png = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0, 0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
  ];
  await media('photo_1', 'note_photo.jpg', png, 'photo', 'n1');
  await media('chatfile_img', '板书 照片.png', png, 'chat_file', 'sc1');
  await media('chatfile_txt', '习题课讲义.txt', '第一题：已知 P(B)=0.5 ……'.codeUnits, 'chat_file', 'sc1');

  await repo.saveKps([
    KnowledgePoint(id: 'k1', projectId: 'p1', docId: 'd1', chapter: '第一章 随机事件与概率', title: '条件概率',
        content: r'设 $P(B)>0$，称 $P(A\mid B)=\dfrac{P(AB)}{P(B)}$ 为条件概率。', page: 12),
  ]);
  await repo.saveNote(StudyNote(
    id: 'n1',
    projectId: 'p1',
    kpId: 'k1',
    chapter: '第一章 随机事件与概率',
    title: r'条件概率: $P(A|B)$ 怎么理解?',
    own: r'把样本空间缩小到 $B$ 上重新算比例：' '\n\n' r'$$P(A\mid B)=\frac{P(AB)}{P(B)}$$',
    ai: r'**要点**：先确认 $P(B)>0$。',
    aiSources: WebSource.encode([const WebSource(url: 'https://zh.wikipedia.org/wiki/条件概率', title: '条件概率 - 维基百科')]),
    quotes: [NoteQuote(docId: 'd1', page: 12, text: '称 P(A|B) 为在事件 B 发生的条件下事件 A 发生的条件概率。')],
    questionIds: ['q1'],
    photoIds: ['photo_1', 'photo_missing'],
    createdAt: now,
  ));
  await repo.saveStudyChat(StudyChat(
    id: 'sc1',
    projectId: 'p1',
    title: '全概率公式和贝叶斯的区别',
    scope: [MaterialRef(docId: 'd1', chapter: '第一章 随机事件与概率')],
    attachments: [
      ChatAttachment(id: 'chatfile_img', name: '板书 照片.png', kind: 'image', size: png.length),
      ChatAttachment(id: 'chatfile_txt', name: '习题课讲义.txt', kind: 'txt', size: 20),
    ],
    messages: [
      {'role': 'user', 'content': '全概率公式和贝叶斯公式有什么区别？'},
      {
        'role': 'assistant',
        'content': r'全概率公式由因求果：$P(A)=\sum_i P(B_i)P(A\mid B_i)$；贝叶斯公式执果索因。',
        'sources': WebSource.encode([const WebSource(url: 'https://example.com/bayes', title: '贝叶斯公式')]),
      },
    ],
    createdAt: now,
  ));
  await repo.saveExplain(ExplainCache(id: 'q1', projectId: 'p2', kind: 'question', title: '下列哪个是一阶线性微分方程？', messages: [
    {'role': 'user', 'content': 'prompt'},
    {'role': 'assistant', 'content': r"标准形式是 $y'+p(x)y=q(x)$。"},
    {'role': 'user', 'content': r"为什么 $y'+y^2=0$ 不是？"},
    {'role': 'assistant', 'content': r'因为含有 $y^2$，不是线性的。'},
  ], createdAt: now));
  await repo.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'kp', targetId: 'k1', title: '条件概率', createdAt: now));
  await repo.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'card', targetId: 'c0', title: '什么是条件概率？', createdAt: now));
  await repo.saveFavorite(FavoriteItem(projectId: 'p1', kind: 'question', targetId: 'gone', title: '已删除的题', createdAt: now));
  await repo.saveWrong(WrongEntry(id: 'q1', projectId: 'p2', questionId: 'q1', mark: '答错', lastAnswer: 'A', addedAt: now));
  await repo.saveWrong(WrongEntry(id: 'card_c1', projectId: 'p1', cardId: 'c1', mark: '不确定', lastAnswer: '记不清, "大概"是乘法', addedAt: now));
  return files;
}
