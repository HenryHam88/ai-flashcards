import 'package:material_ui/material_ui.dart';

import '../services/study_queue.dart';
import '../theme/glass.dart';
import 'due_page.dart';
import 'review_page.dart';

/// 新学 / 待复习 两个计数 + 今日新卡进度 + 三个学习入口（学新卡 / 复习 / 全部学习）。
/// 首页、复习页、项目页共用。
class StudyCountsCard extends StatelessWidget {
  final StudyCounts? counts;
  final String? projectId;
  final String title;

  /// 继续上次中断的学习（首页显示「继续 x/y」）。
  final String? resumeText;
  final VoidCallback? onResume;
  const StudyCountsCard({
    super.key,
    required this.counts,
    this.projectId,
    this.title = '今日学习',
    this.resumeText,
    this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final c = counts;
    void open(StudyMode m) => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReviewPage(projectId: projectId, mode: m),
      ),
    );
    Widget number(String label, int n, Color color) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: M.sub, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$n',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, height: 1, color: color),
              ),
              const SizedBox(width: 4),
              const Padding(
                padding: EdgeInsets.only(bottom: 3),
                child: Text('张', style: TextStyle(fontSize: 14)),
              ),
            ],
          ),
        ],
      ),
    );
    Widget pill(String label, IconData icon, StudyMode m, {bool primary = false, bool enabled = true}) => Expanded(
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Glass(
          radius: 16,
          tint: primary ? M.sage : null,
          padding: const EdgeInsets.symmetric(vertical: 10),
          onTap: enabled ? () => open(m) : null,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: primary ? Colors.white : M.text),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: primary ? Colors.white : M.text),
              ),
            ],
          ),
        ),
      ),
    );
    return Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.assignment_outlined, color: M.text, size: 20),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (resumeText != null)
                GestureDetector(
                  onTap: onResume,
                  child: Text(
                    resumeText!,
                    style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [number('新学', c?.newAvailable ?? 0, M.text), number('待复习', c?.due ?? 0, M.roseDark)]),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(c == null ? '今日新卡' : c.newProgress, style: TextStyle(color: M.sub, fontSize: 12)),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: c == null || c.newCap <= 0 ? 0 : (c.newDone / c.newCap).clamp(0.0, 1.0),
                    minHeight: 6,
                    color: M.rose,
                    backgroundColor: M.glass.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              pill(
                '学新卡',
                Icons.fiber_new_outlined,
                StudyMode.newOnly,
                enabled: (c?.newAvailable ?? 0) > 0 || (c?.newLimitReached ?? false),
              ),
              const SizedBox(width: 8),
              pill('复习', Icons.replay_rounded, StudyMode.reviewOnly, enabled: (c?.due ?? 0) > 0),
              const SizedBox(width: 8),
              pill('全部学习', Icons.play_arrow_rounded, StudyMode.all, primary: true),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: M.sageDark,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => DueByDayPage(projectId: projectId))),
              icon: const Icon(Icons.event_note_outlined, size: 18),
              label: const Text('查看到期安排'),
            ),
          ),
        ],
      ),
    );
  }
}
