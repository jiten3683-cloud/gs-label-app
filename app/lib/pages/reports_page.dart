import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/label_element.dart';
import '../services/ble_service.dart';
import '../services/db_service.dart';
import '../widgets/label_canvas.dart';

// ─── Date preset ──────────────────────────────────────────────────────────────
enum _Preset { today, yesterday, week, month, custom }

extension _PresetExt on _Preset {
  String get label => switch (this) {
    _Preset.today     => 'Today',
    _Preset.yesterday => 'Yesterday',
    _Preset.week      => 'This Week',
    _Preset.month     => 'This Month',
    _Preset.custom    => 'Custom',
  };

  (DateTime, DateTime) range() {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (this) {
      _Preset.today     => (today, today),
      _Preset.yesterday => (today.subtract(const Duration(days: 1)),
                            today.subtract(const Duration(days: 1))),
      _Preset.week      => (today.subtract(Duration(days: today.weekday - 1)), today),
      _Preset.month     => (DateTime(now.year, now.month, 1), today),
      _Preset.custom    => (today.subtract(const Duration(days: 30)), today),
    };
  }
}

// ─── Main page ────────────────────────────────────────────────────────────────
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});
  @override State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  _Preset  _preset  = _Preset.today;
  DateTime _from    = DateTime.now();
  DateTime _to      = DateTime.now();
  final _searchCtrl = TextEditingController();
  String   _search  = '';

  List<Map<String, dynamic>> _rows   = [];
  Map<String, dynamic>       _summary = {};
  bool   _loading  = false;
  final  Set<int> _selected = {};
  bool   _selectMode = false;

  static final _fmtDate = DateFormat('dd-MMM-yy');
  static final _fmtDT   = DateFormat('dd-MMM-yy HH:mm');

  @override void initState() {
    super.initState();
    final r = _preset.range();
    _from = r.$1; _to = r.$2;
    _query();
  }

  @override void dispose() { _searchCtrl.dispose(); super.dispose(); }

  void _applyPreset(_Preset p) {
    setState(() { _preset = p; });
    if (p != _Preset.custom) {
      final r = p.range();
      setState(() { _from = r.$1; _to = r.$2; });
      _query();
    } else {
      _pickCustomRange();
    }
  }

  Future<void> _pickCustomRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime(2099),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (range != null) {
      setState(() { _from = range.start; _to = range.end; });
      _query();
    }
  }

  Future<void> _query() async {
    setState(() { _loading = true; _selected.clear(); _selectMode = false; });
    final db = context.read<DbService>();
    _rows    = await db.queryPrints(from: _from, to: _to, search: _search);
    _summary = await db.querySummary(from: _from, to: _to, search: _search);
    setState(() => _loading = false);
  }

  // ── Selection helpers ────────────────────────────────────────────────────────
  void _toggleSelect(int id) {
    setState(() {
      if (_selected.contains(id)) _selected.remove(id);
      else _selected.add(id);
      _selectMode = _selected.isNotEmpty;
    });
  }

  Future<void> _deleteSelected() async {
    final ok = await _confirmDelete('Delete ${_selected.length} record(s)?');
    if (!ok) return;
    await context.read<DbService>().deletePrints(_selected.toList());
    _query();
  }

  Future<void> _deleteSingle(int id) async {
    final ok = await _confirmDelete('Delete this record?');
    if (!ok) return;
    await context.read<DbService>().deletePrint(id);
    _query();
  }

  Future<void> _clearAll() async {
    final ok = await _confirmDelete('Clear ALL print history? This cannot be undone.');
    if (!ok) return;
    await context.read<DbService>().clearAllPrints();
    _query();
  }

  Future<bool> _confirmDelete(String msg) async {
    return await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ?? false;
  }

  // ── Label preview + reprint ──────────────────────────────────────────────────
  void _showLabelPreview(Map<String, dynamic> row) {
    showModalBottomSheet(
      context: context, isScrollControlled: true, useSafeArea: true,
      builder: (ctx) => _LabelPreviewSheet(
        row: row,
        onReprint: _reprintJob,
        onMore: () { Navigator.pop(ctx); _showRowActions(row); },
      ),
    );
  }

  Future<void> _reprintJob(Map<String, dynamic> job, {int? copies}) async {
    final ble = context.read<BleService>();
    if (!ble.isConnected) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Printer not connected — connect from Home screen first')));
      return;
    }
    final Map<String, dynamic> toSend = copies != null
        ? {...job, 'copies': copies} : Map<String, dynamic>.from(job);
    final sent = await ble.sendPrintJob(toSend);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(sent ? 'Reprinted successfully' : 'Failed to send to printer')));
  }

  // ── Row action sheet ─────────────────────────────────────────────────────────
  void _showRowActions(Map<String, dynamic> row) {
    final serial = row['serial'] as String? ?? '';
    showModalBottomSheet(
      context: context, useSafeArea: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.tag),
            title: Text(serial, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(row['product'] as String? ?? ''),
          ),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('Export PDF (this record)'),
              onTap: () { Navigator.pop(context); _exportPdf([row]); }),
          ListTile(leading: const Icon(Icons.table_view_outlined),
              title: const Text('Export Excel (this record)'),
              onTap: () { Navigator.pop(context); _exportXlsx([row]); }),
          ListTile(leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Export CSV (this record)'),
              onTap: () { Navigator.pop(context); _exportCsv([row]); }),
          ListTile(leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () { Navigator.pop(context); _deleteSingle(row['id'] as int); }),
        ]),
      ),
    );
  }

  // ── Export helpers ────────────────────────────────────────────────────────────
  static List<dynamic> _rowToCsv(Map<String, dynamic> r) => [
    r['serial'] ?? '',
    _fmtDT.format(DateTime.fromMillisecondsSinceEpoch(r['ts'] as int)),
    r['product']      ?? '',
    r['purity']       ?? '',
    (r['gross_g']     as num?)?.toStringAsFixed(3) ?? '',
    (r['tare_g']      as num?)?.toStringAsFixed(3) ?? '',
    (r['net_g']       as num?)?.toStringAsFixed(3) ?? '',
    (r['stone_g']     as num?)?.toStringAsFixed(3) ?? '',
    (r['rate']        as num?)?.toStringAsFixed(2) ?? '',
    (r['amount']      as num?)?.toStringAsFixed(2) ?? '',
    r['barcode']      ?? '',
    r['qr_data']      ?? '',
    r['operator_name']?? '',
    r['template']     ?? '',
    r['copies']       ?? 1,
  ];

  static const _csvHeaders = [
    'Serial', 'Date/Time', 'Product', 'Purity',
    'Gross g', 'Tare g', 'Net g', 'Stone g',
    'Rate ₹', 'Amount ₹', 'Barcode', 'QR Data',
    'Operator', 'Template', 'Copies',
  ];

  Future<void> _exportCsv(List<Map<String, dynamic>> data) async {
    final rows = <List<dynamic>>[_csvHeaders, ...data.map(_rowToCsv)];
    final dir  = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'jbc_report_${DateTime.now().millisecondsSinceEpoch}.csv'));
    await file.writeAsString(const ListToCsvConverter().convert(rows));
    await Share.shareXFiles([XFile(file.path)], text: 'JBC-GS-PRINTER Report');
  }

  Future<void> _exportXlsx(List<Map<String, dynamic>> data) async {
    final ex  = Excel.createExcel();
    final sh  = ex['Prints'];

    // Header row with bold style
    sh.appendRow(_csvHeaders.map((h) => TextCellValue(h)).toList());

    for (final r in data) {
      final ts = _fmtDT.format(DateTime.fromMillisecondsSinceEpoch(r['ts'] as int));
      sh.appendRow([
        TextCellValue(r['serial']       ?? ''),
        TextCellValue(ts),
        TextCellValue(r['product']      ?? ''),
        TextCellValue(r['purity']       ?? ''),
        DoubleCellValue((r['gross_g']   as num? ?? 0).toDouble()),
        DoubleCellValue((r['tare_g']    as num? ?? 0).toDouble()),
        DoubleCellValue((r['net_g']     as num? ?? 0).toDouble()),
        DoubleCellValue((r['stone_g']   as num? ?? 0).toDouble()),
        DoubleCellValue((r['rate']      as num? ?? 0).toDouble()),
        DoubleCellValue((r['amount']    as num? ?? 0).toDouble()),
        TextCellValue(r['barcode']      ?? ''),
        TextCellValue(r['qr_data']      ?? ''),
        TextCellValue(r['operator_name']?? ''),
        TextCellValue(r['template']     ?? ''),
        IntCellValue(r['copies']  as int? ?? 1),
      ]);
    }
    final bytes = ex.encode();
    if (bytes == null) return;
    final dir  = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'jbc_report_${DateTime.now().millisecondsSinceEpoch}.xlsx'));
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)], text: 'JBC-GS-PRINTER Report');
  }

  Future<void> _exportPdf(List<Map<String, dynamic>> data) async {
    final pdf = pw.Document();
    const cols = ['Serial', 'Date', 'Product', 'Purity', 'Gross g', 'Net g', 'Amount ₹'];

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      header: (_) => pw.Column(children: [
        pw.Text('JBC-GS-PRINTER — Print History Report',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text('Period: ${_fmtDate.format(_from)} – ${_fmtDate.format(_to)}  '
            '| Records: ${data.length}  '
            '| Total Net: ${_totalNet(data).toStringAsFixed(3)} g',
            style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 6),
        pw.Divider(),
      ]),
      build: (_) => [
        pw.TableHelper.fromTextArray(
          headers: cols,
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
          cellStyle: const pw.TextStyle(fontSize: 7),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
          data: data.map((r) => [
            r['serial'] ?? '',
            _fmtDT.format(DateTime.fromMillisecondsSinceEpoch(r['ts'] as int)),
            r['product'] ?? '',
            r['purity']  ?? '',
            (r['gross_g'] as num?)?.toStringAsFixed(3) ?? '',
            (r['net_g']   as num?)?.toStringAsFixed(3) ?? '',
            (r['amount']  as num?)?.toStringAsFixed(2) ?? '',
          ]).toList(),
        ),
      ],
    ));

    final dir  = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'jbc_report_${DateTime.now().millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await pdf.save());
    await Share.shareXFiles([XFile(file.path)], text: 'JBC-GS-PRINTER Report');
  }

  double _totalNet(List<Map<String, dynamic>> data) =>
      data.fold(0.0, (s, r) => s + ((r['net_g'] as num? ?? 0).toDouble()));

  // ── Build ─────────────────────────────────────────────────────────────────────
  @override Widget build(BuildContext context) {
    final cs  = Theme.of(context).colorScheme;
    final cnt = _summary['cnt'] as int?    ?? _rows.length;
    final net = (_summary['net'] as num?)?.toDouble() ?? 0.0;
    final amt = (_summary['amt'] as num?)?.toDouble() ?? 0.0;

    return Column(children: [
      // ── Date preset chips ──────────────────────────────────────────────────
      Container(
        color: cs.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final pr in _Preset.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(pr.label, style: const TextStyle(fontSize: 12)),
                  selected: _preset == pr,
                  onSelected: (_) => _applyPreset(pr),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            if (_preset == _Preset.custom) ...[
              const SizedBox(width: 4),
              Text('${_fmtDate.format(_from)} – ${_fmtDate.format(_to)}',
                  style: TextStyle(fontSize: 11, color: cs.primary)),
            ],
          ]),
        ),
      ),

      // ── Search bar ─────────────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
        child: Row(children: [
          Expanded(child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search serial, product, barcode, QR…',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _search.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _search = '');
                        _query();
                      })
                  : null,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            onChanged: (s) => setState(() => _search = s),
            onSubmitted: (_) => _query(),
          )),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _query,
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
            child: const Text('SEARCH'),
          ),
        ]),
      ),

      // ── Summary bar ────────────────────────────────────────────────────────
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withOpacity(0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          _stat('Labels', cnt.toString(), Icons.confirmation_num_outlined),
          const SizedBox(width: 16),
          _stat('Total Net', '${net.toStringAsFixed(3)} g', Icons.scale_outlined),
          const SizedBox(width: 16),
          _stat('Total ₹', '₹ ${amt.toStringAsFixed(0)}', Icons.currency_rupee),
          const Spacer(),
          if (_loading) const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      ),

      // ── Selection action bar ───────────────────────────────────────────────
      if (_selectMode)
        Container(
          color: cs.secondaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Text('${_selected.length} selected',
                style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSecondaryContainer)),
            const Spacer(),
            TextButton.icon(
              onPressed: () { setState(() { _selected.clear(); _selectMode = false; }); },
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Cancel'),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: () => _exportCsv(_rows.where((r) => _selected.contains(r['id'])).toList()),
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('CSV'),
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete, size: 16),
              label: const Text('Delete'),
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.red, visualDensity: VisualDensity.compact),
            ),
          ]),
        ),

      // ── Records list ───────────────────────────────────────────────────────
      Expanded(child: _rows.isEmpty && !_loading
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.history_outlined, size: 60, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text('No records found', style: TextStyle(color: Colors.grey.shade500)),
              if (_search.isNotEmpty)
                TextButton(onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _search = '');
                  _query();
                }, child: const Text('Clear search')),
            ]))
          : ListView.separated(
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r  = _rows[i];
                final id = r['id'] as int;
                final ts = DateTime.fromMillisecondsSinceEpoch(r['ts'] as int);
                final isSelected = _selected.contains(id);
                return InkWell(
                  onTap: _selectMode
                      ? () => _toggleSelect(id)
                      : () => _showLabelPreview(r),
                  onLongPress: () => _toggleSelect(id),
                  child: Container(
                    color: isSelected ? cs.secondaryContainer.withOpacity(0.5) : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(children: [
                      if (_selectMode)
                        Checkbox(
                          value: isSelected,
                          onChanged: (_) => _toggleSelect(id),
                          visualDensity: VisualDensity.compact,
                        ),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(r['serial'] ?? '',
                                style: TextStyle(fontWeight: FontWeight.bold,
                                    color: cs.primary, fontSize: 13)),
                            const SizedBox(width: 8),
                            Text(r['product'] ?? '', style: const TextStyle(fontSize: 13)),
                            if ((r['purity'] as String?)?.isNotEmpty == true) ...[
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: cs.tertiaryContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(r['purity'] as String,
                                    style: TextStyle(fontSize: 10, color: cs.onTertiaryContainer)),
                              ),
                            ],
                          ]),
                          const SizedBox(height: 2),
                          Row(children: [
                            _chip('Net ${(r['net_g'] as num?)?.toStringAsFixed(3) ?? '0'} g'),
                            const SizedBox(width: 6),
                            _chip('Gross ${(r['gross_g'] as num?)?.toStringAsFixed(3) ?? '0'} g'),
                            if ((r['amount'] as num? ?? 0) > 0) ...[
                              const SizedBox(width: 6),
                              _chip('₹ ${(r['amount'] as num).toStringAsFixed(0)}'),
                            ],
                          ]),
                          const SizedBox(height: 2),
                          Text(_fmtDT.format(ts),
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                        ],
                      )),
                      const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                    ]),
                  ),
                );
              }),
      ),

      // ── Export / Delete buttons ────────────────────────────────────────────
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: _rows.isEmpty ? null : () => _exportPdf(_rows),
              icon: const Icon(Icons.picture_as_pdf, size: 16),
              label: const Text('PDF'),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10)),
            )),
            const SizedBox(width: 6),
            Expanded(child: OutlinedButton.icon(
              onPressed: _rows.isEmpty ? null : () => _exportXlsx(_rows),
              icon: const Icon(Icons.table_chart, size: 16),
              label: const Text('Excel'),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10)),
            )),
            const SizedBox(width: 6),
            Expanded(child: OutlinedButton.icon(
              onPressed: _rows.isEmpty ? null : () => _exportCsv(_rows),
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('CSV'),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10)),
            )),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined, color: Colors.red),
              tooltip: 'Clear all history',
              onPressed: _rows.isEmpty ? null : _clearAll,
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _stat(String label, String value, IconData icon) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 4),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      ]),
    ],
  );

  Widget _chip(String s) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: Colors.grey.shade200,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(s, style: const TextStyle(fontSize: 10)),
  );
}

