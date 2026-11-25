import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/study.dart';
import '../theme/glass.dart';
import 'explain_sheet.dart' show showSourceSheet;
import 'favorites_page.dart' show FavoriteButton;
import 'settings_pages.dart' show saveOrShareFile;

/// 横向树布局：根在左，子节点向右展开；兄弟子树上下排开不重叠，父节点在子树中间，连线是三次贝塞尔曲线。
class MindTreeLayout extends MultiChildRenderObjectWidget {
  final List<int> parents; // 每个子部件的父节点下标，根为 -1（先序排列）
  final Color lineColor;
  final double hGap;
  final double vGap;
  const MindTreeLayout({super.key, required this.parents, required this.lineColor, this.hGap = 28, this.vGap = 10, super.children});

  @override
  RenderMindTree createRenderObject(BuildContext context) => RenderMindTree(parents, lineColor, hGap, vGap);

  @override
  void updateRenderObject(BuildContext context, RenderMindTree renderObject) {
    renderObject
      ..parents = parents
      ..lineColor = lineColor
      ..hGap = hGap
      ..vGap = vGap;
  }
}

class MindParentData extends ContainerBoxParentData<RenderBox> {}

class RenderMindTree extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, MindParentData>, RenderBoxContainerDefaultsMixin<RenderBox, MindParentData> {
  RenderMindTree(this._parents, this._lineColor, this._hGap, this._vGap);
  List<int> _parents;
  Color _lineColor;
  double _hGap, _vGap;
  set parents(List<int> v) {
    _parents = v;
    markNeedsLayout();
  }

  set lineColor(Color v) {
    _lineColor = v;
    markNeedsPaint();
  }

  set hGap(double v) {
    _hGap = v;
    markNeedsLayout();
  }

  set vGap(double v) {
    _vGap = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MindParentData) child.parentData = MindParentData();
  }

  @override
  void performLayout() {
    final kids = getChildrenAsList();
    final n = kids.length;
    if (n == 0) {
      size = constraints.smallest;
      return;
    }
    final sizes = [for (final k in kids) (k..layout(const BoxConstraints(maxWidth: 200), parentUsesSize: true)).size];
    final children = List.generate(n, (_) => <int>[]);
    for (var i = 0; i < n && i < _parents.length; i++) {
      if (_parents[i] >= 0) children[_parents[i]].add(i);
    }
    final h = List<double>.filled(n, 0);
    double measure(int i) {
      final cs = children[i];
      var sum = 0.0;
      for (final c in cs) {
        sum += measure(c);
      }
      if (cs.isNotEmpty) sum += _vGap * (cs.length - 1);
      return h[i] = sum > sizes[i].height ? sum : sizes[i].height;
    }

    measure(0);
    var maxX = 0.0;
    void place(int i, double x, double top) {
      final pd = kids[i].parentData as MindParentData;
      pd.offset = Offset(x, top + (h[i] - sizes[i].height) / 2);
      if (x + sizes[i].width > maxX) maxX = x + sizes[i].width;
      final cs = children[i];
      var total = 0.0;
      for (final c in cs) {
        total += h[c];
      }
      total += cs.isEmpty ? 0 : _vGap * (cs.length - 1);
      var y = top + (h[i] - total) / 2;
      for (final c in cs) {
        place(c, x + sizes[i].width + _hGap, y);
        y += h[c] + _vGap;
      }
    }

    place(0, 0, 0);
    size = constraints.constrain(Size(maxX, h[0]));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final kids = getChildrenAsList();
    final paint = Paint()
      ..color = _lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final canvas = context.canvas;
    for (var i = 0; i < kids.length && i < _parents.length; i++) {
      final p = _parents[i];
      if (p < 0) continue;
      final a = (kids[p].parentData as MindParentData).offset + offset, b = (kids[i].parentData as MindParentData).offset + offset;
      final from = Offset(a.dx + kids[p].size.width, a.dy + kids[p].size.height / 2);
      final to = Offset(b.dx, b.dy + kids[i].size.height / 2);
      final mid = (from.dx + to.dx) / 2;
      canvas.drawPath(
          Path()
            ..moveTo(from.dx, from.dy)
            ..cubicTo(mid, from.dy, mid, to.dy, to.dx, to.dy),
          paint);
    }
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);
}

/// 一个节点的外观：根节点是灰绿底白字，第一层浅燕麦，其余是普通玻璃块；收起的分支显示子节点数。
class MindNodeBox extends StatelessWidget {
  final MindNode node;
  final int depth;
  final bool collapsed;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onToggle;
  const MindNodeBox({super.key, required this.node, required this.depth, this.collapsed = false, this.selected = false, this.onTap, this.onToggle});

