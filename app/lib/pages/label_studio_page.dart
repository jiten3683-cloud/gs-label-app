import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../models/label_element.dart';
import '../services/db_service.dart';
import '../widgets/ai_generate_dialog.dart';
import '../widgets/label_canvas.dart';

// ─── Sample data ──────────────────────────────────────────────────────────────
LabelContext get _sampleCtx => const LabelContext(
  netStr: '5.200 g',   grossStr: '5.850 g',  tareStr: '0.650 g',
  stoneStr: '0.100 g', metalStr: '5.100 g',  serial: 'GS-00001',
  dateStr: '14-05-26', timeStr: '10:30',
  product: 'Gold Ring', purity: '22K',
  hsn: '7113', category: 'Rings', code: 'RNG001',
  rateStr: '6500.00', amountStr: '33150.00', makingStr: '1650.00',
  shopName: 'Sharma Jewels', companyName: 'Sharma & Sons Pvt Ltd',
  companyAddress: '12, Gold Market, Mumbai', companyPhone: '+91-9876543210',
  companyGst: '27AAAAA0000A1Z5',
);

const _varGroups = [
  ('Weight',  ['{net}','{gross}','{tare}','{stone}','{metal}']),
  ('Product', ['{product}','{purity}','{hsn}','{category}','{code}']),
  ('Pricing', ['{rate}','{amount}','{making}']),
  ('Print',   ['{serial}','{date}','{time}']),
  ('Shop',    ['{shop}','{company}','{address}','{phone}','{gst}']),
];

const _varHints = <String, String>{
  '{net}':'Net weight', '{gross}':'Gross weight', '{tare}':'Tare weight',
  '{stone}':'Stone wt', '{metal}':'Metal net',    '{product}':'Product name',
  '{purity}':'Purity',  '{hsn}':'HSN code',       '{category}':'Category',
  '{code}':'SKU/code',  '{rate}':'Rate/gram',      '{amount}':'Total amount',
  '{making}':'Making',  '{serial}':'Serial no.',   '{date}':'Print date',
  '{time}':'Print time',
  '{shop}':'Shop/display name', '{company}':'Legal company name',
  '{address}':'Business address', '{phone}':'Phone number',
  '{gst}':'GST number',
};

// ═════════════════════════════════════════════════════════════════════════════
//  Template List
// ═════════════════════════════════════════════════════════════════════════════
class LabelStudioPage extends StatefulWidget {
  const LabelStudioPage({super.key});
  @override State<LabelStudioPage> createState() => _LabelStudioState();
}

class _LabelStudioState extends State<LabelStudioPage> {
  List<Map<String, dynamic>> _templates = [];
  bool _loaded = false;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    _templates = await context.read<DbService>().listTemplates();
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _delete(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Template'),
        content: Text('Delete "$name"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<DbService>().deleteTemplate(id);
      _load();
    }
  }

  // ── Export / Import ──────────────────────────────────────────────────────────

  Map<String, dynamic> _toExportMap(Map<String, dynamic> r) {
    dynamic jsonData;
    try { jsonData = jsonDecode(r['json'] as String? ?? '[]'); } catch (_) { jsonData = []; }
    dynamic linesData;
    try { linesData = jsonDecode(r['lines'] as String? ?? '[]'); } catch (_) { linesData = []; }
    return {
      'name':      r['name'],
      'width_mm':  r['width_mm'],
      'height_mm': r['height_mm'],
      'gap_mm':    r['gap_mm'] ?? 3,
      'json':      jsonData,
      'lines':     linesData,
    };
  }

  Future<void> _exportTemplate(Map<String, dynamic> row) async {
    final payload = jsonEncode({
      'format': 'jbc-gs-template',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'templates': [_toExportMap(row)],
    });
    final safeName = (row['name'] as String)
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(' ', '_');
    await _shareJson(payload, 'jbc_template_$safeName.json');
  }

  Future<void> _exportAll() async {
    if (_templates.isEmpty) return;
    final payload = jsonEncode({
      'format': 'jbc-gs-template',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'templates': _templates.map(_toExportMap).toList(),
    });
    await _shareJson(payload, 'jbc_templates_all.json');
  }

  Future<void> _shareJson(String content, String fileName) async {
    try {
      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(content);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'JBC Template Export'),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _importTemplates() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['json'],
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Cannot open file picker: $e')));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    try {
      final data = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      if (data['format'] != 'jbc-gs-template') throw const FormatException('Not a JBC template file');
      final list = (data['templates'] as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) throw const FormatException('No templates found in file');
      final db = context.read<DbService>();
      for (final t in list) {
        final linesRaw = t['lines'];
        List<String>? lines;
        if (linesRaw is List) lines = linesRaw.map((e) => e.toString()).toList();
        await db.saveTemplate(
          name:  t['name']      as String? ?? 'Imported Template',
          wMm:   (t['width_mm']  as num?)?.toInt() ?? 50,
          hMm:   (t['height_mm'] as num?)?.toInt() ?? 25,
          gapMm: (t['gap_mm']    as num?)?.toInt() ?? 3,
          json:  t['json'] ?? [],
          lines: lines,
        );
      }
      _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${list.length} template(s) imported')));
    } on FormatException catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Invalid file: ${e.message}')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Future<void> _openAiGenerator() async {
    // Step 1: pick label size
    int wMm = 50, hMm = 25;
    final sizes = await showDialog<(int, int)>(
      context: context,
      builder: (_) => _SizePicker(initialW: wMm, initialH: hMm),
    );
    if (sizes == null || !mounted) return;
    (wMm, hMm) = sizes;