// ─── Label Preview Sheet ───────────────────────────────────────────────────────

class _LabelPreviewSheet extends StatefulWidget {
  final Map<String, dynamic> row;
  final Future<void> Function(Map<String, dynamic> job, {int? copies}) onReprint;
  final VoidCallback onMore;
  const _LabelPreviewSheet({
    required this.row, required this.onReprint, required this.onMore});
  @override State<_LabelPreviewSheet> createState() => _LabelPreviewSheetState();
}

class _LabelPreviewSheetState extends State<_LabelPreviewSheet> {
  static final _fmtDT = DateFormat('dd-MMM-yy HH:mm');

  Map<String, dynamic>? _job;
  bool _jobReconstructed = false;  // true when job was rebuilt from template (no snapshot)
  bool _loading    = true;
  bool _reprinting = false;

  @override void initState() {
    super.initState();
    _loadJob();
  }

  Future<void> _loadJob() async {
    // 1. Try stored job_snapshot (exact original job)
    final snap = widget.row['job_snapshot'] as String? ?? '';
    if (snap.isNotEmpty) {
      try {
        final j = jsonDecode(snap);
        if (j is Map<String, dynamic>) {
          if (mounted) setState(() { _job = j; _loading = false; });
          return;
        }
      } catch (_) {}
    }

    // 2. Fallback: reconstruct from stored row fields + current template layout
    final rebuilt = await _reconstructJob();
    if (mounted) setState(() {
      _job = rebuilt;
      _jobReconstructed = rebuilt != null;
      _loading = false;
    });
  }

