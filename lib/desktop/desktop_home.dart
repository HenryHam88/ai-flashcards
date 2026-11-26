import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/study_queue.dart';
import '../theme/glass.dart';
import '../ui/due_page.dart';
import '../ui/home_page.dart' show HomeData, loadHomeData, createProjectDialog;
import '../ui/project_page.dart';
import '../ui/review_page.dart';
import 'desktop_shell.dart';
import 'platform.dart';

/// 桌面版「今日」：数字卡片 + 两列项目 + 常用入口。内容和手机首页一样，排版适合宽屏。
class DesktopHome extends StatelessWidget {
  const DesktopHome({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final shell = DesktopShell.of(context);
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    return DeskPane(
      max: 1080,
      child: FutureBuilder<HomeData>(
        key: ValueKey(s.version),
        future: loadHomeData(s),
        builder: (context, snap) {
          final d = snap.data;
          final c = d?.counts;
          final session = s.settings.reviewSession;
          final projects = d?.projects ?? const <(Project, int, int, String)>[];
          Future<void> upload() async {
            if (projects.isEmpty) return createProjectDialog(context);
            push(ProjectPage(projectId: projects.first.$1.id, autoUpload: true));
          }

          final newLine = c == null
              ? ''
              : c.newCap == 0
                  ? '新卡不限量'
                  : '新卡还剩 ${(c.newCap - c.newDone).clamp(0, 99999)} 张额度';
          return ListView(padding: const EdgeInsets.fromLTRB(28, 24, 28, 28), children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('今日计划 · 保持节奏，稳步前进', style: TextStyle(color: M.sub, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text('今日复习', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: M.text)),
                  if (c != null) ...[
                    const SizedBox(height: 4),
                    Text(c.due > 0 ? '$newLine · 建议先复习到期的 ${c.due} 张' : newLine,
                        style: TextStyle(color: M.sub, fontSize: 13.5)),
                  ],
                ]),
              ),
              GlassButton(label: '上传资料', icon: Icons.cloud_upload_outlined, onTap: upload),
              const SizedBox(width: 10),
              GlassButton(
                label: session == null ? '开始学习' : '继续 ${(session['index'] as int) + 1}/${(session['ids'] as List).length}',
                icon: Icons.play_arrow_rounded,
                tint: M.sage,
                onTap: session != null
                    ? () => push(ReviewPage(projectId: session['projectId'] as String?, resume: true))
                    : (c == null || c.newAvailable + c.due == 0 ? null : () => push(const ReviewPage())),
              ),
            ]),
            const SizedBox(height: 18),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: _Stat(
                  label: '今日新学',
                  value: '${c?.newAvailable ?? 0}',
                  unit: '张可学',
                  hint: c == null || c.newCap == 0 ? '学新卡' : '今天已学 ${c.newDone} / ${c.newCap}',
                  progress: c == null || c.newCap == 0 ? null : (c.newDone / c.newCap).clamp(0.0, 1.0),
                  onTap: (c?.newAvailable ?? 0) == 0 ? null : () => push(const ReviewPage(mode: StudyMode.newOnly)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Stat(
                  label: '待复习',
                  value: '${c?.due ?? 0}',
                  unit: '张到期',
                  rose: true,
                  hint: '先复习，再学新卡',
                  onTap: (c?.due ?? 0) == 0 ? null : () => push(const ReviewPage(mode: StudyMode.reviewOnly)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Stat(
                  label: '今日已复习',
                  value: '${d?.reviewedToday ?? 0}',
                  unit: '张',
                  hint: '查看到期安排',
                  onTap: () => push(const DueByDayPage()),
                ),
              ),
            ]),
            SectionTitle('我的项目', trailing: Text('共 ${projects.length} 个', style: TextStyle(color: M.sub, fontSize: 13))),
            if (d != null && projects.isEmpty)
              Glass(child: Text('还没有项目，点「新建项目」开始，例如「概率论」。', style: TextStyle(color: M.sub))),
            DeskGrid(children: [
              for (final (p, nc, nq, ch) in projects)
                Glass(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  onTap: () => shell?.go(DeskSection.project, project: p.id),
                  child: Row(children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(color: M.greyBlue.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(12)),
                      child: Icon(Icons.menu_book_rounded, color: M.text, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('$nc 张卡片 · $nq 道题${ch.isEmpty ? '' : ' · $ch'}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: M.sub, fontSize: 12)),
                      ]),
                    ),
                    Icon(Icons.chevron_right_rounded, color: M.sub),
                  ]),
                ),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: [
              _Chip(Icons.create_new_folder_outlined, '新建项目', () => createProjectDialog(context)),
              _Chip(Icons.cloud_upload_outlined, '上传资料', upload),
              _Chip(Icons.account_tree_outlined, '学习板块', () => shell?.go(DeskSection.study)),
              _Chip(Icons.edit_note_rounded, '笔记', () => shell?.go(DeskSection.notes)),
              _Chip(Icons.star_outline_rounded, '收藏', () => shell?.go(DeskSection.favorites)),
            ]),
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 8),
              child: Text('支持 PDF / Word / TXT 自动解析与生成卡片', style: TextStyle(color: M.sub, fontSize: 12)),
            ),
            const SizedBox(height: 28),
            Wrap(spacing: 16, runSpacing: 8, children: [
              _Key('${Desk.mod} 1', '今日'),
              _Key('${Desk.mod} 2', '复习'),
              _Key('${Desk.mod} K', '搜索'),
              const _Key('空格', '翻面 / 记住了'),
              const _Key('1–4', '评分'),
              _Key('${Desk.mod} ,', '设置'),
            ]),
          ]);
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value, unit, hint;
  final bool rose;
  final double? progress;
  final VoidCallback? onTap;
  const _Stat({required this.label, required this.value, required this.unit, required this.hint, this.rose = false, this.progress, this.onTap});
  @override
  Widget build(BuildContext context) => Glass(
        radius: 20,
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: M.sub, fontSize: 13)),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(value, style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: rose ? M.roseDark : M.text, height: 1.1)),
            const SizedBox(width: 6),
            Text(unit, style: TextStyle(color: M.sub, fontSize: 14)),
          ]),
          if (progress != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: progress, minHeight: 6, color: M.sage, backgroundColor: M.mist.withValues(alpha: 0.7)),
            ),
          ],
          const SizedBox(height: 6),
          Text(hint, style: TextStyle(color: onTap == null ? M.sub : M.sageDark, fontSize: 12)),
        ]),
      );
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Chip(this.icon, this.label, this.onTap);
  @override
  Widget build(BuildContext context) => Glass(
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        onTap: onTap,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: M.sageDark),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _Key extends StatelessWidget {
  final String keys, label;
  const _Key(this.keys, this.label);
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        KeyCap(keys),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: M.sub, fontSize: 12)),
      ]);
}
