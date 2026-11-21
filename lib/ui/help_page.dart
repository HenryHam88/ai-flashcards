import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../help/help_articles.dart';
import '../theme/glass.dart';

/// 打开使用帮助：不带 [articleId] 时进帮助首页，否则直接打开那篇文章。
Future<void> openHelp(BuildContext context, [String? articleId]) => Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => articleId == null ? const HelpHomePage() : HelpArticlePage(articleId: articleId)));

/// 小问号按钮：放在页面标题栏等处，点开对应的帮助文章。
class HelpButton extends StatelessWidget {
  final String articleId;
  final Color? color;
  const HelpButton(this.articleId, {super.key, this.color});
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: '使用帮助',
        icon: Icon(Icons.help_outline_rounded, color: color ?? M.sub),
        onPressed: () => openHelp(context, articleId),
      );
}

/// 密钥相关的错误（没填、无效、余额不足）。
bool isKeyError(String msg) => msg.contains('密钥') || msg.contains('（401）') || msg.contains('（402）');

/// 错误提示：密钥相关的错误多一个「怎么解决」，打开「配置 AI 模型和密钥」；其他错误和原来的提示一样。
void errorToast(BuildContext context, String msg) {
  if (!isKeyError(msg)) return toast(context, msg);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    behavior: SnackBarBehavior.floating,
    backgroundColor: M.text.withValues(alpha: 0.88),
    action: SnackBarAction(label: '怎么解决', textColor: M.sage, onPressed: () => openHelp(context, HelpIds.keys)),
  ));
}

const _issuesUrl = 'https://github.com/HenryHam88/ai-flashcards/issues/new/choose';

IconData helpCategoryIcon(String icon) => switch (icon) {
      'rocket' => Icons.rocket_launch_outlined,
      'make' => Icons.auto_awesome_outlined,
      'study' => Icons.style_outlined,
      'settings' => Icons.tune_rounded,
      _ => Icons.quiz_outlined,
    };

void copyQQ(BuildContext context) {
  Clipboard.setData(const ClipboardData(text: authorQQ));
  toast(context, '已复制 QQ 号');
}

/// 联系作者卡片：QQ 号（点按复制）+ 问题反馈。
class ContactCard extends StatelessWidget {
  const ContactCard({super.key});
  @override
  Widget build(BuildContext context) => Glass(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          ListTile(
            leading: Icon(Icons.chat_bubble_outline_rounded, color: M.sageDark),
            title: const Text('作者 QQ：$authorQQ', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('点按复制，使用问题、建议都可以联系', style: TextStyle(color: M.sub, fontSize: 12)),
            trailing: Icon(Icons.copy_rounded, size: 18, color: M.sub),
            onTap: () => copyQQ(context),
          ),
          ListTile(
            leading: Icon(Icons.feedback_outlined, color: M.sageDark),
            title: const Text('问题反馈', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('在 GitHub 提交 Bug 或功能建议', style: TextStyle(color: M.sub, fontSize: 12)),
            trailing: Icon(Icons.open_in_new_rounded, size: 18, color: M.sub),
            onTap: () => launchUrl(Uri.parse(_issuesUrl), mode: LaunchMode.externalApplication),
          ),
        ]),
      );
}

class HelpHomePage extends StatefulWidget {
  const HelpHomePage({super.key});
  @override
  State<HelpHomePage> createState() => _HelpHomePageState();
}

class _HelpHomePageState extends State<HelpHomePage> {
  final q = TextEditingController();

  @override
  void dispose() {
    q.dispose();
    super.dispose();
  }