  /// Rebuild a printable job from stored row data + template from DB.
  /// Used for records printed before job_snapshot was introduced.
  Future<Map<String, dynamic>?> _reconstructJob() async {
    try {
      final db  = context.read<DbService>();
      final row = widget.row;

      // Find template by name
      final tplName  = row['template'] as String? ?? '';
      final templates = await db.listTemplates();
      Map<String, dynamic>? tpl;
      for (final t in templates) {
        if (t['name'] == tplName) { tpl = t; break; }
      }
      tpl ??= templates.isNotEmpty ? templates.first : null;
      if (tpl == null) return null;

      // Rebuild LabelContext from stored numeric fields
      final netG   = (row['net_g']   as num? ?? 0).toDouble();
      final grossG = (row['gross_g'] as num? ?? 0).toDouble();
      final tareG  = (row['tare_g']  as num? ?? 0).toDouble();
      final stoneG = (row['stone_g'] as num? ?? 0).toDouble();
      final metalG = (netG - stoneG) < 0 ? 0.0 : (netG - stoneG);
      final ts     = DateTime.fromMillisecondsSinceEpoch(row['ts'] as int? ?? 0);
      final rate   = (row['rate']   as num? ?? 0).toDouble();
      final making = (row['making'] as num? ?? 0).toDouble();

      final s = await db.getAllSettings();

      final ctx = LabelContext(
        netStr:         '${netG.toStringAsFixed(3)} g',
        grossStr:       '${grossG.toStringAsFixed(3)} g',
        tareStr:        '${tareG.toStringAsFixed(3)} g',
        stoneStr:       stoneG > 0 ? '${stoneG.toStringAsFixed(3)} g' : '',
        metalStr:       '${metalG.toStringAsFixed(3)} g',
        serial:         row['serial']  as String? ?? '',
        dateStr:        DateFormat('dd-MM-yyyy').format(ts),
        timeStr:        DateFormat('HH:mm').format(ts),
        product:        row['product'] as String? ?? '',
        purity:         row['purity']  as String? ?? '',
        hsn:            row['hsn']     as String? ?? '',
        rateStr:        rate.toStringAsFixed(2),
        amountStr:      (row['amount'] as num? ?? 0).toStringAsFixed(2),
        makingStr:      (metalG * rate * making / 100).toStringAsFixed(2),
        shopName:       s['shop_name']       ?? '',
        companyName:    s['company_name']    ?? '',
        companyAddress: s['company_address'] ?? '',
        companyPhone:   s['company_phone']   ?? '',
        companyGst:     s['company_gst']     ?? '',
      );

      // Try designer elements first, then fall back to line-based text
      List<Map<String, dynamic>> elements = _buildFromDesigner(tpl['json'] as String? ?? '[]', ctx);
      if (elements.isEmpty) {
        elements = _buildFromLines(DbService.parseLines(tpl), ctx, tpl['width_mm'] as int? ?? 50);
      }
      if (elements.isEmpty) return null;

      final darkStr = await db.getSetting('default_darkness', def: '8');
      final dirStr  = await db.getSetting('print_direction',  def: '0');

      return {
        'cmd': 'print',
        'label': {
          'w': tpl['width_mm'] ?? 50, 'h': tpl['height_mm'] ?? 25,
          'gap': tpl['gap_mm'] ?? 3,
          'darkness': int.tryParse(darkStr) ?? 8,
          'dir':      int.tryParse(dirStr)  ?? 0,
        },
        'copies': row['copies'] as int? ?? 1,
        'elements': elements,
      };
    } catch (_) { return null; }
  }

