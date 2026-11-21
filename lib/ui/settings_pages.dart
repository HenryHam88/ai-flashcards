import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../services/backup.dart';
import '../services/reminder.dart';
import '../theme/glass.dart';
import '../help/help_articles.dart' show authorQQ;
import 'help_page.dart' show HelpHomePage, copyQQ;

const repoUrl = 'https://github.com/HenryHam88/ai-flashcards';

// ------------------------------------------------------------------ 通用小部件

/// 一组设置：玻璃卡片里放多行。
class SettingsGroup extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const SettingsGroup({super.key, this.title, required this.children});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 14, 6, 8),
            child: Text(title!, style: TextStyle(color: M.sub, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        Glass(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 52, color: M.line.withValues(alpha: M.dark ? 0.5 : 0.9)),
              children[i],
            ]
          ]),
        ),
      ]);
}

class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? color;
  const SettingsTile({super.key, required this.icon, required this.title, this.subtitle, this.trailing, this.onTap, this.color});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap == null
            ? null
            : () {
                tapFeedback();
                onTap!();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Icon(icon, color: color ?? M.text, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: color ?? M.text)),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: TextStyle(color: M.sub, fontSize: 12, height: 1.4)),
                  ),
              ]),
            ),
            if (trailing != null) trailing! else if (onTap != null) Icon(Icons.chevron_right_rounded, color: M.sub),
          ]),
        ),
      );
}

class SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const SwitchTile({super.key, required this.icon, required this.title, this.subtitle, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => SettingsTile(
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: () => onChanged(!value),
        trailing: Switch(value: value, onChanged: (v) {
          tapFeedback();
          onChanged(v);
        }, activeThumbColor: M.sageDark),
      );
}

/// 带数值显示的滑块行。
class SliderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String valueLabel;
  final String? hint;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  const SliderTile(
      {super.key,
      required this.icon,
      required this.title,
      required this.valueLabel,
      this.hint,
      required this.value,
      required this.min,
      required this.max,
      this.divisions,
      required this.onChanged});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: M.text, size: 22),
            const SizedBox(width: 14),
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
            Text(valueLabel, style: TextStyle(color: M.sageDark, fontWeight: FontWeight.w700)),
          ]),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: M.sageDark,
            inactiveColor: M.mist,
            onChanged: onChanged,
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 0, 6),
              child: Text(hint!, style: TextStyle(color: M.sub, fontSize: 12, height: 1.4)),
            ),
        ]),
      );
}

String fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

String fmtTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

// ------------------------------------------------------------------ 学习设置

class LearningSettingsPage extends StatefulWidget {
  const LearningSettingsPage({super.key});
  @override
  State<LearningSettingsPage> createState() => _LearningSettingsPageState();
}