  @override
  Widget build(BuildContext context) {
    final root = depth == 0;
    final color = root ? Colors.white : M.text;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(
        child: Glass(
          radius: 14,
          tint: root ? M.sage : (depth == 1 ? M.oat : null),
          padding: EdgeInsets.symmetric(horizontal: root ? 14 : 12, vertical: root ? 10 : 7),
          onTap: onTap,
          child: Container(
            decoration: selected ? BoxDecoration(border: Border(bottom: BorderSide(color: M.sageDark, width: 2))) : null,
            child: MathText(node.text.isEmpty ? '（空）' : node.text,
                style: TextStyle(fontSize: root ? 15 : (depth == 1 ? 14 : 13), fontWeight: depth <= 1 ? FontWeight.w700 : FontWeight.w500, color: color)),
          ),
        ),
      ),
      if (node.children.isNotEmpty)
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Container(
              constraints: const BoxConstraints(minWidth: 18),
              height: 18,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(color: M.glass.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(9), border: Border.all(color: M.sage)),
              child: Text(collapsed ? '${node.count - 1}' : '−', style: TextStyle(fontSize: 10, height: 1.1, color: M.sageDark, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
    ]);
  }
}

/// 思维导图页：缩放、拖动、展开收起；点节点看说明、查看原文、问 AI、收藏、编辑、增删节点。
class MindMapPage extends StatefulWidget {
  final ChapterMindMap map;
  final void Function(String question)? onAsk; // 「问 AI」：交给学习板块的 AI 伴学
  const MindMapPage({super.key, required this.map, this.onAsk});
  @override
  State<MindMapPage> createState() => _MindMapPageState();
}

class _MindMapPageState extends State<MindMapPage> {
  late ChapterMindMap map = widget.map;
  final collapsed = <String>{};
  final view = TransformationController();
  final shot = GlobalKey();
  final viewport = GlobalKey();
  String? selected;

  Future<void> _save() async {
    map
      ..edited = true
      ..updatedAt = DateTime.now();
    await context.read<AppState>().repo.saveMindMap(map);
    if (mounted) setState(() {});
  }

  /// 先序遍历可见节点，得到 (节点, 父下标, 深度)。
  List<(MindNode, int, int)> _visible() {
    final out = <(MindNode, int, int)>[];
    void walk(MindNode n, int parent, int depth) {
      final i = out.length;
      out.add((n, parent, depth));
      if (collapsed.contains(n.id)) return;
      for (final c in n.children) {
        walk(c, i, depth + 1);
      }
    }

    walk(map.root, -1, 0);
    return out;
  }

