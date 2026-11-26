import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/cloud_storage.dart';
import '../theme/glass.dart';
import 'me_page.dart' show KeyField, settingsTextField;
import 'number_input.dart';
import 'settings_pages.dart';
import '../desktop/platform.dart';

/// RAM / CAM 最小权限策略：只允许读写这个存储桶里本应用的前缀。
String cloudPolicy(String provider, String bucket, String prefix) {
  final b = bucket.isEmpty ? '<存储桶名称>' : bucket;
  final pre = prefix.isEmpty ? '' : prefix;
  if (provider == 'tencent') {
    return '''{
  "version": "2.0",
  "statement": [{
    "effect": "allow",
    "action": ["name/cos:PutObject", "name/cos:GetObject", "name/cos:HeadObject", "name/cos:DeleteObject"],
    "resource": ["qcs::cos:*:uid/*:$b/$pre*"]
  }]
}''';
  }
  return '''{
  "Version": "1",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["oss:PutObject", "oss:GetObject", "oss:DeleteObject"],
    "Resource": ["acs:oss:*:*:$b/$pre*"]
  }]
}''';
}

/// 「我的 → 云端存储」：填写自己的阿里云 OSS / 腾讯云 COS，查看空间、释放空间。
class CloudSettingsPage extends StatefulWidget {
  const CloudSettingsPage({super.key});
  @override
  State<CloudSettingsPage> createState() => _CloudSettingsPageState();
}

class _CloudSettingsPageState extends State<CloudSettingsPage> {
  String? testResult;
  bool testing = false;
  bool configured = false;
  CloudUsage? usage;

