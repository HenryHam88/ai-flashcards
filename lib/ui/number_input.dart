import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/glass.dart';

/// 闪卡、题目每次最多生成的数量（大数量会照常拆成多批生成）。
const maxGenCount = 1500;

/// 把输入的文字转成 [min]–[max] 之间的整数；空或非数字返回 null。
int? parseClampedInt(String text, int min, int max) {
  final v = int.tryParse(text.trim());
  return v?.clamp(min, max);
}

/// 弹出数字键盘输入框，返回 [min]–[max] 之间的整数（超出范围自动取边界）；取消返回 null。
Future<int?> promptNumber(BuildContext context,
    {required String title, required int value, required int min, required int max, String unit = '', String? hint}) {
  final ctl = TextEditingController(text: '$value')..selection = TextSelection(baseOffset: 0, extentOffset: '$value'.length);
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      void submit() {
        final v = parseClampedInt(ctl.text, min, max);
        if (v != null) Navigator.pop(ctx, v);
      }

      return AlertDialog(
        backgroundColor: M.sheet,
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: const ValueKey('number_input'),
            controller: ctl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter('$max'.length)],
            decoration: InputDecoration(suffixText: unit.isEmpty ? null : unit, helperText: '范围 $min–$max'),
            onSubmitted: (_) => submit(),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(hint, style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: submit, child: Text('确定', style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w700))),
        ],
      );
    },
  );
}

/// 可点击的数字：点一下弹出输入框直接输入。
class TappableNumber extends StatelessWidget {
  final int value;
  final double width;
  final VoidCallback onTap;
  const TappableNumber({super.key, required this.value, required this.onTap, this.width = 48});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: M.sageDark.withValues(alpha: 0.5), width: 1.2)),
          ),
          child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      );
}

/// 「标签 —— [−] 数字 [+]」：±[step]，点数字可直接输入；范围 [min]–[max]。
class NumberStepper extends StatelessWidget {
  final String label;
  final int value;
  final int min, max, step;
  final ValueChanged<int> onChanged;
  final String? dialogTitle;
  final String unit;
  final String? hint;
  const NumberStepper(
      {super.key,
      required this.label,
      required this.value,
      required this.onChanged,
      this.min = 0,
      this.max = maxGenCount,
      this.step = 5,
      this.dialogTitle,
      this.unit = '',
      this.hint});
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: Text(label)),
        IconButton(
            onPressed: value <= min ? null : () => onChanged((value - step).clamp(min, max)),
            icon: const Icon(Icons.remove_circle_outline)),
        TappableNumber(
          value: value,
          width: '$max'.length > 3 ? 52 : 44,
          onTap: () async {
            final v = await promptNumber(context,
                title: dialogTitle ?? label, value: value, min: min, max: max, unit: unit, hint: hint);
            if (v != null) onChanged(v);
          },
        ),
        IconButton(
            onPressed: value >= max ? null : () => onChanged((value + step).clamp(min, max)),
            icon: const Icon(Icons.add_circle_outline)),
      ]);
}