  Future<(String, String)?> _editDialog({String title = '编辑节点', String text = '', String note = ''}) {
    final t = TextEditingController(text: text), n = TextEditingController(text: note);
    return showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: M.sheet,
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: t, autofocus: true, decoration: const InputDecoration(labelText: '标题', hintText: r'可以用 $...$ 写公式')),
          const SizedBox(height: 8),
          TextField(controller: n, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: '说明（可选）')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, (t.text.trim(), n.text.trim())), child: const Text('保存')),
        ],
      ),
    );
  }

  Future<void> _add(MindNode parent) async {
    final r = await _editDialog(title: '添加子节点');
    if (r == null || r.$1.isEmpty) return;
    parent.children.add(MindNode(text: r.$1, note: r.$2));
    collapsed.remove(parent.id);
    await _save();
  }

  Future<void> _addSibling(MindNode node) async {
    final parent = map.root.parentOf(node.id);
    if (parent == null) return;
    final r = await _editDialog(title: '添加同级节点');
    if (r == null || r.$1.isEmpty) return;
    parent.children.insert(parent.children.indexOf(node) + 1, MindNode(text: r.$1, note: r.$2));
    await _save();
  }

  Future<void> _edit(MindNode node) async {
    final r = await _editDialog(text: node.text, note: node.note);
    if (r == null || r.$1.isEmpty) return;
    node
      ..text = r.$1
      ..note = r.$2;
    await _save();
  }

  Future<void> _delete(MindNode node) async {
    final parent = map.root.parentOf(node.id);
    if (parent == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: M.sheet,
        title: const Text('删除节点'),
        content: Text(node.children.isEmpty ? '删除「${node.text}」？' : '删除「${node.text}」和它下面的 ${node.count - 1} 个节点？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('删除', style: TextStyle(color: M.roseDark))),
        ],
      ),
    );
    if (ok != true) return;
    parent.children.remove(node);
    await _save();
  }

  void _openNode(MindNode node) {
    setState(() => selected = node.id);
    final s = context.read<AppState>();
    final isRoot = node.id == map.root.id;
    showGlassSheet(context, (ctx, sc) {
      void act(Future<void> Function() f) {
        Navigator.pop(ctx);
        f();
      }

      return ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: MathText(node.text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
          if (node.kpId.isNotEmpty) FavoriteButton(kind: 'kp', targetId: node.kpId, projectId: map.projectId, title: node.text),
        ]),
        if (node.note.isNotEmpty) ...[
          const SizedBox(height: 8),
          MathText(node.note, style: const TextStyle(fontSize: 15, height: 1.6)),
        ],
        if (node.page > 0) ...[
          const SizedBox(height: 8),
          Text('出处：${s.sourceLabel(map.docId, node.page, map.chapter)}', style: TextStyle(color: M.sub, fontSize: 13)),
        ],
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (widget.onAsk != null)
            GlassButton(
                label: '让 AI 讲透',
                icon: Icons.auto_awesome_rounded,
                tint: M.sage,
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                  widget.onAsk!('请结合教材讲透「${node.text}」${node.note.isEmpty ? '' : '（${node.note}）'}：它是什么、为什么成立、怎么用，再举一个例子。');
                }),
          if (node.page > 0)
            GlassButton(
                label: '查看原文',
                icon: Icons.menu_book_outlined,
                onTap: () => showSourceSheet(ctx, docId: map.docId, page: node.page, chapter: map.chapter)),
          GlassButton(label: '编辑', icon: Icons.edit_outlined, onTap: () => act(() => _edit(node))),
          GlassButton(label: '添加子节点', icon: Icons.add_rounded, onTap: () => act(() => _add(node))),
          if (!isRoot) GlassButton(label: '添加同级', icon: Icons.playlist_add_rounded, onTap: () => act(() => _addSibling(node))),
          if (!isRoot)
            GlassButton(label: '删除', icon: Icons.delete_outline_rounded, fg: M.roseDark, onTap: () => act(() => _delete(node))),
        ]),
      ]);
    }, initial: 0.45).then((_) {
      if (mounted) setState(() => selected = null);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  @override
  void dispose() {
    view.dispose();
    super.dispose();
  }

  /// 尽量整张显示（最小缩到 0.7 倍保证文字看得清，更大的导图可以拖动查看），放得下时居中。
  void _fit() {
    final tree = shot.currentContext?.findRenderObject() as RenderBox?;
    final port = viewport.currentContext?.findRenderObject() as RenderBox?;
    if (tree == null || port == null || !tree.hasSize || !port.hasSize) return;
    final t = tree.size, p = port.size;
    final k = [p.width / t.width, p.height / t.height, 1.0].reduce((a, b) => a < b ? a : b).clamp(0.7, 1.0);
    final dx = t.width * k < p.width ? (p.width - t.width * k) / 2 : 0.0;
    final dy = t.height * k < p.height ? (p.height - t.height * k) / 2 : 0.0;
    view.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1);
  }

  Future<void> _shareImage() async {
    final b = shot.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (b == null) return;
    final img = await b.toImage(pixelRatio: 2.5);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || !mounted) return;
    final name = '${map.chapter}-思维导图.png'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    await saveOrShareFile(context, data.buffer.asUint8List(), name, title: '导图图片已生成', mimeType: 'image/png');
  }

  @override
  Widget build(BuildContext context) {
    final nodes = _visible();
    return GlassScaffold(
      title: map.chapter,
      actions: [
        IconButton(tooltip: '整张显示', icon: const Icon(Icons.center_focus_strong_outlined), onPressed: _fit),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz_rounded),
          onSelected: (v) async {
            if (v == 'expand') setState(collapsed.clear);
            if (v == 'collapse') {
              setState(() {
                collapsed
                  ..clear()
                  ..addAll([for (final c in map.root.children) if (c.children.isNotEmpty) c.id]);
              });
            }
            if (v == 'expand' || v == 'collapse') WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
            if (v == 'image') await _shareImage();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'expand', child: Text('全部展开')),
            PopupMenuItem(value: 'collapse', child: Text('只看第一层')),
            PopupMenuItem(value: 'image', child: Text('保存为图片')),
          ],
        ),
      ],
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text('${map.root.count - 1} 个节点${map.edited ? ' · 已手动修改' : ''} · 点节点查看、编辑，双指缩放',
              style: TextStyle(color: M.sub, fontSize: 12)),
        ),
        Expanded(
          child: InteractiveViewer(
            key: viewport,
            transformationController: view,
            constrained: false,
            minScale: 0.3,
            maxScale: 2.5,
            boundaryMargin: const EdgeInsets.all(600),
            child: RepaintBoundary(
              key: shot,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 40, 40),
                child: MindTreeLayout(
                  parents: [for (final n in nodes) n.$2],
                  lineColor: M.sage.withValues(alpha: 0.7),
                  children: [
                    for (final (n, _, d) in nodes)
                      MindNodeBox(
                        node: n,
                        depth: d,
                        collapsed: collapsed.contains(n.id),
                        selected: selected == n.id,
                        onTap: () => _openNode(n),
                        onToggle: () => setState(() => collapsed.contains(n.id) ? collapsed.remove(n.id) : collapsed.add(n.id)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// 新建一张空导图（自己画）。
ChapterMindMap emptyMindMap(StudyChapter c) =>
    ChapterMindMap(projectId: c.doc.projectId, docId: c.doc.id, chapter: c.title, root: MindNode(text: c.title), edited: true);
