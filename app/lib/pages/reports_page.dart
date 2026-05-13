import 'dart:io';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/db_service.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 7));
  DateTime _to   = DateTime.now();
  String   _product = '';
  List<Map<String, dynamic>> _rows = [];
  double _totalNet = 0, _totalAmount = 0;

  @override
  void initState() { super.initState(); _query(); }

  Future<void> _query() async {
    _rows = await context.read<DbService>().queryPrints(
      from: _from, to: _to, productLike: _product);
    _totalNet    = _rows.fold(0.0, (s, r) => s + (r['net_g']  as num).toDouble());
    _totalAmount = _rows.fold(0.0, (s, r) => s + ((r['amount'] ?? 0) as num).toDouble());
    setState(() {});
  }

  Future<void> _pick(bool from) async {
    final d = await showDatePicker(context: context,
      initialDate: from ? _from : _to,
      firstDate: DateTime(2024), lastDate: DateTime(2099));
    if (d != null) { setState(() { if (from) _from = d; else _to = d; }); _query(); }
  }

  Future<void> _exportCsv() async {
    final headers = ['Serial','Date','Product','Purity','Gross g','Tare g','Net g','Rate','Amount','Template'];
    final rows = <List<dynamic>>[headers, ..._rows.map((r) => [
      r['serial'], DateTime.fromMillisecondsSinceEpoch(r['ts'] as int).toIso8601String(),
      r['product'] ?? '', r['purity'] ?? '', r['gross_g'], r['tare_g'], r['net_g'],
      r['rate'] ?? '', r['amount'] ?? '', r['template'] ?? '',
    ])];
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'gs_report_${DateTime.now().millisecondsSinceEpoch}.csv'));
    await file.writeAsString(const ListToCsvConverter().convert(rows));
    await Share.shareXFiles([XFile(file.path)], text: 'GS print report');
  }

  Future<void> _exportXlsx() async {
    final ex = Excel.createExcel();
    final s = ex['Prints'];
    s.appendRow(['Serial','Date','Product','Purity','Gross g','Tare g','Net g','Rate','Amount']
        .map((e) => TextCellValue(e)).toList());
    for (final r in _rows) {
      s.appendRow([
        TextCellValue('${r['serial']}'),
        TextCellValue(DateFormat('yyyy-MM-dd HH:mm')
          .format(DateTime.fromMillisecondsSinceEpoch(r['ts'] as int))),
        TextCellValue('${r['product'] ?? ''}'),
        TextCellValue('${r['purity']  ?? ''}'),
        DoubleCellValue((r['gross_g'] as num).toDouble()),
        DoubleCellValue((r['tare_g']  as num).toDouble()),
        DoubleCellValue((r['net_g']   as num).toDouble()),
        DoubleCellValue(((r['rate']   ?? 0) as num).toDouble()),
        DoubleCellValue(((r['amount'] ?? 0) as num).toDouble()),
      ]);
    }
    final bytes = ex.encode();
    if (bytes == null) return;
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'gs_report_${DateTime.now().millisecondsSinceEpoch}.xlsx'));
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)], text: 'GS print report');
  }

  @override
  Widget build(BuildContext context) {
    final fmtD = DateFormat('dd-MMM-yy');
    final fmtT = DateFormat('dd-MMM HH:mm');
    return Column(children: [
      Padding(padding: const EdgeInsets.all(8), child: Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: () => _pick(true),
          icon: const Icon(Icons.event), label: Text('From: ${fmtD.format(_from)}')),
        OutlinedButton.icon(onPressed: () => _pick(false),
          icon: const Icon(Icons.event), label: Text('To: ${fmtD.format(_to)}')),
        SizedBox(width: 180, child: TextField(
          decoration: const InputDecoration(labelText: 'Product filter', isDense: true),
          onSubmitted: (s) { _product = s; _query(); })),
      ])),
      Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(child: Text('Rows: ${_rows.length}')),
          Expanded(child: Text('Total Net: ${_totalNet.toStringAsFixed(3)} g')),
          Expanded(child: Text('Total ₹: ${_totalAmount.toStringAsFixed(2)}')),
        ]),
      ),
      Expanded(child: ListView.separated(
        itemCount: _rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final r = _rows[i];
          return ListTile(
            dense: true,
            title: Text('${r['serial']}  ·  ${r['product'] ?? "-"}  '
                        '(${r['purity'] ?? "-"})'),
            subtitle: Text('Net ${r['net_g']} g  '
                           '·  ₹${(r['amount'] ?? 0)}  '
                           '·  ${fmtT.format(DateTime.fromMillisecondsSinceEpoch(r['ts'] as int))}'),
          );
        })),
      SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
        Expanded(child: FilledButton.icon(onPressed: _rows.isEmpty ? null : _exportCsv,
          icon: const Icon(Icons.download), label: const Text('Export CSV'))),
        const SizedBox(width: 8),
        Expanded(child: FilledButton.icon(onPressed: _rows.isEmpty ? null : _exportXlsx,
          icon: const Icon(Icons.table_chart), label: const Text('Export XLSX'))),
      ]))),
    ]);
  }
}