  Widget _articleTile(HelpArticle a, {String? snippet}) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(a.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Text(snippet ?? a.summary,
            maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: M.sub, fontSize: 12, height: 1.4)),
        trailing: Icon(Icons.chevron_right_rounded, color: M.sub),
        onTap: () => openHelp(context, a.id),
      );

  @override
  Widget build(BuildContext context) {
    final query = q.text.trim();
    final hits = searchHelp(query);
    return GlassScaffold(
      title: '使用帮助',
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        TextField(
          controller: q,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(q.clear),
                  ),
            hintText: '搜索：密钥、章节、换手机…',
            filled: true,
            fillColor: M.glass.withValues(alpha: 0.6),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
          ),
        ),
        const SizedBox(height: 12),
        if (query.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(hits.isEmpty ? '没有找到相关内容，换个说法试试，或直接联系作者' : '找到 ${hits.length} 篇',
                style: TextStyle(color: M.sub, fontSize: 13)),
          ),
          if (hits.isNotEmpty)
            Glass(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [for (final h in hits) _articleTile(h.article, snippet: h.snippet)]),
            ),
        ] else ...[
          Glass(
            onTap: () => openHelp(context, HelpIds.quickStart),
            child: Row(children: [
              Icon(Icons.rocket_launch_rounded, color: M.sageDark, size: 30),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('第一次用？', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('3 分钟上手：填密钥、上传教材、生成、复习', style: TextStyle(color: M.sub, fontSize: 13)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: M.sub),
            ]),
          ),
          for (final c in helpCategories) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 18, 6, 8),
              child: Row(children: [
                Icon(helpCategoryIcon(c.icon), size: 18, color: M.sageDark),
                const SizedBox(width: 6),
                Text(c.title, style: TextStyle(color: M.sub, fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ),
            Glass(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (final a in helpArticles.where((a) => a.category == c.id)) _articleTile(a),
              ]),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 18, 6, 8),
            child: Row(children: [
              Icon(Icons.support_agent_rounded, size: 18, color: M.sageDark),
              const SizedBox(width: 6),
              Text('联系作者 / 反馈', style: TextStyle(color: M.sub, fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
          ),
          const ContactCard(),
        ],
      ]),
    );
  }
}

class HelpArticlePage extends StatelessWidget {
  final String articleId;
  const HelpArticlePage({super.key, required this.articleId});

  static final _special = RegExp(r'^\[\[(img:([^|\]]+)(?:\|([^\]]*))?|contact)\]\]$', multiLine: true);

  /// 把正文切成 Markdown 段落和特殊块（截图、联系卡片）。
  static List<Widget> renderBody(BuildContext context, String body) {
    final out = <Widget>[];
    var pos = 0;
    void md(String t) {
      if (t.trim().isEmpty) return;
      out.add(MathText(t.trim(), style: const TextStyle(fontSize: 15, height: 1.65)));
    }

    for (final m in _special.allMatches(body)) {
      md(body.substring(pos, m.start));
      if (m[1] == 'contact') {
        out.add(const ContactCard());
      } else {
        out.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  decoration: BoxDecoration(border: Border.all(color: M.line.withValues(alpha: 0.8))),
                  child: Image.asset('assets/help/${m[2]}', width: 220, fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const SizedBox()),
                ),
              ),
            ),
            if ((m[3] ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(m[3]!, style: TextStyle(color: M.sub, fontSize: 12)),
              ),
          ]),
        ));
      }
      pos = m.end;
    }
    md(body.substring(pos));
    return [
      for (var i = 0; i < out.length; i++) ...[if (i > 0) const SizedBox(height: 10), out[i]],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final a = helpArticle(articleId);
    if (a == null) {
      return GlassScaffold(title: '使用帮助', body: Center(child: Text('没有找到这篇帮助', style: TextStyle(color: M.sub))));
    }
    final i = helpArticles.indexOf(a);
    final prev = i > 0 ? helpArticles[i - 1] : null;
    final next = i < helpArticles.length - 1 ? helpArticles[i + 1] : null;
    final cat = helpCategories.firstWhere((c) => c.id == a.category);
    void go(HelpArticle t) =>
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => HelpArticlePage(articleId: t.id)));
    return GlassScaffold(
      title: '使用帮助',
      actions: [
        IconButton(
          tooltip: '帮助首页',
          icon: const Icon(Icons.menu_book_outlined),
          onPressed: () => Navigator.of(context)
              .pushReplacement(MaterialPageRoute(builder: (_) => const HelpHomePage())),
        ),
      ],
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        Text(cat.title, style: TextStyle(color: M.sageDark, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(a.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.3)),
        const SizedBox(height: 4),
        Text(a.summary, style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
        const SizedBox(height: 14),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: renderBody(context, a.body)),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: prev == null
                ? const SizedBox()
                : _nav(context, '上一篇', prev.title, Icons.chevron_left_rounded, () => go(prev), alignEnd: false),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: next == null
                ? const SizedBox()
                : _nav(context, '下一篇', next.title, Icons.chevron_right_rounded, () => go(next), alignEnd: true),
          ),
        ]),
      ]),
    );
  }

  Widget _nav(BuildContext context, String label, String title, IconData icon, VoidCallback onTap,
          {required bool alignEnd}) =>
      Glass(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          if (!alignEnd) Icon(icon, color: M.sub),
          Expanded(
            child: Column(
                crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(color: M.sub, fontSize: 11)),
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ]),
          ),
          if (alignEnd) Icon(icon, color: M.sub),
        ]),
      );
}
