import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../services/db_service.dart';

// Variables grouped by category
const _varGroups = [
  ('Weight', [
    ('{net}',      'Net weight'),
    ('{gross}',    'Gross weight'),
    ('{tare}',     'Tare weight'),
    ('{stone}',    'Stone deduction'),
    ('{metal}',    'Metal net weight'),
  ]),
  ('Product', [
    ('{product}',  'Product name'),
    ('{purity}',   'Purity (e.g. 22K)'),
    ('{hsn}',      'HSN code'),
    ('{category}', 'Category'),
    ('{code}',     'SKU/code'),
  ]),
  ('Pricing', [
    ('{rate}',     'Rate per gram'),
    ('{amount}',   'Total amount'),
    ('{making}',   'Making charge'),
  ]),
  ('Print Info', [
    ('{serial}',   'Serial number'),
    ('{date}',     'Print date'),
    ('{time}',     'Print time'),
  ]),
];

class TemplatesPage extends StatefulWidget {
  final void Function(Map<String, dynamic>)? onLoad;
  const TemplatesPage({super.key, this.onLoad});

  @override
  State<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends State<TemplatesPage> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() { super.initState(); _reload(); }

  Future<void> _reload() async {
    _rows = await context.read<DbService>().listTemplates();
    setState(() {});
  }

  Future<void> _delete(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Template'),
        content: Text('Delete "$name"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<DbService>().deleteTemplate(id);
      _reload();
    }
  }

