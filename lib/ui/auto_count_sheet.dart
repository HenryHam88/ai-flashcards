import 'package:material_ui/material_ui.dart';

import '../models.dart';
import '../services/pipeline.dart';
import '../theme/glass.dart';

/// 自动数量确认面板：显示「预计约 N 张/道」和折叠的知识点列表，可微调后开始生成。
/// 返回 (闪卡数, 题目数)，取消返回 null。
Future<(int, int)?> showAutoCountConfirm(BuildContext context, GenPlan plan, {bool expandList = false}) =>
    showGlassSheet<(int, int)>(context, (ctx, sc) => AutoCountConfirm(plan: plan, controller: sc, expandList: expandList),
        initial: 0.75, maxSize: 0.95);

/// 规划失败时：说明原因，请用户手动设置这次的数量。返回 (闪卡数, 题目数)，取消返回 null。
Future<(int, int)?> showFixedCountFallback(BuildContext context, String reason, GenOptions o) => showDialog<(int, int)>(
      context: context,
      builder: (ctx) {
        var c = o.autoCards ? o.cardCount : 0, q = o.autoQuestions ? o.questionCount : 0;
        return StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
            backgroundColor: M.sheet,
            title: const Text('没能自动估算数量'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(reason, style: TextStyle(color: M.sub, fontSize: 13)),
              const SizedBox(height: 8),
              const Text('请手动设置这次要生成的数量：'),
              CountRow(label: '闪卡', value: c, onChanged: (v) => set(() => c = v)),
              CountRow(label: '题目', value: q, onChanged: (v) => set(() => q = v)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              TextButton(
                  onPressed: c + q == 0 ? null : () => Navigator.pop(ctx, (c, q)),
                  child: Text('开始生成', style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w700))),
            ],
          ),
        );
      },
    );

class CountRow extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final int step;
  const CountRow({super.key, required this.label, required this.value, required this.onChanged, this.step = 5});
  @override
  Widget build(BuildContext context) => Row(children: [
        Text(label),
        const Spacer(),
        IconButton(
            onPressed: value <= 0 ? null : () => onChanged((value - step).clamp(0, 200)),
            icon: const Icon(Icons.remove_circle_outline)),
        SizedBox(
            width: 40,
            child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
        IconButton(onPressed: () => onChanged((value + step).clamp(0, 200)), icon: const Icon(Icons.add_circle_outline)),
      ]);
}

class AutoCountConfirm extends StatefulWidget {
  final GenPlan plan;
  final ScrollController? controller;
  final bool expandList;
  const AutoCountConfirm({super.key, required this.plan, this.controller, this.expandList = false});
  @override
  State<AutoCountConfirm> createState() => _AutoCountConfirmState();
}

class _AutoCountConfirmState extends State<AutoCountConfirm> {
  late int cards = widget.plan.count.cards, questions = widget.plan.count.questions;
  late bool open = widget.expandList;

  @override
  Widget build(BuildContext context) {
    final p = widget.plan, a = p.count;
    final groups = p.byChapter;
    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
      const Text('自动数量', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 12),
      Glass(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text('预计约 ', style: TextStyle(color: M.sub)),
            Text('${cards + questions}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
            Text(' 张/道', style: TextStyle(color: M.sub)),
          ]),
          const SizedBox(height: 2),
          Text('识别到 ${p.kps.length} 个知识点 · 闪卡 $cards 张 · 题目 $questions 道',
              style: TextStyle(color: M.sub, fontSize: 13)),
          if (a.capped) ...[
            const SizedBox(height: 6),
            Text('按知识点约 ${a.rawTotal} 张/道，已按单次上限 ${a.cap} 减少（可在学习设置中调整）',
                style: TextStyle(color: M.roseDark, fontSize: 12)),
          ],
        ]),
      ),
      const SizedBox(height: 8),
      CountRow(label: '闪卡', value: cards, step: 1, onChanged: (v) => setState(() => cards = v)),
      CountRow(label: '题目', value: questions, step: 1, onChanged: (v) => setState(() => questions = v)),
      const SizedBox(height: 4),
      Glass(
        padding: EdgeInsets.zero,
        child: Column(children: [
          InkWell(
            onTap: () => setState(() => open = !open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(children: [
                const Icon(Icons.list_alt_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('知识点列表（${p.kps.length}）', style: const TextStyle(fontWeight: FontWeight.w600))),
                Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: M.sub),
              ]),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final e in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                    child: Text('${e.key}（${e.value.length}）',
                        style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                  for (final k in e.value)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (k.type.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(right: 6, top: 1),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                                color: M.greyBlue.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(6)),
                            child: Text(k.type, style: TextStyle(fontSize: 11, color: M.text)),
                          ),
                        Expanded(child: MathText(k.title, style: const TextStyle(fontSize: 13))),
                        if (k.page > 0) Text(' p.${k.page}', style: TextStyle(color: M.sub, fontSize: 11)),
                      ]),
                    ),
                ],
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: GlassButton(label: '取消', onTap: () => Navigator.pop(context))),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: GlassButton(
            label: '开始生成',
            icon: Icons.auto_awesome_rounded,
            tint: M.sage,
            onTap: cards + questions == 0 ? null : () => Navigator.pop(context, (cards, questions)),
          ),
        ),
      ]),
    ]);
  }
}