  AppState get s => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ok = await s.settings.cloudConfigured();
    final u = await (await s.cloud()).usage();
    if (mounted) setState(() => (configured = ok, usage = u));
  }

  Future<void> _test() async {
    setState(() => (testing = true, testResult = '测试中…'));
    try {
      await (await s.cloud()).test();
      setState(() => testResult = '连接成功：可以上传、读取和删除');
    } catch (e) {
      setState(() => testResult = '失败：$e');
    }
    setState(() => testing = false);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final st = s.settings;
    final pv = CloudProvider.of(st.cloudProvider);
    final u = usage;
    return GlassScaffold(
      title: '云端存储',
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('用自己的存储桶省${Desk.device}空间', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('原始 PDF / Word、笔记照片、导出的 PDF 和备份可以放到你自己买的阿里云 OSS 或腾讯云 COS 上，${Desk.device}里只留解析好的文字。'
                '卡片、题目、笔记文字、导图都留在本机，复习不需要联网；需要原文件时（重新解析、查看照片原图）会自动下载回来。',
                style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
            const SizedBox(height: 6),
            Text('只在你点「释放空间」时才上传并删除本机文件，从不自动删除。不是多设备同步。',
                style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('服务商', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final x in CloudProvider.all)
                ChoiceChip(
                  label: Text(x.name),
                  selected: pv.id == x.id,
                  onSelected: (_) => setState(() => st.cloudProvider = x.id),
                ),
            ]),
            const SizedBox(height: 12),
            KeyedSubtree(
              key: ValueKey(pv.id),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                settingsTextField(pv.id == 's3' ? '地域（Region）' : '地域', st.cloudRegion, (v) => st.cloudRegion = v, hint: pv.regionHint),
                settingsTextField('存储桶', st.cloudBucket, (v) => st.cloudBucket = v, hint: pv.bucketHint),
                settingsTextField(pv.id == 's3' ? '服务地址' : '自定义域名（可选）', st.cloudEndpoint, (v) => st.cloudEndpoint = v,
                    hint: pv.id == 's3' ? 'https://<账号>.r2.cloudflarestorage.com' : 'files.example.com'),
                settingsTextField('路径前缀', st.cloudPrefix, (v) => st.cloudPrefix = v, hint: 'ai-flashcards/'),
                KeyField(label: pv.keyIdLabel, load: st.cloudKeyId, save: st.setCloudKeyId, hint: pv.id == 'tencent' ? 'AKID...' : 'LTAI...'),
                KeyField(label: pv.secretLabel, load: st.cloudSecret, save: st.setCloudSecret, hint: ''),
              ]),
            ),
            Text(
                switch (pv.id) {
                  'aliyun' => '地域填地域 ID（如 cn-hangzhou、cn-shanghai）。2025 年 3 月 20 日之后新开通 OSS 的用户，中国内地的存储桶要绑定自定义域名（并配好 HTTPS 证书）才能上传下载，请把域名填到「自定义域名」。',
                  'tencent' => '地域填地域代码（如 ap-guangzhou、ap-shanghai）；存储桶名称要带 APPID（控制台里显示的完整名称）。',
                  _ => '支持 Cloudflare R2、MinIO 等 S3 兼容服务（路径风格访问）。',
                },
                style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
            const SizedBox(height: 8),
            Text('建议新建一个子账号（RAM / CAM），只授予这个存储桶的读写权限，再用它的 AccessKey。密钥只保存在本机系统安全存储里，不会进入任何备份。',
                style: TextStyle(color: M.sub, fontSize: 12, height: 1.5)),
            if (pv.id != 's3')
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: M.sageDark, padding: EdgeInsets.zero),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('复制最小权限策略'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: cloudPolicy(pv.id, st.cloudBucket, st.cloudPrefix)));
                    toast(context, '已复制，粘贴到${pv.id == 'tencent' ? ' CAM' : ' RAM'} 自定义策略里');
                  },
                ),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        GlassButton(label: testing ? '测试中…' : '测试连接', icon: Icons.wifi_tethering_rounded, expand: true, onTap: testing ? null : _test),
        if (testResult != null) Padding(padding: const EdgeInsets.all(8), child: Text(testResult!)),
        if (u != null) ...[
          SettingsGroup(title: '空间', children: [
            SettingsTile(
              icon: Icons.phone_android_rounded,
              title: '本机占用 ${formatBytes(u.localTotal)}',
              subtitle: _kinds(u.localBytes),
            ),
            SettingsTile(
              icon: Icons.cloud_outlined,
              title: '云端 ${formatBytes(u.cloudTotal)}',
              subtitle: u.offloadedCount == 0 ? '还没有放到云端的文件' : '${u.offloadedCount} 个文件只在云端，用到时自动下载',
            ),
            SettingsTile(
              icon: Icons.cleaning_services_outlined,
              title: '释放空间',
              subtitle: !configured
                  ? '先填好上面的信息并测试连接'
                  : u.releasableCount == 0
                      ? '没有可以释放的文件'
                      : '${u.releasableCount} 个文件，约 ${formatBytes(u.releasable)}：上传到云端后删除本机文件',
              onTap: !configured || u.releasableCount == 0 ? null : () => showReleaseSheet(context).then((_) => _refresh()),
            ),
          ]),
          SettingsGroup(title: '下载缓存', children: [
            SliderTile(
              icon: Icons.download_for_offline_outlined,
              title: '缓存上限',
              valueLabel: '${st.cloudCacheMb} MB',
              hint: '从云端下载回来的文件超过这个大小时，自动删除最久没用的（云端仍保留）。当前 ${formatBytes(u.cacheBytes)}',
              value: st.cloudCacheMb.toDouble(),
              min: 50,
              max: 2000,
              divisions: 39,
              onChanged: (v) => setState(() => st.cloudCacheMb = (v / 50).round() * 50),
              onTapValue: () async {
                final v = await promptNumber(context, title: '缓存上限', value: st.cloudCacheMb, min: 50, max: 5000, unit: 'MB');
                if (v != null) setState(() => st.cloudCacheMb = v);
              },
            ),
            SettingsTile(
              icon: Icons.delete_sweep_outlined,
              title: '清空下载缓存',
              subtitle: u.cacheBytes == 0 ? '没有缓存' : '删除 ${formatBytes(u.cacheBytes)} 下载回来的副本',
              onTap: u.cacheBytes == 0
                  ? null
                  : () async {
                      final n = await (await s.cloud()).clearCache();
                      if (context.mounted) toast(context, '已清理 ${formatBytes(n)}');
                      await _refresh();
                    },
            ),
          ]),
        ],
      ]),
    );
  }

  String _kinds(Map<String, int> m) => m.isEmpty
      ? '没有大文件'
      : [for (final e in m.entries) '${MediaAsset.kindNames[e.key] ?? e.key} ${formatBytes(e.value)}'].join(' · ');
}

/// 释放空间面板：列出可以释放的文件（可勾选），上传到云端并校验后删除本机文件。
Future<void> showReleaseSheet(BuildContext context, {String? projectId}) =>
    showGlassSheet(context, (ctx, sc) => ReleaseSheet(projectId: projectId, controller: sc), initial: 0.7);

class ReleaseSheet extends StatefulWidget {
  final String? projectId;
  final ScrollController controller;
  const ReleaseSheet({super.key, this.projectId, required this.controller});
  @override
  State<ReleaseSheet> createState() => _ReleaseSheetState();
}