  List<Map<String, dynamic>> _buildFromDesigner(String jsonStr, LabelContext ctx) {
    try {
      final list = jsonDecode(jsonStr);
      if (list is! List || list.isEmpty) return [];
      return list.whereType<Map>().map<Map<String, dynamic>>((m) {
        final t = ElType.values.firstWhere(
            (e) => e.name == (m['t'] ?? 'text'), orElse: () => ElType.text);
        return LabelElement(
          type: t, x: m['x'] ?? 10, y: m['y'] ?? 10,
          text: m['text'] ?? '', font: m['font'] ?? '3',
          xScale: m['xs'] ?? 1, yScale: m['ys'] ?? 1, rotation: m['rot'] ?? 0,
          data: m['data'] ?? '', barcodeType: m['btype'] ?? '128',
          barcodeHeight: m['bh'] ?? 60, barcodeWidth: m['bw'] ?? 120,
          qrEcc: m['ecc'] ?? 'M', qrSize: m['qs'] ?? 4,
          xEnd: m['xe'] ?? 100, yEnd: m['ye'] ?? 100, thickness: m['th'] ?? 2,
          logoName: m['logo'] ?? 'LOGO.BMP',
          logoPath: m['logo_path'] as String? ?? '',
          logoBmpHex: m['logo_bmp'] as String? ?? '',
          logoBmpW: m['logo_bmpw'] as int? ?? 0,
          logoWidthDots: m['logo_w'] as int? ?? 80,
          logoHeightDots: m['logo_h'] as int? ?? 48,
          prefix: m['pre'] ?? '', suffix: m['suf'] ?? '',
          decimals: m['dec'] ?? 3, unit: m['unit'] ?? 'g',
        ).toJson(ctx);
      }).toList();
    } catch (_) { return []; }
  }

