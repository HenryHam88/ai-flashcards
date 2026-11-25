import '../data/repository.dart';
import '../models.dart';
import 'json_utils.dart';
import 'latex.dart';
import 'llm.dart';
import 'prompts.dart';
import 'settings.dart';

/// 学习板块里的一章：来自已经解析好的资料和分章方案，不重复解析。
class StudyChapter {
  final PdfDoc doc;
  final ChapterRange range;
  final int kpCount;
  final int chars; // 本章原文字数
  final ChapterMindMap? map;
  StudyChapter(this.doc, this.range, {this.kpCount = 0, this.chars = 0, this.map});
  String get title => range.title;
  MaterialRef get ref => MaterialRef(docId: doc.id, chapter: range.title, pageFrom: range.start, pageTo: range.end);
}

/// 选中资料的原文（发给 AI 用）。
class StudyMaterial {
  final String text;
  final int chars; // 选中范围的原文总字数
  final bool truncated; // 超出预算，只发了一部分
  final int pages;
  const StudyMaterial(this.text, this.chars, this.truncated, this.pages);
}

class StudyService {
  final Repository repo;
  final Settings settings;
  StudyService(this.repo, this.settings);

  /// 发给 AI 的原文上限（字），超过时按页截断并提示用户缩小范围。
  static const budget = 24000;

  static bool parsed(PdfDoc d) => d.parsedPages > 0 || d.status == '已解析' || d.status == '部分失败';

  /// 项目里所有已解析资料的章节（没有分章方案的资料整份算一章；没有文字的章节跳过）。
  Future<List<StudyChapter>> chapters(String projectId) async {
    final docs = (await repo.docs(projectId)).where(parsed).toList();
    final kps = await repo.kps(projectId);
    final maps = {for (final m in await repo.mindMaps(projectId)) m.id: m};
    final out = <StudyChapter>[];
    for (final d in docs) {
      final pages = await repo.pages(projectId, docId: d.id);
      if (pages.isEmpty) continue;
      final plan = await repo.chapterPlan(d.id);
      final ranges = plan == null || plan.chapters.isEmpty
          ? [ChapterRange(d.name, pages.first.page, pages.last.page)]
          : plan.chapters;
      for (final r in ranges) {
        final chars = pages.where((p) => p.page >= r.start && p.page <= r.end).fold(0, (a, p) => a + p.text.length);
        if (chars == 0) continue; // 没有解析出文字的章节（如封面、目录）不显示
        final n = kps.where((k) => k.docId == d.id && (k.chapter == r.title || (k.chapter.isEmpty && k.page >= r.start && k.page <= r.end))).length;
        out.add(StudyChapter(d, r, kpCount: n, chars: chars, map: maps[ChapterMindMap.idFor(d.id, r.title)]));
      }
    }
    return out;
  }

  /// 读取选中范围的原文：直接用数据库里解析好的页面文字。
  Future<StudyMaterial> material(String projectId, List<MaterialRef> refs, {int limit = budget}) async {
    final b = StringBuffer();
    var total = 0, used = 0, pages = 0;
    var truncated = false;
    final docs = {for (final d in await repo.docs(projectId)) d.id: d};
    for (final r in refs) {
      final d = docs[r.docId];
      if (d == null) continue;
      final unit = d.isSectioned ? '节' : '页';
      for (final p in await repo.pages(projectId, docId: r.docId)) {
        if ((r.pageFrom > 0 && p.page < r.pageFrom) || (r.pageTo > 0 && p.page > r.pageTo)) continue;
        final t = p.text.trim();
        if (t.isEmpty) continue;
        total += t.length;
        pages++;
        if (used + t.length > limit) {
          truncated = true;
          continue;
        }
        used += t.length;
        b.writeln('【《${d.name}》第 ${p.page} $unit】');
        b.writeln(t);
        b.writeln();
      }
    }
    return StudyMaterial(b.toString().trim(), total, truncated, pages);
  }

  /// 资料范围的文字说明，如「概率论 · 第一章（第 1–20 页）」。
  Future<String> scopeLabel(String projectId, List<MaterialRef> refs) async {
    final docs = {for (final d in await repo.docs(projectId)) d.id: d};
    return refs.map((r) => refLabel(r, docs[r.docId])).join('；');
  }

  static String refLabel(MaterialRef r, PdfDoc? d) {
    final unit = d?.isSectioned == true ? '节' : '页';
    final pages = r.pageFrom > 0 ? (r.pageTo > r.pageFrom ? '第 ${r.pageFrom}–${r.pageTo} $unit' : '第 ${r.pageFrom} $unit') : '';
    final name = r.chapter.isNotEmpty ? r.chapter : (d?.name ?? '资料');
    return pages.isEmpty ? name : '$name（$pages）';
  }

  /// 生成一章的思维导图（只在用户点按钮时调用）。
  Future<ChapterMindMap> generateMindMap(LlmClient llm, StudyChapter c) async {
    final kps = (await repo.kps(c.doc.projectId))
        .where((k) => k.docId == c.doc.id && (k.chapter == c.title || (k.chapter.isEmpty && k.page >= c.range.start && k.page <= c.range.end)))
        .toList();
    final m = await material(c.doc.projectId, [c.ref], limit: kps.isEmpty ? 14000 : 6000);
    if (kps.isEmpty && m.text.isEmpty) throw LlmException('这一章没有解析出文字，无法生成导图');
    final kpText = kps.isEmpty
        ? '（本章还没有分析知识点，请直接根据原文整理）'
        : [for (var i = 0; i < kps.length; i++) '$i. ${kps[i].title}${kps[i].type.isEmpty ? '' : '（${kps[i].type}）'}：${kps[i].content}（第 ${kps[i].page} 页）'].join('\n');
    final prompt = Prompts.fill(settings.prompt('mindmap'), {'chapter': c.title, 'kps': kpText, 'text': m.text});
    final j = await llm.chatJson(prompt);
    final root = parseMindTree(j, c.title, kps);
    if (root.children.isEmpty) throw LlmException('AI 没有返回导图内容，请重试');
    final map = ChapterMindMap(projectId: c.doc.projectId, docId: c.doc.id, chapter: c.title, root: root);
    await repo.saveMindMap(map);
    return map;
  }

  /// 把模型返回的 JSON 变成节点树：限制层数和标题长度，修正公式，kp_index → 知识点 id。
  static MindNode parseMindTree(Map<String, dynamic> j, String chapter, List<KnowledgePoint> kps, {int maxDepth = 4}) {
    MindNode node(Map<String, dynamic> m, int depth) {
      var title = LatexUtil.autoFix('${m['title'] ?? m['text'] ?? ''}'.trim());
      final note = LatexUtil.autoFix('${m['note'] ?? ''}'.trim());
      final kpIndex = m.containsKey('kp_index') ? asInt(m['kp_index'], -1) : -1;
      final kp = kpIndex >= 0 && kpIndex < kps.length ? kps[kpIndex] : null;
      if (title.isEmpty) title = kp?.title ?? '';
      final page = asInt(m['page']) > 0 ? asInt(m['page']) : (kp?.page ?? 0);
      return MindNode(
        text: title,
        note: note,
        page: page,
        kpId: kp?.id ?? '',
        children: depth >= maxDepth
            ? []
            : [
                for (final c in listOfMaps(m['children']))
                  if ('${c['title'] ?? c['text'] ?? ''}'.trim().isNotEmpty || c['kp_index'] != null) node(c, depth + 1)
              ],
      );
    }

    final root = node(j, 1);
    root.text = chapter; // 根节点固定为章节名
    return root;
  }
}