class _ReleaseSheetState extends State<ReleaseSheet> {
  List<(MediaAsset, int)>? items;
  final picked = <String>{};
  bool busy = false;
  String? status;
  double frac = 0;

  @override
  void initState() {
    super.initState();
    () async {
      final c = await context.read<AppState>().cloud();
      final l = <(MediaAsset, int)>[];
      for (final m in await c.releasable(projectId: widget.projectId)) {
        l.add((m, await File(m.localPath).length()));
      }
      l.sort((a, b) => b.$2.compareTo(a.$2));
      if (mounted) {
        setState(() {
          items = l;
          picked.addAll(l.map((e) => e.$1.id));
        });
      }
    }();
  }

  Future<void> _go() async {
    final s = context.read<AppState>();
    final todo = [for (final e in items!) if (picked.contains(e.$1.id)) e.$1];
    setState(() => busy = true);
    try {
      final r = await (await s.cloud()).releaseAll(todo, onProgress: (done, total, name) {
        if (mounted) setState(() => (status = done == total ? '完成' : '正在上传 $name（${done + 1}/$total）', frac = total == 0 ? 1 : done / total));
      });
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, r.errors.isEmpty ? '已释放 ${formatBytes(r.bytes)}（${r.files} 个文件）' : '释放 ${formatBytes(r.bytes)}，${r.errors.length} 个失败：${r.errors.first}');
      s.changed();
    } catch (e) {
      if (mounted) setState(() => (busy = false, status = '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = items;
    final total = l == null ? 0 : l.where((e) => picked.contains(e.$1.id)).fold(0, (a, e) => a + e.$2);
    return ListView(controller: widget.controller, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
      const Text('释放空间', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text('选中的文件会先上传到云端并校验大小，成功后才删除本机文件。之后需要时（重新解析、查看原图）会自动下载回来。',
          style: TextStyle(color: M.sub, fontSize: 13, height: 1.5)),
      const SizedBox(height: 10),
      if (l == null)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
      else if (l.isEmpty)
        Padding(padding: const EdgeInsets.all(24), child: Text('没有可以释放的文件。资料要先解析完成才能放到云端。', style: TextStyle(color: M.sub)))
      else
        SettingsGroup(children: [
          for (final (m, size) in l)
            SettingsTile(
              icon: switch (m.kind) {
                'doc' => Icons.picture_as_pdf_outlined,
                'photo' => Icons.photo_outlined,
                'chat_file' => Icons.attach_file_rounded,
                'backup' => Icons.inventory_2_outlined,
                _ => Icons.description_outlined,
              },
              title: m.fileName.isEmpty ? p.basename(m.localPath) : m.fileName,
              subtitle: '${MediaAsset.kindNames[m.kind] ?? ''} · ${formatBytes(size)}${m.inCloud ? ' · 云端已有，直接删除本机副本' : ''}',
              onTap: busy ? null : () => setState(() => picked.contains(m.id) ? picked.remove(m.id) : picked.add(m.id)),
              trailing: Checkbox(
                value: picked.contains(m.id),
                activeColor: M.sageDark,
                onChanged: busy ? null : (v) => setState(() => v == true ? picked.add(m.id) : picked.remove(m.id)),
              ),
            ),
        ]),
      if (status != null) ...[
        const SizedBox(height: 12),
        Text(status!, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: frac, color: M.sage, backgroundColor: M.glass.withValues(alpha: 0.5)),
      ],
      const SizedBox(height: 14),
      GlassButton(
        label: busy ? '正在上传…' : '上传并释放 ${formatBytes(total)}',
        icon: Icons.cloud_upload_outlined,
        tint: M.sage,
        expand: true,
        onTap: busy || total == 0 ? null : _go,
      ),
    ]);
  }
}

/// 删除资料 / 项目前询问：云端也有文件时，是否一起删除（默认勾选，避免继续占用存储费用）。
/// 返回 null = 取消；true / false = 是否删除云端文件。
Future<bool?> confirmDeleteWithCloud(BuildContext context, {required String title, required String content, required int cloudFiles}) {
  var remote = true;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        backgroundColor: M.sheet,
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(content),
          if (cloudFiles > 0)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: M.sageDark,
              value: remote,
              onChanged: (v) => set(() => remote = v ?? true),
              title: Text('同时删除云端的 $cloudFiles 个文件', style: const TextStyle(fontSize: 14)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, cloudFiles > 0 && remote), child: Text('删除', style: TextStyle(color: M.roseDark))),
        ],
      ),
    ),
  );
}
