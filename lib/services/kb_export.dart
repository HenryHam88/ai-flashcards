import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../data/repository.dart';
import '../models.dart';
import 'llm.dart' show WebSource;

/// 导出到 Obsidian / Notion 时要包含哪些内容。
class KbExportOptions {
  final bool notes, studyChats, explains, favorites, wrong;
  /// null = 全部项目。
  final String? projectId;
  const KbExportOptions(
      {this.notes = true, this.studyChats = true, this.explains = true, this.favorites = true, this.wrong = true, this.projectId});
  bool get any => notes || studyChats || explains || favorites || wrong;
}

/// 各类内容的数量（导出面板上显示）。
class KbCounts {
  final int notes, studyChats, explains, favorites, wrong;
  const KbCounts({this.notes = 0, this.studyChats = 0, this.explains = 0, this.favorites = 0, this.wrong = 0});
}

/// 导出结果。
class KbExportResult {
  final Uint8List bytes;
  final String fileName;
  /// 压缩包里的文件路径（测试和提示用）。
  final List<String> paths;
  /// 没能放进压缩包的照片 / 附件（文件不在本机、下载失败）。
  final int missingFiles;
  const KbExportResult(this.bytes, this.fileName, this.paths, this.missingFiles);
}

/// 把笔记、AI 伴学和 AI 解释的对话、收藏、错题导出成 Markdown 压缩包：
/// Obsidian 解压进笔记库即可，Notion 用「导入 → ZIP」。
///
/// 只用最普通的 Markdown（标题、列表、粗体、引用、图片链接），不用 Obsidian 专有的 callout / [[双链]]，
/// 两边都能正常显示。每个文件开头有 YAML 属性（Obsidian 识别），正文里再写一份可见的信息列表（Notion 不识别 YAML）。
/// 文件名带上由 id 算出的短后缀，重复导出时同一条内容的文件名不变，覆盖即可，不会出现重复副本。
class KbExportService {
  final Repository repo;
  /// 照片 / 伴学附件的本机文件（放到云端的会自动下载）；找不到返回 null。
  final Future<File?> Function(String mediaId) media;
  final DateTime Function() now;
  KbExportService({required this.repo, required this.media, DateTime Function()? now}) : now = now ?? DateTime.now;

  static const attachDir = '附件';

  Future<KbCounts> counts({String? projectId}) async {
    final projects = projectId == null ? [for (final p in await repo.projects()) p.id] : [projectId];
    var chats = 0;
    for (final id in projects) {
      chats += (await repo.studyChats(id)).where((c) => c.messages.isNotEmpty).length;
    }
    return KbCounts(
      notes: (await repo.notes(projectId: projectId)).where((n) => !n.isEmpty).length,
      studyChats: chats,
      explains: (await repo.explainHistory(projectId: projectId)).where((e) => e.messages.length > 1).length,
      favorites: (await repo.favorites(projectId: projectId)).length,
      wrong: (await repo.wrong(projectId: projectId)).length,
    );
  }