  List<Map<String, dynamic>> _buildFromLines(List<String> lines, LabelContext ctx, int wMm) {
    final elems = <Map<String, dynamic>>[];
    int y = 8;
    for (final raw in lines) {
      if (raw.trim().isEmpty) { y += 20; continue; }
      elems.add({'type': 'text', 'x': 8, 'y': y, 'font': '3', 'xs': 1, 'ys': 1, 'rot': 0,
          'text': _resolveVars(raw, ctx)});
      y += 32;
    }
    return elems;
  }

  String _resolveVars(String s, LabelContext ctx) => s
      .replaceAll('{net}',     ctx.netStr)   .replaceAll('{gross}',   ctx.grossStr)
      .replaceAll('{tare}',    ctx.tareStr)   .replaceAll('{stone}',   ctx.stoneStr)
      .replaceAll('{metal}',   ctx.metalStr)  .replaceAll('{serial}',  ctx.serial)
      .replaceAll('{date}',    ctx.dateStr)   .replaceAll('{time}',    ctx.timeStr)
      .replaceAll('{product}', ctx.product)   .replaceAll('{purity}',  ctx.purity)
      .replaceAll('{hsn}',     ctx.hsn)       .replaceAll('{rate}',    ctx.rateStr)
      .replaceAll('{amount}',  ctx.amountStr) .replaceAll('{making}',  ctx.makingStr)
      .replaceAll('{shop}',    ctx.shopName)  .replaceAll('{company}', ctx.companyName)
      .replaceAll('{address}', ctx.companyAddress)
      .replaceAll('{phone}',   ctx.companyPhone)
      .replaceAll('{gst}',     ctx.companyGst);