class _LearningSettingsPageState extends State<LearningSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final st = s.settings;
    String lim(int v) => v == 0 ? '不限' : '$v 张';
    return GlassScaffold(
      title: '学习设置',
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        SettingsGroup(title: '每日上限', children: [
          SliderTile(
            icon: Icons.fiber_new_rounded,
            title: '每日新卡',
            valueLabel: lim(st.dailyNewLimit),
            hint: '每天最多学多少张新卡；拉到最左为不限。',
            value: st.dailyNewLimit.toDouble(),
            min: 0,
            max: 200,
            divisions: 40,
            onChanged: (v) => setState(() => st.dailyNewLimit = v.round()),
          ),
          SliderTile(
            icon: Icons.replay_rounded,
            title: '每日复习',
            valueLabel: lim(st.dailyReviewLimit),
            hint: '到期卡片太多时，每天最多复习多少张；其余顺延到明天。',
            value: st.dailyReviewLimit.toDouble(),
            min: 0,
            max: 500,
            divisions: 50,
            onChanged: (v) => setState(() => st.dailyReviewLimit = v.round()),
          ),
        ]),
        SettingsGroup(title: '记忆算法（FSRS）', children: [
          SliderTile(
            icon: Icons.psychology_alt_outlined,
            title: '目标记忆率',
            valueLabel: '${(st.desiredRetention * 100).round()}%',
            hint: '越高越不容易忘，但每天要复习的卡片更多。一般 85%–92% 最划算，默认 90%。',
            value: st.desiredRetention,
            min: 0.70,
            max: 0.97,
            divisions: 27,
            onChanged: (v) => setState(() => st.desiredRetention = double.parse(v.toStringAsFixed(2))),
          ),
        ]),
        SettingsGroup(title: '出题质量', children: [
          SliderTile(
            icon: Icons.auto_awesome_motion_outlined,
            title: '自动数量上限',
            valueLabel: '${st.autoCap} 张/道',
            hint: '出题数量选「自动（按知识点）」时，每次生成闪卡和题目合计最多多少；超出时按比例减少，控制数量和费用。',
            value: st.autoCap.toDouble(),
            min: 10,
            max: 200,
            divisions: 38,
            onChanged: (v) => setState(() => st.autoCap = v.round()),
          ),
          SwitchTile(
            icon: Icons.fact_check_outlined,
            title: '生成后先审核',
            subtitle: '新生成的卡片和题目先放进「待审核」，确认后才加入复习。关闭时直接加入（生成后仍可点「审核这批」）',
            value: st.reviewBeforeAdd,
            onChanged: (v) => setState(() => st.reviewBeforeAdd = v),
          ),
        ]),
        SettingsGroup(title: '每日开始时间', children: [
          SliderTile(
            icon: Icons.wb_twilight_rounded,
            title: '新的一天从几点开始',
            valueLabel: '${st.dayStartHour}:00',
            hint: '熬夜学习时，凌晨仍算作前一天，用于统计每日上限和打卡。',
            value: st.dayStartHour.toDouble(),
            min: 0,
            max: 6,
            divisions: 6,
            onChanged: (v) => setState(() => st.dayStartHour = v.round()),
          ),
        ]),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 外观

class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});
  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final st = s.settings;
    void apply(VoidCallback f) {
      setState(f);
      s.changed();
    }

    Widget modeChip(String v, String label, IconData icon) {
      final sel = st.themeMode == v;
      return Expanded(
        child: Glass(
          radius: 16,
          tint: sel ? M.sage : null,
          padding: const EdgeInsets.symmetric(vertical: 12),
          onTap: () => apply(() => st.themeMode = v),
          child: Column(children: [
            Icon(icon, color: sel ? Colors.white : M.text),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: sel ? Colors.white : M.text, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
      );
    }

    return GlassScaffold(
      title: '外观',
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 14, 6, 8),
          child: Text('主题', style: TextStyle(color: M.sub, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Row(children: [
          modeChip('light', '浅色', Icons.light_mode_outlined),
          const SizedBox(width: 10),
          modeChip('dark', '深色', Icons.dark_mode_outlined),
          const SizedBox(width: 10),
          modeChip('system', '跟随系统', Icons.brightness_auto_outlined),
        ]),
        SettingsGroup(title: '文字', children: [
          SliderTile(
            icon: Icons.format_size_rounded,
            title: '字体大小',
            valueLabel: '${(st.textScale * 100).round()}%',
            value: st.textScale,
            min: 0.85,
            max: 1.3,
            divisions: 9,
            onChanged: (v) => apply(() => st.textScale = double.parse(v.toStringAsFixed(2))),
          ),
          SliderTile(
            icon: Icons.functions_rounded,
            title: '公式字号',
            valueLabel: '${(st.mathScale * 100).round()}%',
            value: st.mathScale,
            min: 0.8,
            max: 1.5,
            divisions: 14,
            onChanged: (v) => apply(() => st.mathScale = double.parse(v.toStringAsFixed(2))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Glass(
              child: MathText(r'预览：**勾股定理** $a^2+b^2=c^2$，以及 $\int_0^1 x\,dx=\frac12$', style: const TextStyle(fontSize: 15)),
            ),
          ),
        ]),
        SettingsGroup(title: '动效与反馈', children: [
          SwitchTile(
            icon: Icons.animation_rounded,
            title: '减少动态效果',
            subtitle: '关闭页面切换和翻卡动画，适合晕动或低端设备',
            value: st.reduceMotion,
            onChanged: (v) => apply(() => st.reduceMotion = v),
          ),
          SwitchTile(
            icon: Icons.vibration_rounded,
            title: '触感反馈',
            subtitle: '点击按钮、评分时轻微振动',
            value: st.haptics,
            onChanged: (v) => apply(() => st.haptics = v),
          ),
        ]),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 提醒

class ReminderPage extends StatefulWidget {
  const ReminderPage({super.key});
  @override
  State<ReminderPage> createState() => _ReminderPageState();
}

class _ReminderPageState extends State<ReminderPage> {
  @override
  Widget build(BuildContext context) {
    final st = context.read<AppState>().settings;
    final t = TimeOfDay(hour: st.reminderMinutes ~/ 60, minute: st.reminderMinutes % 60);
    Future<void> reschedule() async {
      try {
        await Reminder.schedule(on: st.reminderOn, minutes: st.reminderMinutes);
      } catch (e) {
        if (context.mounted) toast(context, '提醒设置失败：$e');
      }
    }

    return GlassScaffold(
      title: '提醒',
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        SettingsGroup(children: [
          SwitchTile(
            icon: Icons.notifications_active_outlined,
            title: '每日复习提醒',
            subtitle: '每天固定时间发一条通知，提醒你复习到期的卡片',
            value: st.reminderOn,
            onChanged: (v) async {
              if (v && !await Reminder.requestPermission()) {
                if (context.mounted) toast(context, '没有通知权限，请在系统设置里允许「闪卡刷题」发送通知');
                return;
              }
              setState(() => st.reminderOn = v);
              await reschedule();
              if (v && context.mounted) toast(context, '已开启，每天 ${t.format(context)} 提醒你');
            },
          ),
          SettingsTile(
            icon: Icons.schedule_rounded,
            title: '提醒时间',
            subtitle: t.format(context),
            onTap: () async {
              final picked = await showTimePicker(context: context, initialTime: t);
              if (picked == null) return;
              setState(() => st.reminderMinutes = picked.hour * 60 + picked.minute);
              await reschedule();
            },
          ),
        ]),
        const SizedBox(height: 12),
        Text('提醒完全在本机生成，不需要联网。部分手机的省电策略可能会延迟通知，可在系统设置里把本应用设为「不限制」。',
            style: TextStyle(color: M.sub, fontSize: 12, height: 1.6)),
      ]),
    );
  }
}

// ------------------------------------------------------------------ 数据：导出 / 导入

Future<void> saveOrShareBackup(BuildContext context, Uint8List bytes, String name) async {
  final how = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: M.sheet,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        Text('备份已生成（${fmtSize(bytes.length)}）', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 8),
        ListTile(
            leading: const Icon(Icons.save_alt_rounded),
            title: const Text('保存到文件夹'),
            subtitle: const Text('下载目录、网盘或任意文件夹'),
            onTap: () => Navigator.pop(ctx, 'save')),
        ListTile(
            leading: const Icon(Icons.share_rounded),
            title: const Text('分享'),
            subtitle: const Text('发给微信、QQ、邮箱，或传到新手机'),
            onTap: () => Navigator.pop(ctx, 'share')),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (how == null || !context.mounted) return;
  if (how == 'save') {
    final uri = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: 'application/zip');
    if (uri != null && context.mounted) toast(context, '已保存：$name');
  } else {
    final dir = await Directory.systemTemp.createTemp('afc');
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/zip')], subject: name));
  }
}

class DataPage extends StatefulWidget {
  const DataPage({super.key});
  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  List<File> local = [];

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final b = await context.read<AppState>().backup();
    final l = await b.localBackups();
    if (mounted) setState(() => local = l);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final st = s.settings;
    return GlassScaffold(
      title: '数据',
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        SettingsGroup(title: '备份与恢复', children: [
          SettingsTile(
            icon: Icons.upload_file_rounded,
            title: '导出数据',
            subtitle: '所有项目、卡片、题目、复习进度、错题、解释历史和设置，打包成一个 .afcbak 文件',
            onTap: () => showExportSheet(context),
          ),
          SettingsTile(
            icon: Icons.download_rounded,
            title: '导入数据',
            subtitle: '从备份文件恢复，换手机时用；也可以导入同学分享的项目',
            onTap: () => pickAndImport(context).then((_) => _loadLocal()),
          ),
        ]),
        SettingsGroup(title: '自动备份', children: [
          SwitchTile(
            icon: Icons.history_rounded,
            title: '每周自动备份',
            subtitle: st.lastAutoBackup == null ? '保存在应用内部，保留最近 3 份（不含原始文件）' : '上次：${fmtTime(st.lastAutoBackup!)}',
            value: st.autoBackup,
            onChanged: (v) async {
              setState(() => st.autoBackup = v);
              if (v) {
                await (await s.backup()).autoBackupIfDue();
                await _loadLocal();
              }
            },
          ),
          for (final f in local)
            SettingsTile(
              icon: p.basename(f.path).startsWith('safety_') ? Icons.shield_outlined : Icons.inventory_2_outlined,
              title: p.basename(f.path).startsWith('safety_') ? '导入前的安全备份' : '自动备份',
              subtitle: '${fmtTime(f.lastModifiedSync())} · ${fmtSize(f.lengthSync())}',
              trailing: PopupMenuButton<String>(
                icon: Icon(Icons.more_horiz_rounded, color: M.sub),
                onSelected: (v) async {
                  final bytes = v == 'delete' ? null : await f.readAsBytes();
                  if (!context.mounted) return;
                  if (v == 'restore') {
                    await importBytes(context, bytes!);
                  } else if (v == 'share') {
                    await saveOrShareBackup(context, bytes!, p.basename(f.path));
                  } else {
                    await f.delete();
                  }
                  await _loadLocal();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'restore', child: Text('从这份恢复')),
                  PopupMenuItem(value: 'share', child: Text('保存 / 分享')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
        ]),
        const SizedBox(height: 12),
        Text('备份文件默认不含 API 密钥。导入时会先校验文件完整性；选择「覆盖」前会自动保存一份当前数据的安全备份，可在上方找回。',
            style: TextStyle(color: M.sub, fontSize: 12, height: 1.6)),
      ]),
    );
  }
}

/// 导出面板：整机备份或单个项目。
Future<void> showExportSheet(BuildContext context, {String? projectId, String? projectName}) =>
    showGlassSheet(context, (ctx, sc) => _ExportSheet(projectId: projectId, projectName: projectName, controller: sc),
        initial: 0.62);

class _ExportSheet extends StatefulWidget {
  final String? projectId;
  final String? projectName;
  final ScrollController controller;
  const _ExportSheet({this.projectId, this.projectName, required this.controller});
  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  bool files = false, secrets = false, progress = true, busy = false;
  int? fileSize, dataSize;

  bool get isProject => widget.projectId != null;

  @override
  void initState() {
    super.initState();
    () async {
      final b = await context.read<AppState>().backup();
      final f = await b.originalFilesSize(projectId: widget.projectId);
      final d = await b.dataSize(projectId: widget.projectId);
      if (mounted) {
        setState(() {
          fileSize = f;
          dataSize = d;
        });
      }
    }();
  }

  Future<void> _go() async {
    setState(() => busy = true);
    try {
      final b = await context.read<AppState>().backup();
      final bytes = await b.export(
          projectId: widget.projectId,
          options: BackupOptions(includeFiles: files, includeSecrets: !isProject && secrets, includeProgress: progress));
      if (!mounted) return;
      final name = BackupService.fileName(projectName: widget.projectName);
      Navigator.pop(context);
      await saveOrShareBackup(context, bytes, name);
    } catch (e) {
      if (mounted) toast(context, '导出失败：$e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final est = (dataSize ?? 0) + (files ? (fileSize ?? 0) : 0);
    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
      Text(isProject ? '导出项目「${widget.projectName}」' : '导出全部数据',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(
          isProject
              ? '生成一个 .afcbak 文件，同学用闪卡刷题「导入数据」即可得到同样的资料、章节、卡片和题目。'
              : '项目、资料信息、章节、解析结果、卡片、题目、复习进度与记录、错题本、解释历史、出题模板和设置都会打包进去。',
          style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
      const SizedBox(height: 10),
      SettingsGroup(children: [
        SwitchTile(
          icon: Icons.picture_as_pdf_outlined,
          title: '包含原始 PDF / Word',
          subtitle: fileSize == null ? '计算中…' : '约 ${fmtSize(fileSize!)}；不带也能正常复习，只是不能重新解析或查看原页',
          value: files,
          onChanged: (v) => setState(() => files = v),
        ),
        if (isProject)
          SwitchTile(
            icon: Icons.trending_up_rounded,
            title: '包含我的学习进度',
            subtitle: '关闭后卡片以新卡形式分享，不带复习记录和错题',
            value: progress,
            onChanged: (v) => setState(() => progress = v),
          ),
        if (!isProject)
          SwitchTile(
            icon: Icons.key_rounded,
            title: '包含 API 密钥',
            subtitle: secrets ? '⚠️ 拿到这个文件的人可以直接使用你的密钥消费额度，请勿分享' : '默认不包含，换手机后需重新填写',
            value: secrets,
            onChanged: (v) async {
              if (v) {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('包含 API 密钥？'),
                    content: const Text('备份文件不加密。任何拿到这个文件的人都能看到并使用你的 API 密钥。只建议在自己的两台设备之间迁移时打开。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                      TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('我了解，包含')),
                    ],
                  ),
                );
                if (ok != true) return;
              }
              setState(() => secrets = v);
            },
          ),
      ]),
      const SizedBox(height: 14),
      Text('预计大小：约 ${fmtSize(est)}', style: TextStyle(color: M.sub, fontSize: 13)),
      const SizedBox(height: 10),
      GlassButton(
        label: busy ? '正在打包…' : '导出',
        icon: Icons.upload_file_rounded,
        tint: M.sage,
        expand: true,
        onTap: busy ? null : _go,
      ),
    ]);
  }
}

/// 选文件 → 校验 → 摘要 → 选择方式 → 导入。
Future<void> pickAndImport(BuildContext context) async {
  final r = await FilePicker.pickFiles(type: FileType.any);
  if (r.isEmpty || !context.mounted) return;
  final f = r.first;
  final bytes = f.path != null ? await File(f.path!).readAsBytes() : null;
  if (bytes == null) return;
  if (!context.mounted) return;
  await importBytes(context, bytes);
}

Future<void> importBytes(BuildContext context, Uint8List bytes) async {
  final s = context.read<AppState>();
  final b = await s.backup();
  BackupInfo info;
  try {
    info = b.read(bytes);
  } on BackupException catch (e) {
    if (context.mounted) {
      await showDialog(
          context: context,
          builder: (c) => AlertDialog(
                title: const Text('无法导入'),
                content: Text(e.message),
                actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('知道了'))],
              ));
    }
    return;
  }
  if (!context.mounted) return;
  final choice = await showGlassSheet<(ImportMode, bool)>(context, (ctx, sc) => ImportSummary(info: info, controller: sc),
      initial: 0.7);
  if (choice == null || !context.mounted) return;
  try {
    final res = await b.import(info, choice.$1, restoreSecrets: choice.$2);
    await s.afterImport();
    if (context.mounted) {
      toast(
          context,
          choice.$1 == ImportMode.overwrite
              ? '导入完成，已用备份替换当前数据'
              : '合并完成：新增 ${res.added['projects'] ?? 0} 个项目、${res.added['cards'] ?? 0} 张卡片、${res.added['questions'] ?? 0} 道题'
                  '${(res.updated['cards'] ?? 0) > 0 ? '，更新 ${res.updated['cards']} 张卡片的进度' : ''}');
    }
  } catch (e) {
    if (context.mounted) toast(context, '导入失败，当前数据没有任何改动：$e');
  }
}

class ImportSummary extends StatefulWidget {
  final BackupInfo info;
  final ScrollController? controller;
  const ImportSummary({super.key, required this.info, this.controller});
  @override
  State<ImportSummary> createState() => _ImportSummaryState();
}

class _ImportSummaryState extends State<ImportSummary> {
  late ImportMode mode = widget.info.scope == 'full' ? ImportMode.overwrite : ImportMode.merge;
  bool secrets = false;

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final full = i.scope == 'full';
    Widget stat(String label, int n) => Expanded(
          child: Column(children: [
            Text('$n', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: M.sageDark)),
            Text(label, style: TextStyle(color: M.sub, fontSize: 12)),
          ]),
        );
    Widget modeTile(ImportMode m, String title, String sub) {
      final sel = mode == m;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Glass(
          tint: sel ? M.sage.withValues(alpha: 0.9) : null,
          onTap: () => setState(() => mode = m),
          child: Row(children: [
            Icon(sel ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: sel ? Colors.white : M.sub),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: sel ? Colors.white : M.text)),
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(fontSize: 12, height: 1.4, color: sel ? Colors.white : M.sub)),
              ]),
            ),
          ]),
        ),
      );
    }

    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
      Text(full ? '导入备份' : '导入项目', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
          [
            if (i.createdAt != null) '备份于 ${fmtTime(i.createdAt!)}',
            if (i.appVersion.isNotEmpty) '来自 v${i.appVersion}',
            if (!full && i.projectNames.isNotEmpty) '「${i.projectNames.join('、')}」',
          ].join(' · '),
          style: TextStyle(color: M.sub, fontSize: 13)),
      const SizedBox(height: 12),
      Glass(
        child: Row(children: [
          stat('项目', i.count('projects')),
          stat('卡片', i.count('cards')),
          stat('题目', i.count('questions')),
          stat('错题', i.count('wrong')),
        ]),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final t in [
          if (i.includesFiles) '含原始文件 ${i.count('files')} 个' else '不含原始文件',
          if (i.count('explain') > 0) '解释历史 ${i.count('explain')} 条',
          if (i.includesProgress) '含学习进度' else '不含学习进度',
          if (i.includesSecrets) '含 API 密钥',
        ])
          Chip(label: Text(t, style: const TextStyle(fontSize: 12)), visualDensity: VisualDensity.compact),
      ]),
      const SizedBox(height: 14),
      modeTile(
          ImportMode.merge,
          '合并',
          full
              ? '保留现有数据，只添加备份里没有的项目和卡片；同一张卡保留更近一次复习的进度'
              : '加入这个项目；已存在的卡片、题目不会重复添加'),
      modeTile(
          ImportMode.overwrite,
          full ? '覆盖当前数据' : '替换同名项目',
          full ? '清空本机数据，换成备份里的内容。会先自动保存一份当前数据的安全备份' : '用文件里的版本替换本机的这个项目（先自动做安全备份），其他项目不受影响'),
      if (i.includesSecrets)
        SwitchTile(
          icon: Icons.key_rounded,
          title: '同时恢复 API 密钥',
          subtitle: '会覆盖本机已填写的密钥',
          value: secrets,
          onChanged: (v) => setState(() => secrets = v),
        ),
      const SizedBox(height: 10),
      GlassButton(
        label: mode == ImportMode.overwrite ? (full ? '覆盖并导入' : '替换并导入') : '合并导入',
        icon: Icons.download_done_rounded,
        tint: mode == ImportMode.overwrite ? M.roseDark : M.sage,
        expand: true,
        onTap: () => Navigator.pop(context, (mode, secrets)),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ 关于

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});
  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String? updateText;

  /// 比较 1.2.10 > 1.2.9 这种版本号。
  static int cmpVersion(String a, String b) {
    List<int> parts(String v) => v.replaceFirst('v', '').split(RegExp(r'[.+]')).map((e) => int.tryParse(e) ?? 0).toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  Future<void> _check() async {
    final cur = context.read<AppState>().appVersion;
    setState(() => updateText = '检查中…');
    try {
      final r = await http
          .get(Uri.parse('https://api.github.com/repos/HenryHam88/ai-flashcards/releases/latest'),
              headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 10));
      final tag = (jsonDecode(r.body) as Map)['tag_name']?.toString() ?? '';
      if (tag.isEmpty) throw '没有找到发布版本';
      if (cmpVersion(tag, cur) > 0) {
        setState(() => updateText = '发现新版本 $tag');
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('发现新版本 $tag'),
            content: Text('当前版本 v$cur。前往 GitHub 下载最新安装包？数据不会丢失。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('以后再说')),
              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('去下载')),
            ],
          ),
        );
        if (go == true) _open('$repoUrl/releases/latest');
      } else {
        setState(() => updateText = '已是最新版本');
      }
    } catch (e) {
      setState(() => updateText = '检查失败，请稍后再试');
    }
  }

  void _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final v = context.read<AppState>().appVersion;
    void go(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    return GlassScaffold(
      title: '关于',
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        const SizedBox(height: 10),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.asset('assets/logo.png', width: 84, height: 84, errorBuilder: (_, _, _) {
              return Icon(Icons.style_rounded, size: 72, color: M.sageDark);
            }),
          ),
        ),
        const SizedBox(height: 10),
        const Center(child: Text('闪卡刷题', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
        Center(child: Text(v.isEmpty ? '' : '版本 $v', style: TextStyle(color: M.sub))),
        const SizedBox(height: 4),
        Center(child: Text('把课本和讲义变成闪卡与练习题', style: TextStyle(color: M.sub, fontSize: 13))),
        SettingsGroup(title: '版本', children: [
          SettingsTile(
              icon: Icons.system_update_rounded,
              title: '检查更新',
              subtitle: updateText ?? '从 GitHub 查询最新发布版本',
              onTap: _check),
          SettingsTile(icon: Icons.article_outlined, title: '更新日志', onTap: () => go(const ChangelogPage())),
        ]),
        SettingsGroup(title: '联系作者', children: [
          SettingsTile(
              icon: Icons.chat_bubble_outline_rounded,
              title: '作者 QQ：$authorQQ',
              subtitle: '点按复制',
              onTap: () => copyQQ(context)),
          SettingsTile(
              icon: Icons.help_outline_rounded,
              title: '使用帮助',
              subtitle: '快速上手、各功能怎么用、常见问题',
              onTap: () => go(const HelpHomePage())),
        ]),
        SettingsGroup(title: '开源', children: [
          SettingsTile(
              icon: Icons.code_rounded, title: 'GitHub 仓库', subtitle: 'HenryHam88/ai-flashcards', onTap: () => _open(repoUrl)),
          SettingsTile(
              icon: Icons.feedback_outlined,
              title: '问题反馈',
              subtitle: '提交 Bug 或功能建议',
              onTap: () => _open('$repoUrl/issues/new/choose')),
          SettingsTile(
              icon: Icons.gavel_rounded,
              title: '开源许可',
              subtitle: '本应用使用的第三方库',
              onTap: () => showLicensePage(context: context, applicationName: '闪卡刷题', applicationVersion: v)),
        ]),
        SettingsGroup(title: '隐私', children: [
          SettingsTile(icon: Icons.privacy_tip_outlined, title: '隐私说明', onTap: () => go(const PrivacyPage())),
        ]),
      ]),
    );
  }
}