  Future<KbExportResult> export(KbExportOptions o) async {
    final t = now();
    final allProjects = await repo.projects();
    final projects = o.projectId == null ? allProjects : allProjects.where((p) => p.id == o.projectId).toList();
    final projectNames = {for (final p in allProjects) p.id: p.name};
    final folders = _projectFolders(allProjects);
    final single = o.projectId != null && projects.isNotEmpty ? projects.first.name : null;
    final root = sanitizeName(single == null ? '闪卡刷题导出-${_date(t)}' : '闪卡刷题导出-$single-${_date(t)}', max: 60);
    final w = _Writer(root, media);
    final docNames = <String, String>{};
    for (final p in projects) {
      for (final d in await repo.docs(p.id)) {
        docNames[d.id] = d.name;
      }
    }
    String folder(String projectId) => folders[projectId] ?? '其他';

    if (o.notes) {
      for (final n in await repo.notes(projectId: o.projectId)) {
        if (n.isEmpty) continue;
        final kp = n.kpId.isEmpty ? null : await repo.kp(n.kpId);
        final title = _firstNonEmpty([n.title, kp?.title ?? '', '笔记']);
        final path = '笔记/${folder(n.projectId)}/${fileNameFor(title, n.id)}';
        final b = _Doc(w, path);
        b.front({
          'title': title,
          'type': '笔记',
          'project': projectNames[n.projectId] ?? '',
          if (n.chapter.isNotEmpty) 'chapter': n.chapter,
          if (kp != null) 'knowledge_point': kp.title,
          'created': _iso(n.createdAt),
          'updated': _iso(n.updatedAt),
          'tags': ['闪卡刷题', '笔记'],
          'id': n.id,
        });
        b.h1(title);
        b.meta([
          ('项目', projectNames[n.projectId] ?? ''),
          ('章节', n.chapter),
          ('知识点', kp?.title ?? ''),
          ('更新时间', _human(n.updatedAt)),
        ]);
        if (kp != null && kp.content.trim().isNotEmpty) b.section('知识点', kp.content);
        if (n.own.trim().isNotEmpty) b.section('我的理解', n.own);
        if (n.ai.trim().isNotEmpty) b.section('AI 讲解', n.ai);
        b.sources(WebSource.decode(n.aiSources));
        if (n.quotes.isNotEmpty) {
          b.h2('原文引用');
          for (final q in n.quotes) {
            final where = [docNames[q.docId] ?? '', if (q.page > 0) '第 ${q.page} 页'].where((x) => x.isNotEmpty).join(' · ');
            b.quote(q.text, where);
          }
        }
        final qs = [for (final id in n.questionIds) ?await repo.question(id)];
        if (qs.isNotEmpty) {
          b.h2('相关题目');
          for (var i = 0; i < qs.length; i++) {
            b.h3('第 ${i + 1} 题');
            b.question(qs[i]);
          }
        }
        if (n.photoIds.isNotEmpty) {
          b.h2('照片');
          for (var i = 0; i < n.photoIds.length; i++) {
            await b.image(n.photoIds[i], '照片 ${i + 1}');
          }
        }
        b.close();
      }
    }

    if (o.studyChats) {
      for (final p in projects) {
        for (final c in await repo.studyChats(p.id)) {
          if (c.messages.isEmpty) continue;
          final title = _firstNonEmpty([c.title, _preview(c.messages.first['content'] ?? ''), 'AI 伴学对话']);
          final path = 'AI伴学/${folder(c.projectId)}/${fileNameFor(title, c.id)}';
          final b = _Doc(w, path);
          final scope = [for (final r in c.scope) _scopeLabel(r, docNames)].where((x) => x.isNotEmpty).toList();
          b.front({
            'title': title,
            'type': 'AI 伴学',
            'project': p.name,
            if (scope.isNotEmpty) 'materials': scope,
            'created': _iso(c.createdAt),
            'updated': _iso(c.updatedAt),
            'tags': ['闪卡刷题', 'AI伴学'],
            'id': c.id,
          });
          b.h1(title);
          b.meta([
            ('项目', p.name),
            ('资料范围', scope.join('；')),
            ('对话时间', _human(c.createdAt)),
            ('更新时间', _human(c.updatedAt)),
          ]);
          if (c.attachments.isNotEmpty) {
            b.h2('附件');
            for (final a in c.attachments) {
              if (a.isImage) {
                await b.image(a.id, a.name);
              } else {
                await b.fileLink(a.id, a.name);
              }
            }
            b.blank();
          }
          b.chat(c.messages, ai: 'AI 伴学');
          b.close();
        }
      }
    }

    if (o.explains) {
      for (final e in await repo.explainHistory(projectId: o.projectId)) {
        if (e.messages.length <= 1) continue;
        var card = e.kind == 'card' ? await repo.card(e.id) : null;
        final q = e.kind != 'card' ? await repo.question(e.id) : null;
        if (card == null && q == null && e.kind.isEmpty) card = await repo.card(e.id);
        final title = _firstNonEmpty([_preview(e.title), _preview(card?.front ?? q?.stem ?? ''), 'AI 解释']);
        final path = 'AI解释/${folder(e.projectId)}/${fileNameFor(title, e.id)}';
        final b = _Doc(w, path);
        b.front({
          'title': title,
          'type': 'AI 解释',
          'project': projectNames[e.projectId] ?? '',
          'source': e.kind == 'card' ? '闪卡' : '题目',
          'created': _iso(e.createdAt),
          'updated': _iso(e.updatedAt),
          'tags': ['闪卡刷题', 'AI解释'],
          'id': e.id,
        });
        b.h1(title);
        b.meta([
          ('项目', projectNames[e.projectId] ?? ''),
          ('来源', e.kind == 'card' ? '闪卡' : '题目'),
          ('追问', e.followUps > 0 ? '${e.followUps} 次' : ''),
          ('更新时间', _human(e.updatedAt)),
        ]);
        if (card != null) {
          b.h2('闪卡');
          b.card(card);
        } else if (q != null) {
          b.h2('题目');
          b.question(q);
        }
        b.chat(e.messages.skip(1).toList(), ai: 'AI 解释');
        b.close();
      }
    }

    if (o.favorites) {
      for (final f in await repo.favorites(projectId: o.projectId)) {
        final kind = FavoriteItem.kindNames[f.kind] ?? '收藏';
        final kp = f.kind == 'kp' ? await repo.kp(f.targetId) : null;
        final card = f.kind == 'card' ? await repo.card(f.targetId) : null;
        final q = f.kind == 'question' ? await repo.question(f.targetId) : null;
        final title = _firstNonEmpty([_preview(f.title), _preview(kp?.title ?? card?.front ?? q?.stem ?? ''), kind]);
        final path = '收藏/${folder(f.projectId)}/$kind/${fileNameFor(title, f.id)}';
        final b = _Doc(w, path);
        b.front({
          'title': title,
          'type': '收藏·$kind',
          'project': projectNames[f.projectId] ?? '',
          if ((kp?.chapter ?? card?.chapter ?? q?.chapter ?? '').isNotEmpty) 'chapter': kp?.chapter ?? card?.chapter ?? q?.chapter,
          'created': _iso(f.createdAt),
          'tags': ['闪卡刷题', '收藏'],
          'id': f.id,
        });
        b.h1(title);
        b.meta([
          ('项目', projectNames[f.projectId] ?? ''),
          ('类型', kind),
          ('章节', kp?.chapter ?? card?.chapter ?? q?.chapter ?? ''),
          ('收藏时间', _human(f.createdAt)),
        ]);
        if (kp != null) {
          b.text(kp.content);
          if (kp.page > 0) b.text('（${docNames[kp.docId] ?? '教材'} 第 ${kp.page} 页）');
        } else if (card != null) {
          b.card(card);
        } else if (q != null) {
          b.question(q);
        } else {
          b.text('（原内容已删除，只保留收藏时的标题）');
        }
        b.close();
      }
    }

    if (o.wrong) {
      final rows = <List<String>>[
        ['题目', '项目', '章节', '题型', '选项', '正确答案', '我的答案', '解析', '标记', '连续答对', '加入时间', '页码', 'ID'],
      ];
      for (final e in await repo.wrong(projectId: o.projectId)) {
        final q = e.questionId.isNotEmpty ? await repo.question(e.questionId) : null;
        final card = q == null && e.cardId.isNotEmpty ? await repo.card(e.cardId) : null;
        if (q == null && card == null) continue;
        final stem = q?.stem ?? card!.front;
        final title = _firstNonEmpty([_preview(stem), '错题']);
        final path = '错题/${folder(e.projectId)}/${fileNameFor(title, e.id)}';
        final b = _Doc(w, path);
        final chapter = q?.chapter ?? card?.chapter ?? '';
        b.front({
          'title': title,
          'type': '错题',
          'project': projectNames[e.projectId] ?? '',
          if (chapter.isNotEmpty) 'chapter': chapter,
          'question_type': q?.type ?? '闪卡',
          'mark': e.mark,
          'streak': e.streak,
          'created': _iso(e.addedAt),
          'tags': ['闪卡刷题', '错题'],
          'id': e.id,
        });
        b.h1(title);
        b.meta([
          ('项目', projectNames[e.projectId] ?? ''),
          ('章节', chapter),
          ('题型', q?.type ?? '闪卡'),
          ('标记', e.mark),
          ('连续答对', '${e.streak} 次'),
          ('加入时间', _human(e.addedAt)),
        ]);
        if (q != null) {
          b.question(q, lastAnswer: e.lastAnswer);
        } else {
          b.card(card!);
          if (e.lastAnswer.trim().isNotEmpty) b.section('我的答案', e.lastAnswer, level: 0);
        }
        b.close();
        rows.add([
          stem,
          projectNames[e.projectId] ?? '',
          chapter,
          q?.type ?? '闪卡',
          q == null ? '' : [for (var i = 0; i < q.options.length; i++) '${_letter(i)}. ${q.options[i]}'].join('\n'),
          q?.answer ?? card!.back,
          e.lastAnswer,
          q?.explanation ?? card!.explanation,
          e.mark,
          '${e.streak}',
          _human(e.addedAt),
          '${q?.page ?? card!.page}',
          e.id,
        ]);
      }
      if (rows.length > 1) w.addText('错题/错题.csv', '\uFEFF${toCsv(rows)}');
    }

    w.addText('使用说明.md', _readme(o, t, single));
    final archive = Archive();
    for (final e in w.files.entries) {
      archive.addFile(ArchiveFile.bytes('$root/${e.key}', e.value));
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    return KbExportResult(bytes, '$root.zip', [for (final k in w.files.keys) '$root/$k'], w.missing);
  }

  // ---------------------------------------------------------------- 工具

  /// 项目文件夹名：同名项目加短后缀区分。
  static Map<String, String> _projectFolders(List<Project> ps) {
    final out = <String, String>{};
    final used = <String>{};
    for (final p in ps) {
      var n = sanitizeName(p.name, max: 40);
      if (used.contains(n)) n = '$n-${shortId(p.id)}';
      used.add(n);
      out[p.id] = n;
    }
    return out;
  }

  /// 由 id 算出的 6 位短后缀：同一条内容每次导出都一样。
  static String shortId(String id) => sha1.convert(utf8.encode(id)).toString().substring(0, 6);

  /// 笔记文件名：「标题-短后缀.md」。
  static String fileNameFor(String title, String id) => '${sanitizeName(title)}-${shortId(id)}.md';

  static final _bad = RegExp(r'[\\/:*?"<>|#^\[\]$`{}\u0000-\u001f\u007f]');
  static const _reserved = {'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'LPT1', 'LPT2', 'LPT3'};

  /// 文件 / 文件夹名清理：去掉 Windows、安卓、Obsidian 链接不允许的字符和公式符号，压缩空白，截到 [max] 个字。
  static String sanitizeName(String s, {int max = 50}) {
    var t = s.replaceAll(RegExp(r'\\[a-zA-Z]+'), ' ').replaceAll(_bad, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = t.runes.toList();
    if (runes.length > max) t = String.fromCharCodes(runes.take(max)).trim();
    t = t.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    if (t.isEmpty) return '未命名';
    if (_reserved.contains(t.toUpperCase())) t = '_$t';
    return t;
  }

  /// CSV（RFC 4180）：含逗号、引号、换行的字段加引号，引号写两次；行尾 CRLF。
  static String toCsv(List<List<String>> rows) => '${rows.map((r) => r.map(csvField).join(',')).join('\r\n')}\r\n';
  static String csvField(String v) =>
      v.contains(RegExp('[",\r\n]')) || v.startsWith(' ') || v.endsWith(' ') ? '"${v.replaceAll('"', '""')}"' : v;

  static String _letter(int i) => String.fromCharCode(65 + i);
  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _date(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';
  static String _iso(DateTime t) => '${_date(t)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  static String _human(DateTime t) => '${_date(t)} ${_two(t.hour)}:${_two(t.minute)}';
  static String _firstNonEmpty(List<String> l) => l.firstWhere((x) => x.trim().isNotEmpty, orElse: () => '').trim();

  /// 标题预览：去掉公式、Markdown 符号和换行，截到 40 个字。
  static String _preview(String s) {
    var t = s.replaceAll(RegExp(r'\$\$[\s\S]*?\$\$|\$[^$\n]*\$'), ' 公式 ').replaceAll(RegExp(r'[*#>`_]+'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    final r = t.runes.toList();
    return r.length > 40 ? '${String.fromCharCodes(r.take(40))}…' : t;
  }

  static String _scopeLabel(MaterialRef r, Map<String, String> docNames) {
    final d = docNames[r.docId] ?? '';
    if (r.chapter.isNotEmpty) return [d, r.chapter].where((x) => x.isNotEmpty).join(' · ');
    if (r.pageFrom > 0) return '$d 第 ${r.pageFrom}–${r.pageTo} 页'.trim();
    return d;
  }

  String _readme(KbExportOptions o, DateTime t, String? single) {
    final parts = [
      if (o.notes) '笔记',
      if (o.studyChats) 'AI伴学',
      if (o.explains) 'AI解释',
      if (o.favorites) '收藏',
      if (o.wrong) '错题',
    ];
    return '''# 闪卡刷题导出

导出时间：${_human(t)}
范围：${single ?? '全部项目'}
包含：${parts.join('、')}

每条内容是一个 Markdown 文件，按「类型 / 项目」分文件夹；照片和伴学附件在「$attachDir」文件夹里，笔记里用相对路径引用，整个文件夹一起移动就不会丢图。

## 导入 Obsidian

1. 解压这个压缩包。
2. 把解压出来的文件夹整个放进你的 Obsidian 笔记库（库文件夹里任意位置）。
3. 公式（\$…\$ 和 \$\$…\$\$）、图片、标签和文件开头的属性都能直接显示。

以后再导出一次，把新文件夹覆盖旧的即可：同一条内容的文件名保持不变（文件名末尾的 6 位字符由内容编号算出）。

## 导入 Notion

1. 在电脑上打开 Notion（手机版不能导入）。
2. 左侧「设置」→「导入」→ 选「ZIP」或「Text & Markdown」，选择这个压缩包（不用解压）。
3. 想把错题做成表格（可以按项目、标记筛选），另外用「导入 → CSV」选择「错题/错题.csv」。

注意：

- 每个文件开头 --- 之间的属性是给 Obsidian 用的，Notion 会把它显示成普通文字，可以直接删掉；同样的信息在标题下面也列了一份。
- Notion 导入时，行内公式 \$…\$ 可能显示成普通文字。需要时在 Notion 里选中公式文字，按 Ctrl/Cmd + Shift + E 转成公式；独立成行的 \$\$…\$\$ 一般能直接识别。
- Notion 免费版单个文件最大 5 MB；附件很多时可以分几次导出（选单个项目）。
''';
  }
}

/// 收集压缩包里的文件；附件去重。
class _Writer {
  final String root;
  final Future<File?> Function(String) media;
  final Map<String, Uint8List> files = {};
  final Map<String, String?> _attached = {}; // mediaId → 附件路径（null = 找不到文件）
  int missing = 0;
  _Writer(this.root, this.media);

  void addText(String path, String text) => files[path] = Uint8List.fromList(utf8.encode(text));

  /// 把附件放进「附件/」，返回压缩包内路径；文件不在时返回 null。
  Future<String?> attach(String mediaId, String name) async {
    if (_attached.containsKey(mediaId)) return _attached[mediaId];
    File? f;
    try {
      f = await media(mediaId);
    } catch (_) {
      f = null;
    }
    if (f == null || !await f.exists()) {
      missing++;
      return _attached[mediaId] = null;
    }
    final base = name.trim().isEmpty ? f.uri.pathSegments.last : name;
    final dot = base.lastIndexOf('.');
    var ext = dot > 0 ? base.substring(dot + 1).toLowerCase() : '';
    if (ext.isEmpty || ext.length > 5) {
      final fp = f.path, fd = fp.lastIndexOf('.');
      ext = fd > 0 ? fp.substring(fd + 1).toLowerCase() : 'bin';
    }
    final stem = KbExportService.sanitizeName(dot > 0 ? base.substring(0, dot) : base, max: 30).replaceAll(' ', '_');
    final path = '${KbExportService.attachDir}/$stem-${KbExportService.shortId(mediaId)}.$ext';
    files[path] = await f.readAsBytes();
    return _attached[mediaId] = path;
  }
}

/// 一个 Markdown 文件。
class _Doc {
  final _Writer w;
  final String path;
  final b = StringBuffer();
  _Doc(this.w, this.path);

  /// 从这个文件到压缩包根目录的相对前缀，如「../../」。
  String get _up => '../' * (path.split('/').length - 1);

  /// 链接地址：每段做 URL 编码（空格、中文都安全），Obsidian 和 Notion 都能识别。
  String _link(String zipPath) => _up + zipPath.split('/').map(Uri.encodeComponent).join('/');

  void front(Map<String, Object?> m) {
    b.writeln('---');
    for (final e in m.entries) {
      final v = e.value;
      if (v == null) continue;
      if (v is List) {
        b.writeln('${e.key}:');
        for (final x in v) {
          b.writeln('  - ${_yaml('$x')}');
        }
      } else if (v is num) {
        b.writeln('${e.key}: $v');
      } else {
        b.writeln('${e.key}: ${_yaml('$v')}');
      }
    }
    b.writeln('---');
    b.writeln();
  }

  static String _yaml(String s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll(RegExp(r'[\r\n\t]+'), ' ')}"';

  void h1(String t) => b.write('# ${_oneLine(t)}\n\n');
  void h2(String t) => b.write('## $t\n\n');
  void h3(String t) => b.write('### $t\n\n');
  void blank() => b.writeln();
  void text(String t) {
    if (t.trim().isEmpty) return;
    b.write('${t.trim()}\n\n');
  }

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 标题下面可见的信息列表（空值跳过）。
  void meta(List<(String, String)> items) {
    final l = items.where((e) => e.$2.trim().isNotEmpty).toList();
    if (l.isEmpty) return;
    for (final e in l) {
      b.writeln('- ${e.$1}：${_oneLine(e.$2)}');
    }
    b.writeln();
  }

  /// level 0 = 粗体小标题（**问题** 这种），2 = 二级标题。
  void section(String title, String body, {int level = 2}) {
    if (level == 0) {
      b.write('**$title**\n\n');
    } else {
      h2(title);
    }
    text(body);
  }

  void quote(String text, String where) {
    for (final line in text.trim().split('\n')) {
      b.writeln(line.trim().isEmpty ? '>' : '> $line');
    }
    if (where.isNotEmpty) b.writeln('>\n> —— $where');
    b.writeln();
  }

  void sources(List<WebSource> l) {
    if (l.isEmpty) return;
    b.write('**参考网页**\n\n');
    for (var i = 0; i < l.length; i++) {
      b.writeln('${i + 1}. [${l[i].label.replaceAll(RegExp(r'[\[\]]'), '')}](${l[i].url})');
    }
    b.writeln();
  }

  void question(Question q, {String lastAnswer = ''}) {
    section('问题', q.stem, level: 0);
    if (q.options.isNotEmpty) {
      for (var i = 0; i < q.options.length; i++) {
        b.writeln('- ${String.fromCharCode(65 + i)}. ${_oneLine(q.options[i])}');
      }
      b.writeln();
    }
    section('答案', q.answer.replaceAll('|', ' / '), level: 0);
    if (lastAnswer.trim().isNotEmpty) section('我的答案', lastAnswer, level: 0);
    if (q.explanation.trim().isNotEmpty) section('解析', q.explanation, level: 0);
  }

  void card(Flashcard c) {
    section('问题', c.front, level: 0);
    section('答案', c.back, level: 0);
    if (c.explanation.trim().isNotEmpty) section('解析', c.explanation, level: 0);
  }

  void chat(List<Map<String, String>> msgs, {required String ai}) {
    b.write('## 对话\n\n');
    for (final m in msgs) {
      final content = (m['content'] ?? '').trim();
      if (content.isEmpty) continue;
      final user = m['role'] == 'user';
      b.write('### ${user ? '我' : ai}\n\n');
      text(content);
      if (!user) sources(WebSource.decode(m['sources']));
    }
  }

  Future<void> image(String mediaId, String alt) async {
    final p = await w.attach(mediaId, alt);
    final a = alt.replaceAll(RegExp(r'[\[\]]'), '');
    b.write(p == null ? '（$a 未能导出：文件不在本机）\n\n' : '![$a](${_link(p)})\n\n');
  }

  Future<void> fileLink(String mediaId, String name) async {
    final p = await w.attach(mediaId, name);
    final a = name.replaceAll(RegExp(r'[\[\]]'), '');
    b.write(p == null ? '- $a（未能导出：文件不在本机）\n' : '- [$a](${_link(p)})\n');
  }

  void close() => w.addText(path, '${b.toString().trimRight()}\n');
}