  // ── Reprint actions ──────────────────────────────────────────────────────────

  Future<void> _reprint({int? copies}) async {
    if (_job == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Template not found — cannot reprint')));
      return;
    }
    setState(() => _reprinting = true);
    await widget.onReprint(_job!, copies: copies);
    if (mounted) setState(() => _reprinting = false);
  }

  Future<void> _reprintCopies() async {
    final ctrl = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reprint — Number of Copies'),
        content: TextField(
          controller: ctrl, keyboardType: TextInputType.number, autofocus: true,
          decoration: const InputDecoration(labelText: 'Copies', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('PRINT')),
        ],
      ),
    ) ?? false;
    ctrl.dispose();
    if (!ok || !mounted) return;
    await _reprint(copies: (int.tryParse(ctrl.text) ?? 1).clamp(1, 99));
  }

  Future<void> _exportSinglePdf() async {
    final r      = widget.row;
    final serial = r['serial'] as String? ?? '';
    final ts     = DateTime.fromMillisecondsSinceEpoch(r['ts'] as int? ?? 0);
    final pdf    = pw.Document();
    pdf.addPage(pw.Page(
      pageFormat: PdfPageFormat.a5,
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('JBC-GS-PRINTER — Label Record',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Divider(), pw.SizedBox(height: 6),
        ...[
          ['Serial',   serial],
          ['Date',     _fmtDT.format(ts)],
          ['Product',  r['product']  ?? ''],
          ['Purity',   r['purity']   ?? ''],
          ['HSN',      r['hsn']      ?? ''],
          ['Gross g',  (r['gross_g'] as num?)?.toStringAsFixed(3) ?? ''],
          ['Tare g',   (r['tare_g']  as num?)?.toStringAsFixed(3) ?? ''],
          ['Net g',    (r['net_g']   as num?)?.toStringAsFixed(3) ?? ''],
          ['Stone g',  (r['stone_g'] as num?)?.toStringAsFixed(3) ?? ''],
          ['Rate ₹',   (r['rate']    as num?)?.toStringAsFixed(2) ?? ''],
          ['Amount ₹', (r['amount']  as num?)?.toStringAsFixed(2) ?? ''],
          ['Barcode',  r['barcode']  ?? ''],
          ['QR Data',  r['qr_data']  ?? ''],
          ['Operator', r['operator_name'] ?? ''],
          ['Template', r['template'] ?? ''],
          ['Copies',   (r['copies'] as int? ?? 1).toString()],
        ].where((e) => (e[1] as String).isNotEmpty).map((e) => pw.Row(children: [
          pw.SizedBox(width: 90,
              child: pw.Text(e[0], style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700))),
          pw.Expanded(child: pw.Text(e[1], style: const pw.TextStyle(fontSize: 9))),
        ])),
      ]),
    ));
    final dir  = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'label_${serial}_${ts.millisecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await pdf.save());
    await Share.shareXFiles([XFile(file.path)], text: 'Label Record — $serial');
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override Widget build(BuildContext context) {
    final cs      = Theme.of(context).colorScheme;
    final row     = widget.row;
    final serial  = row['serial']  as String? ?? '';
    final product = row['product'] as String? ?? '';
    final purity  = row['purity']  as String? ?? '';
    final ts      = DateTime.fromMillisecondsSinceEpoch(row['ts'] as int? ?? 0);
    final net     = (row['net_g']   as num?)?.toStringAsFixed(3) ?? '';
    final gross   = (row['gross_g'] as num?)?.toStringAsFixed(3) ?? '';
    final amount  = (row['amount']  as num?)?.toStringAsFixed(2) ?? '';
    final copies  = row['copies'] as int? ?? 1;
    final barcode = row['barcode']      as String? ?? '';
    final qrData  = row['qr_data']      as String? ?? '';

    List<Map<String, dynamic>> elements = [];
    int wMm = 50, hMm = 25;
    if (_job != null) {
      final lbl = _job!['label'] as Map<String, dynamic>? ?? {};
      wMm = (lbl['w'] as num? ?? 50).toInt();
      hMm = (lbl['h'] as num? ?? 25).toInt();
      final raw = _job!['elements'];
      if (raw is List) {
        elements = raw.whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m as Map)).toList();
      }
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.92, minChildSize: 0.5, maxChildSize: 0.97, expand: false,
      builder: (_, scrollCtrl) => Column(children: [
        // Handle
        Container(width: 36, height: 4, margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2))),

        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(serial, style: TextStyle(fontWeight: FontWeight.bold,
                  fontSize: 18, color: cs.primary)),
              Text('$product${purity.isNotEmpty ? " · $purity" : ""}'
                  ' — ${_fmtDT.format(ts)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ])),
            IconButton(icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context)),
          ]),
        ),
        const Divider(height: 1),

        // Body
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
            controller: scrollCtrl,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            children: [

              // ── Reconstructed notice ──────────────────────────────────────
              if (_jobReconstructed)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    border: Border.all(color: Colors.amber.shade300),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(children: [
                    Icon(Icons.info_outline, size: 14, color: Colors.amber.shade800),
                    const SizedBox(width: 6),
                    Expanded(child: Text(
                      'Rebuilt from current template — exact original layout may differ',
                      style: TextStyle(fontSize: 11, color: Colors.amber.shade900),
                    )),
                  ]),
                ),

              // ── Label canvas ──────────────────────────────────────────────
              if (elements.isNotEmpty)
                InteractiveViewer(
                  minScale: 0.5, maxScale: 5.0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: LabelCanvas(elements: elements, wMm: wMm, hMm: hMm),
                  ),
                )
              else
                Container(
                  height: 100, margin: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey.shade50,
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.image_not_supported_outlined,
                        color: Colors.grey.shade400, size: 28),
                    const SizedBox(height: 6),
                    Text('Template not found — preview unavailable',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                  ]),
                ),

              // ── Details card ──────────────────────────────────────────────
              Card(margin: const EdgeInsets.symmetric(vertical: 6), child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Label Details', style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.bold, color: cs.primary)),
                  const SizedBox(height: 8),
                  _dRow('Net Weight', net.isNotEmpty    ? '$net g'    : ''),
                  _dRow('Gross Weight', gross.isNotEmpty ? '$gross g' : ''),
                  _dRow('Amount',   amount.isNotEmpty   ? '₹ $amount' : ''),
                  _dRow('Copies',   copies > 1 ? copies.toString()    : ''),
                  _dRow('Barcode',  barcode),
                  _dRow('QR Data',  qrData),
                  _dRow('Operator', row['operator_name'] as String? ?? ''),
                  _dRow('Template', row['template']      as String? ?? ''),
                ]),
              )),
              const SizedBox(height: 6),
            ],
          ),
        ),

        // ── Action buttons ────────────────────────────────────────────────
        SafeArea(child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: _loading ? const SizedBox.shrink() : Column(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.icon(
              onPressed: (_reprinting || _job == null) ? null : () => _reprint(),
              icon: _reprinting
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.print),
              label: Text(_job == null ? 'Template Not Found' : 'Reprint Same Label'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: (_reprinting || _job == null) ? null : _reprintCopies,
                icon: const Icon(Icons.print_outlined, size: 18),
                label: const Text('N Copies'),
              )),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _exportSinglePdf,
                icon: const Icon(Icons.share_outlined, size: 18),
                label: const Text('PDF'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: widget.onMore,
                icon: const Icon(Icons.more_horiz, size: 18),
                label: const Text('More'),
              ),
            ]),
          ]),
        )),
      ]),
    );
  }

  Widget _dRow(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 90, child: Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.grey))),
        Expanded(child: Text(value,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500))),
      ]),
    );
  }
}