  Future<void> _duplicate(int id) async {
    await context.read<DbService>().duplicateTemplate(id);
    _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Template duplicated')));
    }
  }

  void _editLines(Map<String, dynamic> row) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _LinesEditor(
        row: row,
        db: context.read<DbService>(),
        onSaved: _reload,
      ),
    );
  }

  // ── Export ───────────────────────────────────────────────────────────────────

  Map<String, dynamic> _templateToExportMap(Map<String, dynamic> r) {
    dynamic jsonData;
    dynamic linesData;
    try { jsonData  = jsonDecode(r['json']  as String? ?? '[]'); } catch (_) { jsonData  = []; }
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
      'templates': [_templateToExportMap(row)],
    });
    final safeName = (row['name'] as String)
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(' ', '_');
    await _shareJson(payload, 'jbc_template_$safeName.json');
  }

  Future<void> _exportAll() async {
    if (_rows.isEmpty) return;
    final payload = jsonEncode({
      'format': 'jbc-gs-template',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'templates': _rows.map(_templateToExportMap).toList(),
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  // ── Import ───────────────────────────────────────────────────────────────────

  Future<void> _importTemplates() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
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
      final content = await File(path).readAsString();
      final data    = jsonDecode(content) as Map<String, dynamic>;

      if (data['format'] != 'jbc-gs-template') {
        throw const FormatException('Not a JBC template file');
      }

      final list = (data['templates'] as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) throw const FormatException('No templates found in file');

      final db = context.read<DbService>();
      int count = 0;
      for (final t in list) {
        final linesRaw = t['lines'];
        List<String>? lines;
        if (linesRaw is List) {
          lines = linesRaw.map((e) => e.toString()).toList();
        }
        await db.saveTemplate(
          name:  t['name']      as String? ?? 'Imported Template',
          wMm:   (t['width_mm']  as num?)?.toInt() ?? 50,
          hMm:   (t['height_mm'] as num?)?.toInt() ?? 25,
          gapMm: (t['gap_mm']    as num?)?.toInt() ?? 3,
          json:  t['json'] ?? [],
          lines: lines,
        );
        count++;
      }

      _reload();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count template(s) imported successfully')));
    } on FormatException catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Invalid file: ${e.message}')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  // Parse the designer JSON to discover which element types are present
  List<String> _elementTypes(Map<String, dynamic> row) {
    try {
      final raw = row['json'] as String? ?? '[]';
      if (raw == '[]' || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      final seen = <String>{};
      for (final m in list.whereType<Map>()) {
        seen.add(m['t'] as String? ?? 'text');
      }
      return seen.toList();
    } catch (_) { return []; }
  }

  Widget _elBadge(BuildContext context, String type) {
    final (label, ic) = switch (type) {
      'text'     => ('Text', Icons.text_fields),
      'weight'   => ('Weight', Icons.scale),
      'serial'   => ('Serial', Icons.confirmation_num),
      'dateTime' => ('Date/Time', Icons.calendar_today),
      'qr'       => ('QR', Icons.qr_code_2),
      'bar'      => ('Barcode', Icons.barcode_reader),
      'box'      => ('Box', Icons.crop_square),
      'logo'     => ('Logo', Icons.image),
      _          => (type, Icons.widgets),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ic, size: 11, color: Theme.of(context).colorScheme.secondary),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 10,
            color: Theme.of(context).colorScheme.onSecondaryContainer)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd-MMM HH:mm');
    return RefreshIndicator(
      onRefresh: _reload,
      child: Column(children: [
        // ── Import / Export All bar ───────────────────────────────────────────
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
                onPressed: _rows.isEmpty ? null : _exportAll,
              ),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: _rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.label_outline, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No templates yet.\nCreate one in the Designer tab.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)),
                ]),
              ))
          : ListView.separated(
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r       = _rows[i];
                final id      = r['id'] as int;
                final name    = r['name'] as String;
                final lines   = DbService.parseLines(r);
                final hasLines  = lines.any((l) => l.trim().isNotEmpty);
                final elTypes = _elementTypes(r);
                final updated = DateTime.fromMillisecondsSinceEpoch(r['updated'] as int);

                return ExpansionTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(Icons.label, color: Theme.of(context).colorScheme.primary),
                  ),
                  title: Text(name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      '${r['width_mm']} × ${r['height_mm']} mm  •  '
                      '${elTypes.isNotEmpty ? "${elTypes.length} element(s)" : hasLines ? "Lines only" : "Empty"}  •  '
                      '${fmt.format(updated)}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: const Icon(Icons.ios_share, size: 20),
                      tooltip: 'Share / Export',
                      onPressed: () => _exportTemplate(r),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit')      widget.onLoad?.call(r);
                        if (v == 'lines')     _editLines(r);
                        if (v == 'duplicate') _duplicate(id);
                        if (v == 'export')    _exportTemplate(r);
                        if (v == 'delete')    _delete(id, name);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit',
                            child: ListTile(leading: Icon(Icons.design_services),
                                title: Text('Edit Layout'), dense: true)),
                        PopupMenuItem(value: 'lines',
                            child: ListTile(leading: Icon(Icons.format_list_bulleted),
                                title: Text('Edit Print Lines'), dense: true)),
                        PopupMenuItem(value: 'duplicate',
                            child: ListTile(leading: Icon(Icons.copy),
                                title: Text('Duplicate'), dense: true)),
                        PopupMenuItem(value: 'export',
                            child: ListTile(leading: Icon(Icons.download),
                                title: Text('Export'), dense: true)),
                        PopupMenuItem(value: 'delete',
                            child: ListTile(
                                leading: Icon(Icons.delete, color: Colors.red),
                                title: Text('Delete',
                                    style: TextStyle(color: Colors.red)), dense: true)),
                      ],
                    ),
                  ]),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Designer element badges
                          if (elTypes.isNotEmpty) ...[
                            const Text('Designer elements:',
                                style: TextStyle(color: Colors.grey, fontSize: 11)),
                            const SizedBox(height: 4),
                            Wrap(spacing: 4, runSpacing: 4,
                                children: elTypes.map((t) => _elBadge(context, t)).toList()),
                            const SizedBox(height: 8),
                          ],
                          // Print lines preview
                          if (!hasLines)
                            Text(
                              elTypes.isEmpty
                                  ? 'Empty template — add elements in Designer or set print lines'
                                  : 'Print lines: not set (designer elements will be used)',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            )
                          else ...[
                            const Text('Print lines (text-only override):',
                                style: TextStyle(color: Colors.grey, fontSize: 11)),
                            const SizedBox(height: 2),
                            ...lines.asMap().entries
                                .where((e) => e.value.trim().isNotEmpty)
                                .map((e) => Padding(
                                      padding: const EdgeInsets.only(bottom: 2),
                                      child: Text('Line ${e.key + 1}: ${e.value}',
                                          style: const TextStyle(fontSize: 12,
                                              fontFamily: 'monospace')),
                                    )),
                          ],
                          const SizedBox(height: 8),
                          Row(children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.format_list_bulleted, size: 16),
                              label: const Text('Edit Print Lines'),
                              onPressed: () => _editLines(r),
                              style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6)),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.design_services, size: 16),
                              label: const Text('Edit Layout'),
                              onPressed: () => widget.onLoad?.call(r),
                              style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6)),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ],
                );
              }),
        ),   // Expanded
      ]),    // Column
    );
  }
}

// =============================================================================
// Bottom sheet for editing print lines — unlimited lines, grouped variables
class _LinesEditor extends StatefulWidget {
  final Map<String, dynamic> row;
  final DbService db;
  final VoidCallback onSaved;
  const _LinesEditor({required this.row, required this.db, required this.onSaved});

  @override State<_LinesEditor> createState() => _LinesEditorState();
}

class _LinesEditorState extends State<_LinesEditor> {
  final List<TextEditingController> _ctrls = [];
  final List<FocusNode> _foci = [];
  int _focusedLine = 0;

  @override
  void initState() {
    super.initState();
    // Parse raw saved lines (no padding)
    List<String> saved;
    try {
      final raw  = widget.row['lines'] as String? ?? '[]';
      final list = jsonDecode(raw) as List;
      saved = list.map((e) => e.toString()).toList();
    } catch (_) {
      saved = [];
    }
    final nonEmpty = saved.where((s) => s.isNotEmpty).toList();
    final initial  = nonEmpty.isEmpty ? [''] : nonEmpty;
    for (final l in initial) _addCtrl(l);
  }

  @override
  void dispose() {
    for (final c in _ctrls) c.dispose();
    for (final f in _foci)  f.dispose();
    super.dispose();
  }