    // Step 2: show AI dialog
    final elements = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => AiGenerateDialog(widthMm: wMm, heightMm: hMm),
    );
    if (elements == null || elements.isEmpty || !mounted) return;

    // Step 3: open editor with AI-generated elements as an unsaved template
    final fakeRow = <String, dynamic>{
      'name':      'AI Generated',
      'width_mm':  wMm,
      'height_mm': hMm,
      'gap_mm':    3,
      'json':      jsonEncode(elements),
      'lines':     '[]',
      'updated':   DateTime.now().millisecondsSinceEpoch,
    };
    _openEditor(row: fakeRow);
  }

  void _openEditor({Map<String, dynamic>? row}) async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => Provider.value(
        value: context.read<DbService>(),
        child: _LabelEditorPage(initialRow: row),
      ),
    ));
    _load();
  }

  List<Map<String, dynamic>> _resolveRow(Map<String, dynamic> row) {
    try {
      final list = jsonDecode(row['json'] as String? ?? '[]') as List;
      return list.whereType<Map<String, dynamic>>()
          .map((m) => _fromMap(m).toJson(_sampleCtx)).toList();
    } catch (_) { return []; }
  }

  LabelElement _fromMap(Map<String, dynamic> m) {
    final t = ElType.values.firstWhere(
        (e) => e.name == (m['t'] as String? ?? 'text'), orElse: () => ElType.text);
    return LabelElement(
      type: t, x: m['x'] as int? ?? 10, y: m['y'] as int? ?? 10,
      text: m['text'] as String? ?? '', font: m['font'] as String? ?? '3',
      xScale: m['xs'] as int? ?? 1, yScale: m['ys'] as int? ?? 1,
      rotation: m['rot'] as int? ?? 0, data: m['data'] as String? ?? '',
      barcodeType: m['btype'] as String? ?? '128',
      barcodeHeight: m['bh'] as int? ?? 60, barcodeWidth: m['bw'] as int? ?? 120,
      qrEcc: m['ecc'] as String? ?? 'M', qrSize: m['qs'] as int? ?? 4,
      xEnd: m['xe'] as int? ?? 100, yEnd: m['ye'] as int? ?? 50,
      thickness: m['th'] as int? ?? 2,
      prefix: m['pre'] as String? ?? '', suffix: m['suf'] as String? ?? '',
      logoPath: m['logo_path'] as String? ?? '',
      logoBmpHex: m['logo_bmp'] as String? ?? '',
      logoBmpW: m['logo_bmpw'] as int? ?? 0,
      logoWidthDots: m['logo_w'] as int? ?? 80,
      logoHeightDots: m['logo_h'] as int? ?? 48,
    );
  }

  @override Widget build(BuildContext context) {
    final fmt = DateFormat('dd-MMM-yy');
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    if (_templates.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.label_outline, size: 72, color: Colors.grey),
        const SizedBox(height: 16),
        const Text('No templates yet', style: TextStyle(fontSize: 18, color: Colors.grey)),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => _openEditor(),
          icon: const Icon(Icons.add), label: const Text('Create First Template'),
        ),
      ]));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: Column(children: [
        // ── Import / Export All bar ──────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Import'),
                onPressed: _importTemplates,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.share, size: 18),
                label: const Text('Export All'),
                onPressed: _templates.isEmpty ? null : _exportAll,
              ),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: Stack(children: [
        GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, childAspectRatio: 1.3,
              crossAxisSpacing: 10, mainAxisSpacing: 10),
          itemCount: _templates.length,
          itemBuilder: (_, i) {
            final r    = _templates[i];
            final id   = r['id']       as int;
            final name = r['name']     as String;
            final wMm  = r['width_mm'] as int? ?? 50;
            final hMm  = r['height_mm']as int? ?? 25;
            final upd  = DateTime.fromMillisecondsSinceEpoch(r['updated'] as int);
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _openEditor(row: r),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Container(
                    color: Colors.grey.shade100, width: double.infinity,
                    padding: const EdgeInsets.all(6),
                    child: Center(child: LabelCanvas(
                        elements: _resolveRow(r), wMm: wMm, hMm: hMm)),
                  )),
                  Container(padding: const EdgeInsets.fromLTRB(8,4,4,4),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                          Text('$wMm×$hMm mm • ${fmt.format(upd)}',
                              style: const TextStyle(fontSize: 10, color: Colors.grey)),
                        ],
                      )),
                      IconButton(
                        icon: const Icon(Icons.ios_share, size: 18),
                        tooltip: 'Share / Export',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        onPressed: () => _exportTemplate(r),
                      ),
                      PopupMenuButton<String>(iconSize: 18,
                        onSelected: (v) {
                          if (v == 'edit')      _openEditor(row: r);
                          if (v == 'duplicate') context.read<DbService>().duplicateTemplate(id).then((_) => _load());
                          if (v == 'export')    _exportTemplate(r);
                          if (v == 'delete')    _delete(id, name);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit',
                              child: ListTile(leading: Icon(Icons.edit, size: 18), title: Text('Edit'), dense: true)),
                          PopupMenuItem(value: 'duplicate',
                              child: ListTile(leading: Icon(Icons.copy, size: 18), title: Text('Duplicate'), dense: true)),
                          PopupMenuItem(value: 'export',
                              child: ListTile(leading: Icon(Icons.share, size: 18), title: Text('Export'), dense: true)),
                          PopupMenuItem(value: 'delete',
                              child: ListTile(leading: Icon(Icons.delete, size: 18, color: Colors.red),
                                  title: Text('Delete', style: TextStyle(color: Colors.red)), dense: true)),
                        ],
                      ),
                    ]),
                  ),
                ]),
              ),
            );
          },
        ),
        Positioned(
          right: 16, bottom: 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FloatingActionButton.extended(
              heroTag: 'fab_ai',
              onPressed: _openAiGenerator,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('AI Generate'),
              backgroundColor: Colors.amber.shade700,
              foregroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            FloatingActionButton.extended(
              heroTag: 'fab_new',
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('New Template'),
            ),
          ]),
        ),
      ])),   // Stack + Expanded
      ]),    // Column
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Size picker dialog used before AI generation
// ─────────────────────────────────────────────────────────────────────────────
class _SizePicker extends StatefulWidget {
  final int initialW, initialH;
  const _SizePicker({required this.initialW, required this.initialH});
  @override State<_SizePicker> createState() => _SizePickerState();
}

