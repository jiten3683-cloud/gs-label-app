import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../services/ble_service.dart';
import '../services/db_service.dart';
import '../models/label_element.dart';

/// The operator's "Print" screen. Shows live Gross / Tare / Net,
/// product picker, purity, copies, and a big PRINT button.
class ScalePage extends StatefulWidget {
  const ScalePage({super.key});
  @override
  State<ScalePage> createState() => _ScalePageState();
}

class _ScalePageState extends State<ScalePage> {
  final _productCtrl = TextEditingController();
  final _purityCtrl  = TextEditingController(text: '22K');
  final _rateCtrl    = TextEditingController();
  final _copiesCtrl  = TextEditingController(text: '1');
  String _unit = 'g';
  int? _templateId;
  List<Map<String, dynamic>> _templates = [];

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    final db = context.read<DbService>();
    _templates = await db.listTemplates();
    if (_templates.isNotEmpty) _templateId = _templates.first['id'] as int;
    setState(() {});
  }

  String _fmt(double v) => v.toStringAsFixed(3);

  Future<void> _print() async {
    final ble = context.read<BleService>();
    final db  = context.read<DbService>();
    if (!ble.isConnected) {
      _toast('Not connected to printer bridge'); return;
    }
    if (_templateId == null) { _toast('Pick a template first'); return; }

    final tplRow = await db.getTemplate(_templateId!);
    if (tplRow == null) return;
    final tplJson = (tplRow['json'] as String);
    final w = tplRow['width_mm'] as int;
    final h = tplRow['height_mm'] as int;
    final gap = tplRow['gap_mm'] as int;

    final serial = await db.nextSerial('GS-');
    final rate   = double.tryParse(_rateCtrl.text) ?? 0;
    final amount = rate * ble.netG;
    final ctx = LabelContext(
      netStr  : '${_fmt(ble.netG)} $_unit',
      grossStr: '${_fmt(ble.grossG)} $_unit',
      tareStr : '${_fmt(ble.tareG)} $_unit',
      serial  : serial,
      dateStr : DateFormat('dd-MM-yyyy').format(DateTime.now()),
      timeStr : DateFormat('HH:mm').format(DateTime.now()),
      product : _productCtrl.text,
      purity  : _purityCtrl.text,
      rateStr : rate.toStringAsFixed(2),
      amountStr: amount.toStringAsFixed(2),
    );

    // Re-hydrate elements from the stored template JSON and bind them.
    final elements = _renderElements(tplJson, ctx);
    final job = {
      'cmd'   : 'print',
      'label' : {'w': w, 'h': h, 'gap': gap},
      'copies': int.tryParse(_copiesCtrl.text) ?? 1,
      'elements': elements,
    };
    await ble.sendPrintJob(job);

    await db.logPrint({
      'serial' : serial,
      'product': _productCtrl.text,
      'purity' : _purityCtrl.text,
      'gross_g': ble.grossG, 'tare_g': ble.tareG, 'net_g': ble.netG,
      'rate'   : rate, 'amount': amount,
      'ts'     : DateTime.now().millisecondsSinceEpoch,
      'template': tplRow['name'],
    });
    _toast('Printed $serial');
  }

  /// Convert stored designer JSON -> bound element JSON for the firmware.
  List<Map<String, dynamic>> _renderElements(String tplJson, LabelContext ctx) {
    if (tplJson.isEmpty) return [];
    final dynamic decoded = jsonDecode(tplJson);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map<Map<String, dynamic>>(
            (m) => _fromMap(m.cast<String, dynamic>()).toJson(ctx))
        .toList();
  }

  LabelElement _fromMap(Map m) {
    final t = ElType.values.firstWhere(
      (e) => e.name == (m['t'] ?? 'text'),
      orElse: () => ElType.text);
    return LabelElement(
      type: t,
      x: m['x'] ?? 10, y: m['y'] ?? 10,
      text: m['text'] ?? '', font: m['font'] ?? '3',
      xScale: m['xs'] ?? 1, yScale: m['ys'] ?? 1,
      rotation: m['rot'] ?? 0,
      data: m['data'] ?? '',
      barcodeType: m['btype'] ?? '128',
      barcodeHeight: m['bh'] ?? 60,
      qrEcc: m['ecc'] ?? 'M', qrSize: m['qs'] ?? 4,
      xEnd: m['xe'] ?? 100, yEnd: m['ye'] ?? 100, thickness: m['th'] ?? 2,
      logoName: m['logo'] ?? 'LOGO.BMP',
      prefix: m['pre'] ?? '', suffix: m['suf'] ?? '',
      decimals: m['dec'] ?? 3, unit: m['unit'] ?? 'g',
    );
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _ReadingPanel(ble: ble, unit: _unit),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: ble.isConnected ? ble.tare : null,
              icon: const Icon(Icons.exposure_zero), label: const Text('TARE'),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: ble.isConnected ? ble.zero : null,
              icon: const Icon(Icons.restart_alt), label: const Text('ZERO'),
            )),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: _unit,
              items: const [
                DropdownMenuItem(value: 'g',  child: Text('grams')),
                DropdownMenuItem(value: 'mg', child: Text('mg')),
              ],
              onChanged: (v) => setState(() => _unit = v ?? 'g'),
            ),
          ]),
          const Divider(height: 32),
          Row(children: [
            Expanded(child: TextField(controller: _productCtrl,
              decoration: const InputDecoration(labelText: 'Product / Item'))),
            const SizedBox(width: 8),
            SizedBox(width: 90, child: TextField(controller: _purityCtrl,
              decoration: const InputDecoration(labelText: 'Purity'))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _rateCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Rate / gram (₹)'))),
            const SizedBox(width: 8),
            SizedBox(width: 90, child: TextField(controller: _copiesCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Copies'))),
          ]),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            value: _templateId,
            decoration: const InputDecoration(labelText: 'Template'),
            items: _templates.map((t) => DropdownMenuItem<int>(
              value: t['id'] as int, child: Text(t['name'] as String))).toList(),
            onChanged: (v) => setState(() => _templateId = v),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: ble.isConnected ? _print : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(64),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
            icon: const Icon(Icons.print, size: 28),
            label: const Text('PRINT LABEL',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ),
        ]),
      ),
    );
  }
}

class _ReadingPanel extends StatelessWidget {
  final BleService ble; final String unit;
  const _ReadingPanel({required this.ble, required this.unit});
  String _f(double v) => v.toStringAsFixed(3);
  @override
  Widget build(BuildContext context) {
    final color = ble.stable ? Colors.green : Colors.orange;
    return Card(
      elevation: 2,
      child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
        Row(children: [
          const Text('NET', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('${_f(ble.netG)} $unit',
            style: TextStyle(fontSize: 44, fontWeight: FontWeight.bold, color: color)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text('Gross: ${_f(ble.grossG)} $unit')),
          Expanded(child: Text('Tare:  ${_f(ble.tareG)} $unit')),
          Row(children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 4),
            Text(ble.stable ? 'STABLE' : '...',
              style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ]),
        ]),
      ])),
    );
  }
}