  void _addCtrl(String text) {
    final fn = FocusNode();
    fn.addListener(() {
      if (fn.hasFocus) setState(() => _focusedLine = _foci.indexOf(fn));
    });
    _ctrls.add(TextEditingController(text: text));
    _foci.add(fn);
  }

  void _addLine() {
    setState(() {
      _addCtrl('');
      _focusedLine = _ctrls.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_foci.isNotEmpty) _foci.last.requestFocus();
    });
  }

  void _removeLine(int i) {
    if (_ctrls.length <= 1) return;
    _ctrls[i].dispose();
    _foci[i].dispose();
    setState(() {
      _ctrls.removeAt(i);
      _foci.removeAt(i);
      _focusedLine = _focusedLine.clamp(0, _ctrls.length - 1);
    });
  }

  void _insertVar(String v) {
    if (_ctrls.isEmpty) return;
    final idx = _focusedLine.clamp(0, _ctrls.length - 1);
    final c   = _ctrls[idx];
    final sel = c.selection;
    final txt = c.text;
    final ins = sel.isValid ? sel.baseOffset : txt.length;
    c.value = TextEditingValue(
      text: '${txt.substring(0, ins)}$v${txt.substring(ins)}',
      selection: TextSelection.collapsed(offset: ins + v.length),
    );
    _foci[idx].requestFocus();
  }

  String _expandDots(String line, int wMm) {
    if (!line.contains('...')) return line;
    final totalChars = (wMm * 8 / 14).round();
    final parts = line.split('...');
    if (parts.length != 2) return line;
    final dots = (totalChars - parts[0].length - parts[1].length).clamp(3, 50);
    return '${parts[0]}${List.filled(dots, '.').join()}${parts[1]}';
  }

  Future<void> _save() async {
    var lines = _ctrls.map((c) => c.text).toList();
    while (lines.isNotEmpty && lines.last.trim().isEmpty) lines.removeLast();
    await widget.db.saveTemplateLines(widget.row['id'] as int, lines);
    widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final wMm       = widget.row['width_mm'] as int? ?? 50;
    final hasContent = _ctrls.any((c) => c.text.isNotEmpty);
    final focusLabel = _ctrls.isEmpty ? 'Line 1' : 'Line ${_focusedLine + 1}';

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── Header ─────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(children: [
              const Icon(Icons.format_list_bulleted),
              const SizedBox(width: 8),
              Expanded(child: Text(
                'Print Lines — ${widget.row['name']}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              )),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Use {variables} for live data. Use ... for dot leaders (e.g. Net:...{net}). '
              'Designer elements (QR, barcode, logo) always take priority during print/preview.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
          const Divider(height: 1),

          // ── Scrollable content ──────────────────────────────────────────────
          Flexible(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [

              // Line fields
              ...List.generate(_ctrls.length, (i) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: _ctrls[i],
                  focusNode: _foci[i],
                  decoration: InputDecoration(
                    labelText: 'Line ${i + 1}',
                    hintText: i == 0
                        ? 'e.g. {product} {purity}'
                        : i == 1
                            ? 'e.g. Net:...{net}g'
                            : 'e.g. {serial}  {date}',
                    border: const OutlineInputBorder(),
                    suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_ctrls[i].text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () { _ctrls[i].clear(); setState(() {}); },
                        ),
                      if (_ctrls.length > 1)
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline,
                              size: 18, color: Colors.red),
                          tooltip: 'Remove line',
                          onPressed: () => _removeLine(i),
                        ),
                    ]),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              )),

              // Add line button
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addLine,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Line'),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4)),
                ),
              ),
              const SizedBox(height: 8),

              // Variable chips — grouped
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Tap to insert into $focusLabel:',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  const SizedBox(height: 8),
                  for (final group in _varGroups) ...[
                    Text(group.$1,
                        style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4, runSpacing: 4,
                      children: group.$2.map((v) => ActionChip(
                        label: Text(v.$1, style: const TextStyle(fontSize: 11)),
                        tooltip: v.$2,
                        onPressed: () => _insertVar(v.$1),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      )).toList(),
                    ),
                    const SizedBox(height: 8),
                  ],
                ]),
              ),
              const SizedBox(height: 10),

              // Live preview — black box with green monospace text
              if (hasContent)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('PREVIEW',
                          style: TextStyle(fontSize: 9, color: Colors.grey,
                              letterSpacing: 2)),
                      const SizedBox(height: 4),
                      ..._ctrls.where((c) => c.text.isNotEmpty).map((c) => Text(
                        _expandDots(c.text, wMm)
                            .replaceAllMapped(RegExp(r'\{(\w+)\}'),
                                (m) => '[${m.group(1)}]'),
                        style: const TextStyle(
                            color: Colors.greenAccent, fontFamily: 'monospace',
                            fontSize: 13, height: 1.4),
                      )),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
            ]),
          )),

          // ── Footer — Save button ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Save Lines'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
          ),
        ]),
      ),
    );
  }
}