class _SizePickerState extends State<_SizePicker> {
  late int _w, _h;
  static const _presets = [
    ('50 × 25 mm', 50, 25),
    ('60 × 30 mm', 60, 30),
    ('80 × 40 mm', 80, 40),
    ('100 × 50 mm', 100, 50),
  ];

  @override void initState() {
    super.initState();
    _w = widget.initialW;
    _h = widget.initialH;
  }

  @override Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(children: [
        Icon(Icons.auto_awesome, color: Colors.amber),
        SizedBox(width: 8),
        Text('Label Size for AI'),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Choose a size or set custom dimensions:',
            style: TextStyle(fontSize: 13)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: _presets.map((p) {
          final selected = _w == p.$2 && _h == p.$3;
          return ChoiceChip(
            label: Text(p.$1),
            selected: selected,
            onSelected: (_) => setState(() { _w = p.$2; _h = p.$3; }),
          );
        }).toList()),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _IntInput(label: 'Width (mm)', value: _w,
              onChanged: (v) => setState(() => _w = v))),
          const SizedBox(width: 12),
          Expanded(child: _IntInput(label: 'Height (mm)', value: _h,
              onChanged: (v) => setState(() => _h = v))),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, (_w, _h)),
          icon: const Icon(Icons.auto_awesome, size: 16),
          label: const Text('Next: Describe Label'),
        ),
      ],
    );
  }
}

class _IntInput extends StatefulWidget {
  final String label; final int value; final ValueChanged<int> onChanged;
  const _IntInput({required this.label, required this.value, required this.onChanged});
  @override State<_IntInput> createState() => _IntInputState();
}
class _IntInputState extends State<_IntInput> {
  late final TextEditingController _c;
  @override void initState() { super.initState(); _c = TextEditingController(text: '${widget.value}'); }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => TextField(
    controller: _c, keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: widget.label, border: const OutlineInputBorder(), isDense: true),
    onChanged: (s) { final v = int.tryParse(s); if (v != null && v > 0) widget.onChanged(v); },
  );
}

// ═════════════════════════════════════════════════════════════════════════════
//  Label Editor (pushed as full-screen route)
// ═════════════════════════════════════════════════════════════════════════════
class _LabelEditorPage extends StatefulWidget {
  final Map<String, dynamic>? initialRow;
  const _LabelEditorPage({this.initialRow});
  @override State<_LabelEditorPage> createState() => _LabelEditorState();
}

class _LabelEditorState extends State<_LabelEditorPage> {
  int?   _editingId;
  int    _wMm = 50, _hMm = 25, _gap = 3;
  final  _nameCtrl = TextEditingController(text: '');
  final  List<LabelElement> _elements = [];
  LabelElement? _selected;
  Object _inspKey = Object();

  // Focus tracking for variable insertion
  TextEditingController? _focusedCtrl;

  // Zoom
  final _transformCtrl = TransformationController();
  bool  _elemDragging  = false;
  double get _zoom => _transformCtrl.value.getMaxScaleOnAxis();

  // Grid snap (1 mm = 8 dots)
  bool _snapGrid = false;
  int  _snap(double v) => _snapGrid ? (v / 8).round() * 8 : v.round();

  @override
  void initState() {
    super.initState();
    if (widget.initialRow != null) {
      _applyRow(widget.initialRow!);
    }
    _transformCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  void _applyRow(Map<String, dynamic> row) {
    _nameCtrl.text = row['name']      as String? ?? 'Template';
    _wMm           = row['width_mm']  as int?    ?? 50;
    _hMm           = row['height_mm'] as int?    ?? 25;
    _gap           = row['gap_mm']    as int?    ?? 3;
    _editingId     = row['id']        as int?;
    _elements.clear(); _selected = null;
    try {
      final raw  = row['json'];
      final list = raw is String ? (jsonDecode(raw) as List) : (raw as List? ?? []);
      for (final m in list.whereType<Map<String, dynamic>>()) {
        _elements.add(_fromMap(m));
      }
    } catch (_) {}
  }

  LabelElement _fromMap(Map<String, dynamic> m) {
    final t = ElType.values.firstWhere(
        (e) => e.name == (m['t'] as String? ?? 'text'), orElse: () => ElType.text);
    return LabelElement(
      type: t, x: m['x'] as int? ?? 10, y: m['y'] as int? ?? 10,
      text: m['text'] as String? ?? '', font: m['font'] as String? ?? '3',
      xScale: m['xs'] as int? ?? 1, yScale: m['ys'] as int? ?? 1,
      rotation: m['rot'] as int? ?? 0, data: m['data'] as String? ?? '',
      barcodeType: m['btype'] as String? ?? '128',
      barcodeHeight: m['bh'] as int? ?? 60, barcodeWidth: m['bw'] as int? ?? 120,
      qrEcc: m['ecc'] as String? ?? 'M', qrSize: m['qs'] as int? ?? 4,
      xEnd: m['xe'] as int? ?? 100, yEnd: m['ye'] as int? ?? 50,
      thickness: m['th'] as int? ?? 2,
      prefix: m['pre'] as String? ?? '', suffix: m['suf'] as String? ?? '',
      logoPath: m['logo_path'] as String? ?? '',
      logoBmpHex: m['logo_bmp'] as String? ?? '',
      logoBmpW: m['logo_bmpw'] as int? ?? 0,
      logoWidthDots: m['logo_w'] as int? ?? 80,
      logoHeightDots: m['logo_h'] as int? ?? 48,
    );
  }

  Map<String, dynamic> _toMap(LabelElement el) => {
    't': el.type.name, 'x': el.x, 'y': el.y,
    'text': el.text, 'font': el.font, 'xs': el.xScale, 'ys': el.yScale, 'rot': el.rotation,
    'data': el.data, 'btype': el.barcodeType, 'bh': el.barcodeHeight, 'bw': el.barcodeWidth,
    'ecc': el.qrEcc, 'qs': el.qrSize,
    'xe': el.xEnd, 'ye': el.yEnd, 'th': el.thickness,
    'pre': el.prefix, 'suf': el.suffix,
    // Logo fields
    'logo_path': el.logoPath, 'logo_bmp': el.logoBmpHex, 'logo_bmpw': el.logoBmpW,
    'logo_w': el.logoWidthDots, 'logo_h': el.logoHeightDots,
  };

  Future<void> _save() async {
    var name = _nameCtrl.text.trim();
    // Prompt for name when blank or still the default placeholder
    if (name.isEmpty) {
      final entered = await showDialog<String>(
        context: context,
        builder: (_) {
          final c = TextEditingController();
          return AlertDialog(
            title: const Text('Template Name'),
            content: TextField(
              controller: c, autofocus: true,
              decoration: const InputDecoration(hintText: 'e.g. Gold Ring 50×25'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()),
                  child: const Text('Save')),
            ],
          );
        },
      );
      if (entered == null || entered.isEmpty) return;
      name = entered;
      _nameCtrl.text = name;
    }

    final db = context.read<DbService>();
    final id = await db.saveTemplate(
      id: _editingId, name: name,
      wMm: _wMm, hMm: _hMm, gapMm: _gap,
      json: _elements.map(_toMap).toList(),
    );
    setState(() => _editingId = id);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved "$name"'), duration: const Duration(seconds: 1)));
  }