class ChangelogPage extends StatelessWidget {
  const ChangelogPage({super.key});
  @override
  Widget build(BuildContext context) => GlassScaffold(
        title: '更新日志',
        body: FutureBuilder<String>(
          future: rootBundle.loadString('CHANGELOG.md'),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            // 去掉文件头说明，只保留各版本
            var t = snap.data!;
            final i = t.indexOf('\n## [');
            if (i > 0) t = t.substring(i + 1);
            t = t.replaceAll('## [Unreleased]\n', '').replaceAllMapped(
                RegExp(r'^## \[(.+?)\] - (.+)$', multiLine: true), (m) => '## v${m[1]}  ·  ${m[2]}');
            t = t.replaceAll(RegExp(r'^\[.+?\]: .+$', multiLine: true), '');
            return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
              Glass(child: MathText(t.trim(), style: const TextStyle(fontSize: 14, height: 1.6))),
            ]);
          },
        ),
      );
}

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});
  static const text = '''## 数据保存在哪里
所有资料、解析结果、卡片、题目、复习记录、错题和解释历史都只保存在你的手机上。闪卡刷题没有服务器，也不收集任何统计信息。

## 什么时候会联网
- **解析资料**：选择 DeepSeek OCR 或 Kimi 时，PDF / Word 会上传给你在设置中填写的服务商；选择「本地提取」则完全不联网。TXT 文件只在手机上读取，不会上传。
- **出题、解释、批改**：相关文字会发给你填写的出题模型接口。
- **检查更新**：只在你点击时访问 GitHub 查询最新版本号。

## API 密钥
密钥保存在系统安全存储（Android Keystore）中。导出备份时默认**不包含**密钥，除非你手动勾选。

## 删除数据
删除项目会同时删除其资料、卡片和题目；卸载应用会清除全部数据。''';
  @override
  Widget build(BuildContext context) => GlassScaffold(
        title: '隐私说明',
        body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
          Glass(child: MathText(text, style: const TextStyle(fontSize: 14, height: 1.6))),
        ]),
      );
}