  void _add(ElType t) {
    // Smart placement: stack below last element, centered horizontally
    final usedY = _elements.isEmpty ? 0 : _elements.map((e) => e.y).reduce((a, b) => a > b ? a : b) + 32;
    final cx    = _wMm * 8 ~/ 2;
    final el = LabelElement(type: t, x: 16, y: usedY.clamp(0, _hMm * 8 - 24));
    switch (t) {
      case ElType.text:     el.text   = '{product} {purity}'; el.x = 8;
      case ElType.weight:   el.prefix = 'Net: '; el.x = 8;
      case ElType.serial:   el.prefix = 'SN: '; el.x = 8;
      case ElType.dateTime: el.prefix = ''; el.x = 8;
      case ElType.qr:
        el.data = '{serial}|{net}|{product}';
        el.x = (_wMm * 8 - el.qrSize * 16) ~/ 2;  // center
      case ElType.bar:
        el.data = '{serial}'; el.barcodeWidth = (_wMm * 8 - 32).clamp(80, 400);
        el.x = 16; el.barcodeHeight = 48;
      case ElType.box:
        el.x = 0; el.y = 0;
        el.xEnd = _wMm * 8; el.yEnd = _hMm * 8;
      case ElType.logo:     el.x = cx - 30;
    }
    setState(() { _elements.add(el); _selected = el; _inspKey = Object(); });
  }

  // ── Alignment helpers ────────────────────────────────────────────────────────
  int _elW(LabelElement el) => switch (el.type) {
    ElType.bar  => el.barcodeWidth,
    ElType.qr   => el.qrSize * 16,
    ElType.box  => (el.xEnd - el.x).abs(),
    ElType.logo => el.logoWidthDots,
    _           => ((el.text.isEmpty ? 6 : el.text.length + el.prefix.length + el.suffix.length) *
                    (kFontDotH[el.font] ?? 24) * 0.55 * el.xScale).round().clamp(16, _wMm * 8),
  };
  int _elH(LabelElement el) => switch (el.type) {
    ElType.bar  => el.barcodeHeight,
    ElType.qr   => el.qrSize * 16,
    ElType.box  => (el.yEnd - el.y).abs(),
    ElType.logo => el.logoHeightDots,
    _           => ((kFontDotH[el.font] ?? 24) * el.yScale).clamp(12, _hMm * 8),
  };

  void _align(String dir) {
    final el = _selected; if (el == null) return;
    final w = _elW(el); final h = _elH(el);
    final lw = _wMm * 8; final lh = _hMm * 8;
    setState(() {
      switch (dir) {
        case 'L':  el.x = 0;
        case 'CH': el.x = ((lw - w) ~/ 2).clamp(0, lw);
        case 'R':  el.x = (lw - w).clamp(0, lw);
        case 'T':  el.y = 0;
        case 'CV': el.y = ((lh - h) ~/ 2).clamp(0, lh);
        case 'B':  el.y = (lh - h).clamp(0, lh);
      }
    });
  }

  void _zoomSet(double z) {
    final clamped = z.clamp(0.25, 8.0);
    _transformCtrl.value = Matrix4.diagonal3Values(clamped, clamped, 1.0);
  }

  Future<void> _pickAndProcessLogo(LabelElement el) async {
    final xfile = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (xfile == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Processing image…'), duration: Duration(seconds: 60)));
    try {
      final bytes   = await xfile.readAsBytes();
      img.Image? src = img.decodeImage(bytes);
      if (src == null) throw Exception('Cannot decode image');

      final wDots = el.logoWidthDots.clamp(8, 2400);
      final hDots = el.logoHeightDots.clamp(8, 1600);
      final resized = img.copyResize(src, width: wDots, height: hDots,
          interpolation: img.Interpolation.linear);

      // Save display copy to app documents/logos/
      final dir     = await getApplicationDocumentsDirectory();
      final logoDir = Directory(p.join(dir.path, 'logos'));
      await logoDir.create(recursive: true);
      final file = File(p.join(logoDir.path, '${DateTime.now().millisecondsSinceEpoch}.png'));
      await file.writeAsBytes(img.encodePng(resized));

      // Convert to TSPL BITMAP (1-bit per pixel, MSB first, white=0, black=1)
      final wBytes = (wDots + 7) ~/ 8;
      final sb = StringBuffer();
      for (int row = 0; row < hDots; row++) {
        int byteVal = 0, bitPos = 7;
        for (int col = 0; col < wDots; col++) {
          final px  = resized.getPixel(col, row);
          final lum = (px.r.toInt() * 299 + px.g.toInt() * 587 + px.b.toInt() * 114) ~/ 1000;
          if (lum < 128) byteVal |= (1 << bitPos);   // dark → black → bit=1
          bitPos--;
          if (bitPos < 0) {
            sb.write(byteVal.toRadixString(16).padLeft(2, '0').toUpperCase());
            byteVal = 0; bitPos = 7;
          }
        }
        if (wDots % 8 != 0) {                          // flush last partial byte
          sb.write(byteVal.toRadixString(16).padLeft(2, '0').toUpperCase());
        }
      }

      if (mounted) setState(() {
        el.logoPath      = file.path;
        el.logoBmpHex    = sb.toString();
        el.logoBmpW      = wBytes;
        el.logoWidthDots = wDots;
        el.logoHeightDots= hDots;
        _inspKey = Object();
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logo error: $e')));
    } finally {
      if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(el.logoBmpHex.isEmpty ? 'Image pick failed' : 'Logo saved ✓'),
          duration: const Duration(seconds: 2)));
    }
  }

  void _deleteSelected() {
    if (_selected == null) return;
    setState(() { _elements.remove(_selected); _selected = null; });
  }

  void _duplicateSelected() {
    if (_selected == null) return;
    final src = _selected!;
    final copy = _fromMap(_toMap(src));
    copy.x += 16; copy.y += 16;
    setState(() { _elements.add(copy); _selected = copy; _inspKey = Object(); });
  }

  // Insert variable into focused field, or into primary field of selected element
  void _insertVar(String v) {
    final c = _focusedCtrl;
    if (c != null) {
      final sel = c.selection;
      final txt = c.text;
      final ins = sel.isValid ? sel.baseOffset : txt.length;
      c.value = TextEditingValue(
        text: '${txt.substring(0, ins)}$v${txt.substring(ins)}',
        selection: TextSelection.collapsed(offset: ins + v.length),
      );
      // Sync the element from the controller
      setState(() {});
      return;
    }
    // No field focused — append to primary field and rebuild inspector
    final el = _selected;
    if (el == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Select an element first, then tap a variable'),
          duration: const Duration(seconds: 2)));
      return;
    }
    switch (el.type) {
      case ElType.text:
        el.text = el.text + v;
      case ElType.qr || ElType.bar:
        el.data = el.data + v;
      case ElType.weight || ElType.serial || ElType.dateTime:
        el.prefix = el.prefix + v;
      case ElType.box || ElType.logo:
        break;
    }
    setState(() { _inspKey = Object(); });
  }

  @override Widget build(BuildContext context) {
    final zoomPct = (_zoom * 100).round();
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context)),
        titleSpacing: 4,
        title: TextField(
          controller: _nameCtrl,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          decoration: const InputDecoration(isDense: true, border: InputBorder.none,
              hintText: 'Tap to name template…', contentPadding: EdgeInsets.zero),
        ),
        actions: [
          if (_selected != null) ...[
            IconButton(icon: const Icon(Icons.copy_outlined, size: 20), tooltip: 'Duplicate',
                onPressed: _duplicateSelected),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                tooltip: 'Delete', onPressed: _deleteSelected),
          ],
          FilledButton.icon(onPressed: _save,
              icon: const Icon(Icons.save, size: 18), label: const Text('Save')),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(children: [
        _DimensionBar(
          wMm: _wMm, hMm: _hMm, gap: _gap,
          onW: (v) => setState(() => _wMm = v),
          onH: (v) => setState(() => _hMm = v),
          onGap: (v) => setState(() => _gap = v),
        ),
        _ToolboxBar(onAdd: _add),
        // ── Zoom + Grid toolbar ──────────────────────────────────────────────
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(children: [
            // Preset zoom buttons
            for (final pct in [50, 100, 200, 400])
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: GestureDetector(
                  onTap: () => _zoomSet(pct / 100),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: (zoomPct == pct)
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('$pct%',
                        style: TextStyle(
                          fontSize: 11,
                          color: (zoomPct == pct)
                              ? Theme.of(context).colorScheme.onPrimary
                              : null,
                        )),
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.zoom_out, size: 18),
              padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => _zoomSet(_zoom / 1.4),
            ),
            Text('$zoomPct%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            IconButton(
              icon: const Icon(Icons.zoom_in, size: 18),
              padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => _zoomSet(_zoom * 1.4),
            ),
            const Spacer(),
            // Grid snap toggle
            GestureDetector(
              onTap: () => setState(() => _snapGrid = !_snapGrid),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _snapGrid
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.grid_4x4, size: 14,
                      color: _snapGrid ? Theme.of(context).colorScheme.onPrimary : null),
                  const SizedBox(width: 3),
                  Text('Snap', style: TextStyle(fontSize: 11,
                      color: _snapGrid ? Theme.of(context).colorScheme.onPrimary : null)),
                ]),
              ),
            ),
          ]),
        ),
        Expanded(child: _buildCanvas()),
        _BottomPanel(
          selected: _selected,
          inspKey: _inspKey,
          wMm: _wMm, hMm: _hMm,
          onFocusCtrl: (c) => _focusedCtrl = c,
          onChange: () => setState(() {}),
          onInsertVar: _insertVar,
          onAlign: _align,
          onPickLogo: _pickAndProcessLogo,
        ),
      ]),
    );
  }

  // ── Canvas ─────────────────────────────────────────────────────────────────
  Widget _buildCanvas() {
    return Container(
      color: Colors.grey.shade400,
      child: LayoutBuilder(builder: (_, cns) {
        final availW  = (cns.maxWidth - 32).clamp(40.0, 800.0);
        final sc      = (availW / (_wMm * 8.0)).clamp(0.08, 3.0);
        final canvasW = _wMm * 8.0 * sc;
        final canvasH = _hMm * 8.0 * sc;

        return InteractiveViewer(
          transformationController: _transformCtrl,
          minScale: 0.25, maxScale: 8.0,
          boundaryMargin: const EdgeInsets.all(300),
          // Disable canvas pan while user is dragging an element
          panEnabled: !_elemDragging,
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(16),
              width: canvasW, height: canvasH,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black54, width: 1),
                boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
              ),
              child: Stack(children: [
                // Dot grid background
                Positioned.fill(child: CustomPaint(painter: _GridPainter(sc))),
                // Tap background to deselect
                Positioned.fill(child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(() {
                    _selected = null; _focusedCtrl = null;
                  }),
                )),
                // Safe-area boundary (dashed, 2mm inset)
                Positioned(
                  left: 16 * sc, top: 16 * sc,
                  right: 16 * sc, bottom: 16 * sc,
                  child: IgnorePointer(
                    child: DecoratedBox(decoration: BoxDecoration(
                      border: Border.all(color: Colors.blue.withOpacity(0.3),
                          width: 0.5, strokeAlign: BorderSide.strokeAlignInside),
                    )),
                  ),
                ),
                // Elements
                ..._elements.map((el) {
                  final selected = el == _selected;
                  return Positioned(
                    left: el.x * sc, top: el.y * sc,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() {
                        _selected = el; _inspKey = Object();
                      }),
                      onPanStart: (_) => setState(() {
                        _elemDragging = true;
                        _selected = el; _inspKey = Object();
                      }),
                      onPanUpdate: (d) => setState(() {
                        // Divide by effective scale (canvas base scale × zoom factor)
                        final eff = sc * _zoom;
                        el.x = _snap(el.x + d.delta.dx / eff).clamp(0, _wMm * 8);
                        el.y = _snap(el.y + d.delta.dy / eff).clamp(0, _hMm * 8);
                      }),
                      onPanEnd: (_)    => setState(() => _elemDragging = false),
                      onPanCancel: ()  => setState(() => _elemDragging = false),
                      child: _ElPreview(el: el, selected: selected, scale: sc),
                    ),
                  );
                }),
              ]),
            ),
          ),
        );
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Dot grid painter for canvas background
// ─────────────────────────────────────────────────────────────────────────────
class _GridPainter extends CustomPainter {
  final double scale;
  _GridPainter(this.scale);

  @override void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.grey.shade200..strokeWidth = 1;
    final step = (8.0 * scale).clamp(6.0, 40.0);
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.8, paint);
      }
    }
  }

  @override bool shouldRepaint(_GridPainter old) => old.scale != scale;
}

// ─────────────────────────────────────────────────────────────────────────────
//  WYSIWYG element preview
// ─────────────────────────────────────────────────────────────────────────────
class _ElPreview extends StatelessWidget {
  final LabelElement el; final bool selected; final double scale;
  const _ElPreview({required this.el, required this.selected, required this.scale});

  @override Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: selected ? Colors.blue.shade600 : Colors.transparent,
          width: selected ? 2.0 : 0,
        ),
      ),
      padding: const EdgeInsets.all(1),
      child: LabelCanvas.renderEl(el.toJson(_sampleCtx), scale),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Dimension bar
// ─────────────────────────────────────────────────────────────────────────────
class _DimensionBar extends StatelessWidget {
  final int wMm, hMm, gap;
  final ValueChanged<int> onW, onH, onGap;
  const _DimensionBar({required this.wMm, required this.hMm, required this.gap,
      required this.onW, required this.onH, required this.onGap});

  @override Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal,
        child: Row(children: [
          const Text('W:', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          _IntField(value: wMm, min: 10, max: 300, onChanged: onW),
          const SizedBox(width: 10),
          const Text('H:', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          _IntField(value: hMm, min: 5, max: 300, onChanged: onH),
          const SizedBox(width: 10),
          const Text('Gap:', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          _IntField(value: gap, min: 0, max: 20, onChanged: onGap),
          const SizedBox(width: 6),
          Text('mm', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(width: 12),
          Text('$wMm × $hMm mm',
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Toolbox bar
// ─────────────────────────────────────────────────────────────────────────────
class _ToolboxBar extends StatelessWidget {
  final void Function(ElType) onAdd;
  const _ToolboxBar({required this.onAdd});

  static const _items = [
    (ElType.text,     Icons.title,            'Text'),
    (ElType.weight,   Icons.scale,            'Weight'),
    (ElType.serial,   Icons.confirmation_num, 'Serial'),
    (ElType.dateTime, Icons.calendar_today,   'Date'),
    (ElType.qr,       Icons.qr_code_2,        'QR'),
    (ElType.bar,      Icons.barcode_reader,   'Barcode'),
    (ElType.box,      Icons.crop_square,      'Box'),
    (ElType.logo,     Icons.image_outlined,   'Logo'),
  ];

  @override Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal,
        child: Row(children: _items.map((item) => Padding(
          padding: const EdgeInsets.only(right: 4),
          child: ActionChip(
            avatar: Icon(item.$2, size: 14),
            label: Text(item.$3, style: const TextStyle(fontSize: 11)),
            onPressed: () => onAdd(item.$1),
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        )).toList()),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Bottom Panel — Properties + Variables
// ─────────────────────────────────────────────────────────────────────────────
class _BottomPanel extends StatelessWidget {
  final LabelElement? selected;
  final Object inspKey;
  final int wMm, hMm;
  final ValueChanged<TextEditingController?> onFocusCtrl;
  final VoidCallback onChange;
  final ValueChanged<String> onInsertVar;
  final ValueChanged<String> onAlign;
  final void Function(LabelElement)? onPickLogo;

  const _BottomPanel({
    required this.selected, required this.inspKey,
    required this.wMm, required this.hMm,
    required this.onFocusCtrl, required this.onChange,
    required this.onInsertVar, required this.onAlign,
    this.onPickLogo,
  });

  @override Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      constraints: BoxConstraints(maxHeight: selected != null ? 330 : 130),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Colors.grey.shade300, width: 1)),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (selected != null) ...[
            _PropertiesSection(
              key: ValueKey(inspKey),
              el: selected!,
              wMm: wMm, hMm: hMm,
              onFocusCtrl: onFocusCtrl,
              onChange: onChange,
              onPickLogo: onPickLogo,
            ),
            // ── Alignment toolbar ──────────────────────────────────────────
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(children: [
                Text('Align:', style: TextStyle(fontSize: 10,
                    color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
                const SizedBox(width: 4),
                for (final (icon, dir, tip) in [
                  (Icons.align_horizontal_left,   'L',  'Left'),
                  (Icons.align_horizontal_center,  'CH', 'Center H'),
                  (Icons.align_horizontal_right,   'R',  'Right'),
                  (Icons.align_vertical_top,        'T',  'Top'),
                  (Icons.align_vertical_center,     'CV', 'Center V'),
                  (Icons.align_vertical_bottom,     'B',  'Bottom'),
                ])
                  Tooltip(
                    message: tip,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => onAlign(dir),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Icon(icon, size: 18,
                            color: Theme.of(context).colorScheme.onSurface),
                      ),
                    ),
                  ),
              ]),
            ),
            Divider(height: 1, color: Colors.grey.shade300),
          ],
          _VariablesSection(
            hasSelection: selected != null,
            onInsert: onInsertVar,
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Properties Section
// ─────────────────────────────────────────────────────────────────────────────
class _PropertiesSection extends StatefulWidget {
  final LabelElement el;
  final int wMm, hMm;
  final ValueChanged<TextEditingController?> onFocusCtrl;
  final VoidCallback onChange;
  final void Function(LabelElement)? onPickLogo;

  const _PropertiesSection({
    super.key, required this.el, required this.wMm, required this.hMm,
    required this.onFocusCtrl, required this.onChange,
    this.onPickLogo,
  });

  @override State<_PropertiesSection> createState() => _PropertiesSectionState();
}

class _PropertiesSectionState extends State<_PropertiesSection> {
  late TextEditingController _text, _pre, _suf, _data;
  late FocusNode _textFn, _preFn, _sufFn, _dataFn;

  @override void initState() {
    super.initState();
    final el = widget.el;
    _text = TextEditingController(text: el.text);
    _pre  = TextEditingController(text: el.prefix);
    _suf  = TextEditingController(text: el.suffix);
    _data = TextEditingController(text: el.data);

    void reg(FocusNode fn, TextEditingController c) =>
        fn.addListener(() { if (fn.hasFocus) widget.onFocusCtrl(c); });

    _textFn = FocusNode(); reg(_textFn, _text);
    _preFn  = FocusNode(); reg(_preFn,  _pre);
    _sufFn  = FocusNode(); reg(_sufFn,  _suf);
    _dataFn = FocusNode(); reg(_dataFn, _data);
  }

  @override void dispose() {
    for (final c in [_text, _pre, _suf, _data]) c.dispose();
    for (final f in [_textFn, _preFn, _sufFn, _dataFn]) f.dispose();
    widget.onFocusCtrl(null);
    super.dispose();
  }

  void _sync() {
    widget.el.text   = _text.text;
    widget.el.prefix = _pre.text;
    widget.el.suffix = _suf.text;
    widget.el.data   = _data.text;
    widget.onChange();
  }

  Widget _tf(String label, TextEditingController c, FocusNode fn, {String hint = ''}) =>
      TextField(
        controller: c, focusNode: fn, onChanged: (_) => _sync(),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label, hintText: hint, isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
      );

  Widget _numRow(String label, int val, ValueChanged<int> cb, {int mn = 0, int mx = 9999}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        const SizedBox(height: 2),
        _IntField(value: val, min: mn, max: mx,
            onChanged: (v) { cb(v); _sync(); }),
      ]);

  Widget _dpFont(String val, ValueChanged<String?> cb) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Font', style: TextStyle(fontSize: 10, color: Colors.grey)),
      const SizedBox(height: 2),
      DropdownButton<String>(
        value: val, isDense: true,
        items: ['1','2','3','4','5','6','7','8']
            .map((f) => DropdownMenuItem(value: f, child: Text('F$f'))).toList(),
        onChanged: (v) { cb(v); widget.onChange(); },
      ),
    ],
  );

  Widget _dpBarType(String val, ValueChanged<String?> cb) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Type', style: TextStyle(fontSize: 10, color: Colors.grey)),
      const SizedBox(height: 2),
      DropdownButton<String>(
        value: val, isDense: true,
        items: const [
          DropdownMenuItem(value: '128',   child: Text('Code128')),
          DropdownMenuItem(value: '39',    child: Text('Code39')),
          DropdownMenuItem(value: 'EAN13', child: Text('EAN-13')),
          DropdownMenuItem(value: 'EAN8',  child: Text('EAN-8')),
          DropdownMenuItem(value: 'UPC',   child: Text('UPC-A')),
        ],
        onChanged: (v) { cb(v); widget.onChange(); },
      ),
    ],
  );

  Widget _dpEcc(String val, ValueChanged<String?> cb) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('ECC', style: TextStyle(fontSize: 10, color: Colors.grey)),
      const SizedBox(height: 2),
      DropdownButton<String>(
        value: val, isDense: true,
        items: ['L','M','Q','H'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
        onChanged: (v) { cb(v); widget.onChange(); },
      ),
    ],
  );

  @override Widget build(BuildContext context) {
    final el = widget.el;
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Row 1: Type badge + X + Y
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: cs.primaryContainer, borderRadius: BorderRadius.circular(6)),
            child: Text(el.type.name.toUpperCase(),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: cs.primary)),
          ),
          const SizedBox(width: 12),
          _numRow('X (dots)', el.x, (v) => el.x = v, mx: widget.wMm * 8),
          const SizedBox(width: 12),
          _numRow('Y (dots)', el.y, (v) => el.y = v, mx: widget.hMm * 8),
        ]),
        const SizedBox(height: 8),

        // Type-specific fields
        switch (el.type) {
          ElType.text => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _tf('Content (use {variable} tokens)', _text, _textFn,
                  hint: '{product} {purity}'),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: _tf('Prefix', _pre, _preFn)),
                const SizedBox(width: 8),
                Expanded(child: _tf('Suffix', _suf, _sufFn)),
              ]),
              const SizedBox(height: 6),
              SingleChildScrollView(scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _dpFont(el.font, (v) => el.font = v ?? '3'),
                  const SizedBox(width: 16),
                  _numRow('XScale', el.xScale, (v) => el.xScale = v, mn: 1, mx: 10),
                  const SizedBox(width: 12),
                  _numRow('YScale', el.yScale, (v) => el.yScale = v, mn: 1, mx: 10),
                ]),
              ),
            ]),

          ElType.weight || ElType.serial || ElType.dateTime => Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _tf('Prefix', _pre, _preFn)),
                const SizedBox(width: 8),
                Expanded(child: _tf('Suffix', _suf, _sufFn)),
              ]),
              const SizedBox(height: 6),
              SingleChildScrollView(scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _dpFont(el.font, (v) => el.font = v ?? '3'),
                  const SizedBox(width: 16),
                  _numRow('XScale', el.xScale, (v) => el.xScale = v, mn: 1, mx: 10),
                  const SizedBox(width: 12),
                  _numRow('YScale', el.yScale, (v) => el.yScale = v, mn: 1, mx: 10),
                ]),
              ),
            ]),

          ElType.qr => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _tf('QR Data (use {variable} tokens)', _data, _dataFn,
                  hint: '{serial}|{net}|{product}'),
              const SizedBox(height: 6),
              Row(children: [
                _numRow('Size', el.qrSize, (v) => el.qrSize = v, mn: 1, mx: 10),
                const SizedBox(width: 16),
                _dpEcc(el.qrEcc, (v) => el.qrEcc = v ?? 'M'),
              ]),
            ]),

          ElType.bar => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _tf('Barcode Data (use {variable} tokens)', _data, _dataFn,
                  hint: '{serial}'),
              const SizedBox(height: 6),
              SingleChildScrollView(scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _dpBarType(el.barcodeType, (v) => el.barcodeType = v ?? '128'),
                  const SizedBox(width: 16),
                  _numRow('Width', el.barcodeWidth, (v) => el.barcodeWidth = v, mn: 40, mx: 600),
                  const SizedBox(width: 12),
                  _numRow('Height', el.barcodeHeight, (v) => el.barcodeHeight = v, mn: 10, mx: 400),
                ]),
              ),
            ]),

          ElType.box => SingleChildScrollView(scrollDirection: Axis.horizontal,
              child: Row(children: [
                _numRow('X2', el.xEnd, (v) => el.xEnd = v, mx: widget.wMm * 8),
                const SizedBox(width: 12),
                _numRow('Y2', el.yEnd, (v) => el.yEnd = v, mx: widget.hMm * 8),
                const SizedBox(width: 12),
                _numRow('Thickness', el.thickness, (v) => el.thickness = v, mn: 1, mx: 20),
              ]),
            ),

          ElType.logo => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (el.logoPath.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(
                    File(el.logoPath),
                    width: 72, height: 44, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, size: 36, color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Row(children: [
                OutlinedButton.icon(
                  onPressed: () => widget.onPickLogo?.call(el),
                  icon: const Icon(Icons.photo_library_outlined, size: 16),
                  label: Text(el.logoPath.isEmpty ? 'Pick Image' : 'Change Image',
                      style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
                ),
                if (el.logoBmpHex.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text('${el.logoBmpW}B/row · ${el.logoHeightDots}rows',
                      style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ]),
              const SizedBox(height: 6),
              SingleChildScrollView(scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _numRow('W (dots)', el.logoWidthDots, (v) => el.logoWidthDots = v,
                      mn: 8, mx: 2400),
                  const SizedBox(width: 12),
                  _numRow('H (dots)', el.logoHeightDots, (v) => el.logoHeightDots = v,
                      mn: 8, mx: 1600),
                ]),
              ),
            ]),
        },
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Variables Section
// ─────────────────────────────────────────────────────────────────────────────
class _VariablesSection extends StatelessWidget {
  final bool hasSelection;
  final ValueChanged<String> onInsert;
  const _VariablesSection({required this.hasSelection, required this.onInsert});

  @override Widget build(BuildContext context) {
    final hint = hasSelection
        ? 'Tap variable → inserts at cursor (or appends to content)'
        : 'Select element on canvas, then tap a variable';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hint, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        const SizedBox(height: 4),
        for (final g in _varGroups) Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            SizedBox(width: 52, child: Text(g.$1,
                style: TextStyle(fontSize: 10,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold))),
            Expanded(child: Wrap(spacing: 3, runSpacing: 2,
              children: g.$2.map((v) => ActionChip(
                label: Text(v, style: const TextStyle(fontSize: 10)),
                tooltip: _varHints[v],
                onPressed: () => onInsert(v),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              )).toList(),
            )),
          ]),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Reusable integer field
// ─────────────────────────────────────────────────────────────────────────────
class _IntField extends StatefulWidget {
  final int value, min, max;
  final ValueChanged<int> onChanged;
  const _IntField({required this.value, this.min = 0, this.max = 9999, required this.onChanged});
  @override State<_IntField> createState() => _IntFieldState();
}
class _IntFieldState extends State<_IntField> {
  late final TextEditingController _c;
  @override void initState() { super.initState(); _c = TextEditingController(text: '${widget.value}'); }
  @override void didUpdateWidget(_IntField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final s = '${widget.value}';
      if (_c.text != s) _c.value = TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));
    }
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => SizedBox(width: 56, child: TextField(
    controller: _c, keyboardType: TextInputType.number,
    style: const TextStyle(fontSize: 12),
    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
    onChanged: (s) { final v = int.tryParse(s); if (v != null) widget.onChanged(v.clamp(widget.min, widget.max)); },
  ));
}