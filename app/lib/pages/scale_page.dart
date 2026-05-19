import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../services/ble_service.dart';
import '../services/db_service.dart';
import '../models/label_element.dart';
import '../widgets/label_canvas.dart';

const _unitFactors = {'g': 1.0, 'mg': 1000.0, 'Tola': 1 / 11.6638, 'Carat': 1 / 0.2, 'Kg': 0.001};
const _unitDecimals = {'g': 3, 'mg': 1, 'Tola': 4, 'Carat': 3, 'Kg': 6};

double _convert(double grams, String unit) => grams * (_unitFactors[unit] ?? 1.0);
String _fmt(double grams, String unit) =>
    '${_convert(grams, unit).toStringAsFixed(_unitDecimals[unit] ?? 3)} $unit';

String _expandDots(String line, int wMm) {
  if (!line.contains('...')) return line;
  final totalChars = (wMm * 8 / 14).round();
  final parts = line.split('...');
  if (parts.length != 2) return line;
  final dots = (totalChars - parts[0].length - parts[1].length).clamp(3, 50);
  return '${parts[0]}${List.filled(dots, '.').join()}${parts[1]}';
}

// Read explicit wt field; fall back to prefix-based inference for old templates.
int _wtTypeFrom(Map m) {
  final v = m['wt'];
  if (v is int) return v.clamp(0, 2);
  final pfx = (m['pre'] as String? ?? '').toLowerCase();
  if (pfx.contains('gross')) return 1;
  if (pfx.contains('tare'))  return 2;
  return 0;
}

// Resolve all {variables} in a string from a LabelContext
String _resolveCtx(String s, LabelContext ctx) => s
    .replaceAll('{net}',      ctx.netStr)
    .replaceAll('{gross}',    ctx.grossStr)
    .replaceAll('{tare}',     ctx.tareStr)
    .replaceAll('{stone}',    ctx.stoneStr)
    .replaceAll('{metal}',    ctx.metalStr)
    .replaceAll('{serial}',   ctx.serial)
    .replaceAll('{date}',     ctx.dateStr)
    .replaceAll('{time}',     ctx.timeStr)
    .replaceAll('{product}',  ctx.product)
    .replaceAll('{purity}',   ctx.purity)
    .replaceAll('{hsn}',      ctx.hsn)
    .replaceAll('{category}', ctx.category)
    .replaceAll('{code}',     ctx.code)
    .replaceAll('{rate}',     ctx.rateStr)
    .replaceAll('{amount}',   ctx.amountStr)
    .replaceAll('{making}',   ctx.makingStr)
    .replaceAll('{shop}',     ctx.shopName)
    .replaceAll('{company}',  ctx.companyName)
    .replaceAll('{address}',  ctx.companyAddress)
    .replaceAll('{phone}',    ctx.companyPhone)
    .replaceAll('{gst}',      ctx.companyGst);

// =============================================================================
class ScalePage extends StatefulWidget {
  const ScalePage({super.key});
  @override State<ScalePage> createState() => _ScalePageState();
}

class _ScalePageState extends State<ScalePage> {
  final _productCtrl = TextEditingController();
  final _purityCtrl  = TextEditingController(text: '22K');
  final _hsnCtrl     = TextEditingController();
  final _rateCtrl    = TextEditingController();
  final _makingCtrl  = TextEditingController(text: '0');
  final _copiesCtrl  = TextEditingController(text: '1');
  final _stoneCtrl   = TextEditingController(text: '0.000');

  bool _manualMode        = false;
  final _manGrossCtrl     = TextEditingController(text: '0.000');
  final _manTareCtrl      = TextEditingController(text: '0.000');

  // App-side tare for live mode — editable by user or set by TARE button
  double _appTareG        = 0.0;
  final _appTareCtrl      = TextEditingController(text: '0.000');

  bool _showQuickPrint    = false;
  final _qp1Ctrl          = TextEditingController();
  final _qp2Ctrl          = TextEditingController();
  final _qp3Ctrl          = TextEditingController();

  String _unit            = 'g';
  int?   _templateId;
  String _productCategory = '';
  String _productCode     = '';
  List<Map<String, dynamic>> _templates = [];
  int    _queueCount      = 0;
  int    _printDirection  = 0;

  // Company profile variables loaded from settings
  String _shopName        = '';
  String _companyName     = '';
  String _companyAddress  = '';
  String _companyPhone    = '';
  String _companyGst      = '';

  // Scale diagnostics — shows raw UART string forwarded via BLE status
  String _scaleRaw        = '';
  bool   _showScaleDebug  = false;

  // Serial number preview
  String _nextSerialStr   = '';

  @override void initState() {
    super.initState();
    _loadSettings();
    _loadTemplates();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DbService>().templateVersion.addListener(_loadTemplates);
      // Capture raw scale diagnostic strings from BLE status notifications
      context.read<BleService>().addListener(_onBleUpdate);
    });
  }

  void _onBleUpdate() {
    final status = context.read<BleService>().lastStatus;
    if (status.startsWith('scale: ') || status.startsWith('scale:')) {
      final raw = status.replaceFirst(RegExp(r'^scale:\s*'), '');
      if (mounted) setState(() => _scaleRaw = raw);
    }
  }

  @override void dispose() {
    context.read<DbService>().templateVersion.removeListener(_loadTemplates);
    context.read<BleService>().removeListener(_onBleUpdate);
    for (final c in [_productCtrl, _purityCtrl, _hsnCtrl, _rateCtrl, _makingCtrl,
        _copiesCtrl, _stoneCtrl, _manGrossCtrl, _manTareCtrl,
        _appTareCtrl, _qp1Ctrl, _qp2Ctrl, _qp3Ctrl]) c.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final db = context.read<DbService>();
    final s  = await db.getAllSettings();
    if (!mounted) return;
    setState(() {
      final unit    = s['default_unit'] ?? 'g';
      _unit         = _unitFactors.containsKey(unit) ? unit : 'g';
      _printDirection  = int.tryParse(s['print_direction'] ?? '0') ?? 0;
      _shopName        = s['shop_name']        ?? '';
      _companyName     = s['company_name']     ?? '';
      _companyAddress  = s['company_address']  ?? '';
      _companyPhone    = s['company_phone']     ?? '';
      _companyGst      = s['company_gst']       ?? '';
    });
    _refreshQueueCount();
    _refreshNextSerial();
  }

  Future<void> _refreshNextSerial() async {
    if (!mounted) return;
    final db     = context.read<DbService>();
    final prefix = await db.getSetting('serial_prefix', def: 'GS-');
    final suffix = await db.getSetting('serial_suffix', def: '');
    final padLen = int.tryParse(await db.getSetting('serial_pad', def: '5')) ?? 5;
    // peekNextSerial reads without incrementing — only _print() consumes a serial
    final next   = await db.peekNextSerial(prefix, padLen: padLen, suffix: suffix);
    if (mounted) setState(() => _nextSerialStr = next);
  }

  Future<void> _loadTemplates() async {
    final db = context.read<DbService>();
    await db.seedDefaultTemplates();
    _templates = await db.listTemplates();
    if (_templates.isNotEmpty && _templateId == null) {
      _templateId = _templates.first['id'] as int;
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshQueueCount() async {
    if (!mounted) return;
    _queueCount = await context.read<DbService>().queueCount();
    setState(() {});
  }

  // ── Weight ──────────────────────────────────────────────────────────────────
  double get _resolvedGross =>
      _manualMode ? (double.tryParse(_manGrossCtrl.text) ?? 0) : context.read<BleService>().grossG;
  double get _resolvedTare {
    if (_manualMode) return double.tryParse(_manTareCtrl.text) ?? 0;
    return _appTareG; // app-side tare (0 means untared)
  }
  double get _resolvedNet =>
      _manualMode
          ? (_resolvedGross - _resolvedTare).clamp(0, double.infinity)
          : (_resolvedGross - _appTareG).clamp(0, double.infinity);
  double get _stoneG   => (double.tryParse(_stoneCtrl.text) ?? 0).clamp(0, double.infinity);
  double get _metalNet => (_resolvedNet  - _stoneG).clamp(0, double.infinity);
  double get _rate     => double.tryParse(_rateCtrl.text)   ?? 0;
  double get _making   => double.tryParse(_makingCtrl.text) ?? 0;
  double get _amount   => _metalNet * _rate * (1 + _making / 100);

  void _captureFromScale() {
    final ble = context.read<BleService>();
    setState(() {
      _manGrossCtrl.text = ble.grossG.toStringAsFixed(3);
      _manTareCtrl.text  = ble.tareG.toStringAsFixed(3);
    });
  }

  Future<void> _pickProduct() async {
    final all = await context.read<DbService>().listProducts();
    if (!mounted) return;
    await showModalBottomSheet(
      context: context, isScrollControlled: true, useSafeArea: true,
      builder: (_) => _ProductPicker(products: all, onSelect: (p) {
        setState(() {
          _productCtrl.text = p['name']    as String? ?? '';
          _purityCtrl.text  = p['purity']  as String? ?? '';
          _hsnCtrl.text     = p['hsn']     as String? ?? '';
          _rateCtrl.text    = (p['rate']   as num? ?? 0).toString();
          _makingCtrl.text  = (p['making'] as num? ?? 0).toString();
          _productCategory  = p['category'] as String? ?? '';
          _productCode      = p['code']     as String? ?? '';
          final tid = p['template_id'] as int?;
          if (tid != null && _templates.any((t) => t['id'] == tid)) _templateId = tid;
        });
      }),
    );
  }

  // ── Build LabelContext from current state ────────────────────────────────────
  LabelContext _buildCtx(String serial) {
    final now  = DateTime.now();
    final stoG = _stoneG;
    final metG = _metalNet;
    return LabelContext(
      netStr:    _fmt(_resolvedNet,   _unit),
      grossStr:  _fmt(_resolvedGross, _unit),
      tareStr:   _fmt(_resolvedTare,  _unit),
      stoneStr:  stoG > 0 ? _fmt(stoG, _unit) : '',
      metalStr:  _fmt(metG, _unit),
      serial:    serial,
      dateStr:   DateFormat('dd-MM-yyyy').format(now),
      timeStr:   DateFormat('HH:mm').format(now),
      product:        _productCtrl.text,
      purity:         _purityCtrl.text,
      hsn:            _hsnCtrl.text,
      category:       _productCategory,
      code:           _productCode,
      rateStr:        _rate.toStringAsFixed(2),
      amountStr:      _amount.toStringAsFixed(2),
      makingStr:      (_metalNet * _rate * _making / 100).toStringAsFixed(2),
      shopName:       _shopName,
      companyName:    _companyName,
      companyAddress: _companyAddress,
      companyPhone:   _companyPhone,
      companyGst:     _companyGst,
    );
  }

  // ── Resolve template lines → TSPL elements ───────────────────────────────────
  List<Map<String, dynamic>> _buildFromLines(
      List<String> lines, LabelContext ctx, int wMm, [int hMm = 25]) {
    final elems = <Map<String, dynamic>>[];
    final hDots = hMm * 8;
    // Small labels (≤15 mm tall): font-2 (20 dots) with tight 20-dot step packs
    // 4 lines into 80 dots (10 mm). Larger labels keep font-3 (24 dots) + spacing.
    final bool small = hMm <= 15;
    final String font = small ? '2' : '3';
    final int fontH   = small ? 20 : 24;
    final int step    = small ? 20 : 32;
    int y = small ? 0 : 8;
    for (final raw in lines) {
      if (y + fontH > hDots) break;
      if (raw.trim().isEmpty) { y += step ~/ 2; continue; }
      elems.add({'type': 'text', 'x': 8, 'y': y, 'font': font,
          'xs': 1, 'ys': 1, 'rot': 0,
          'text': _resolveCtx(_expandDots(raw, wMm), ctx)});
      y += step;
    }
    return elems;
  }

  // ── Resolve designer elements → TSPL elements ────────────────────────────────
  List<Map<String, dynamic>> _buildFromElements(String tplJson, LabelContext ctx) {
    if (tplJson.isEmpty) return [];
    try {
      final list = jsonDecode(tplJson);
      if (list is! List) return [];
      final result = <Map<String, dynamic>>[];
      for (final m in list.whereType<Map>()) {
        final t = ElType.values.firstWhere(
            (e) => e.name == (m['t'] ?? 'text'), orElse: () => ElType.text);
        final isBold = m['bold'] as bool? ?? false;
        final resolved = LabelElement(
          type: t, x: m['x'] ?? 10, y: m['y'] ?? 10,
          text: m['text'] ?? '', font: m['font'] ?? '3',
          xScale: m['xs'] ?? 1, yScale: m['ys'] ?? 1, rotation: m['rot'] ?? 0,
          bold: isBold,
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
          wtType: _wtTypeFrom(m),
        ).toJson(ctx);
        result.add(resolved);
        // Bold: print text twice with 1-dot x offset (double-strike thermal bold)
        if (isBold && resolved['type'] == 'text') {
          final copy = Map<String, dynamic>.from(resolved);
          copy['x'] = (resolved['x'] as int) + 1;
          result.add(copy);
        }
      }
      return result;
    } catch (_) { return []; }
  }

  // Font character heights in printer dots at 203 DPI
  static const Map<String, int> _kFontDotH = {
    '1': 12, '2': 20, '3': 24, '4': 32, '5': 48, '6': 19, '7': 27, '8': 21,
  };

  // Clamp element positions so no content overflows the label boundary.
  // The app canvas clips visually (Clip.hardEdge) but the printer does not —
  // this ensures what the preview shows is what actually prints.
  List<Map<String, dynamic>> _clampToLabel(
      List<Map<String, dynamic>> elems, int wDots, int hDots) {
    final out = <Map<String, dynamic>>[];
    for (final e in elems) {
      final type = e['type'] as String? ?? '';
      final x = (e['x'] as num? ?? 0).toInt();
      final y = (e['y'] as num? ?? 0).toInt();
      if (x >= wDots || y >= hDots) continue;   // anchor completely outside
      final c = Map<String, dynamic>.from(e);
      switch (type) {
        case 'text':
          final ys    = (e['ys'] as num? ?? 1).toInt();
          final textH = (_kFontDotH[e['font'] as String? ?? '3'] ?? 24) * ys;
          if (y + textH > hDots) c['y'] = (hDots - textH).clamp(0, hDots - 1);
        case 'qr':
          final qrDots = (e['size'] as num? ?? 4).toInt() * 25;
          if (x + qrDots > wDots) c['x'] = (wDots - qrDots).clamp(0, wDots - 1);
          if (y + qrDots > hDots) c['y'] = (hDots - qrDots).clamp(0, hDots - 1);
        case 'bar':
          final barH = (e['height'] as num? ?? 60).toInt();
          if (y + barH > hDots) {
            final clamped = (hDots - y).clamp(8, barH);
            c['height'] = clamped;
          }
      }
      out.add(c);
    }
    return out;
  }

  // For small labels: if all content elements are in the bottom half of the label
  // (caused by _add() clamping), shift them up so the first element starts near y=0.
  // Box and logo elements keep their positions (they are layout anchors).
  List<Map<String, dynamic>> _normalizeTop(
      List<Map<String, dynamic>> elems, int hDots) {
    final contentTypes = {'text', 'qr', 'bar'};
    int minY = hDots;
    for (final e in elems) {
      if (contentTypes.contains(e['type'] as String? ?? '')) {
        final y = (e['y'] as num? ?? 0).toInt();
        if (y < minY) minY = y;
      }
    }
    if (minY <= hDots ~/ 2) return elems; // already in top half, nothing to do
    final shift = minY - 4;               // shift so top element lands at y=4 (0.5 mm margin)
    if (shift <= 0) return elems;
    return elems.map((e) {
      if (!contentTypes.contains(e['type'] as String? ?? '')) return e;
      final c = Map<String, dynamic>.from(e);
      c['y'] = ((e['y'] as num? ?? 0).toInt() - shift).clamp(0, hDots - 1);
      return c;
    }).toList();
  }

  // ── Get resolved elements for a template ────────────────────────────────────
  List<Map<String, dynamic>> _resolveTemplate(
      Map<String, dynamic> tplRow, LabelContext ctx) {
    final wMm  = tplRow['width_mm']  as int? ?? 50;
    final hMm  = tplRow['height_mm'] as int? ?? 25;
    // Designer elements take priority — they support all types (QR, barcode, logo…)
    final elems = _buildFromElements(tplRow['json'] as String? ?? '[]', ctx);
    if (elems.isNotEmpty) {
      var clamped = _clampToLabel(elems, wMm * 8, hMm * 8);
      // For small labels, prevent content being stuck at bottom due to _add() clamping.
      if (hMm <= 15) clamped = _normalizeTop(clamped, hMm * 8);
      return clamped;
    }
    // Fall back to line-based text when no designer elements exist
    final lines = DbService.parseLines(tplRow);
    return _buildFromLines(lines, ctx, wMm, hMm);
  }

  // ── Runtime preview ──────────────────────────────────────────────────────────
  Future<void> _showPreview() async {
    if (_templateId == null) { _toast('Pick a template first'); return; }
    final db     = context.read<DbService>();
    final tplRow = await db.getTemplate(_templateId!);
    if (tplRow == null || !mounted) return;

    final ctx      = _buildCtx('PREVIEW');
    final elements = _resolveTemplate(tplRow, ctx);
    final wMm      = tplRow['width_mm']  as int? ?? 50;
    final hMm      = tplRow['height_mm'] as int? ?? 25;

    showModalBottomSheet(
      context: context, isScrollControlled: true, useSafeArea: true,
      builder: (_) => _PrintPreview(
        templateName: tplRow['name'] as String? ?? '',
        wMm: wMm, hMm: hMm, elements: elements, ctx: ctx,
        onPrint: () { Navigator.pop(context); _print(); },
      ),
    );
  }

  Future<void> _print() async {
    final ble = context.read<BleService>();
    final db  = context.read<DbService>();

    if (_templateId == null) { _toast('Pick a template first'); return; }
    if (_resolvedNet <= 0 && !_manualMode) {
      _toast('Weight is zero — place item on scale or use manual entry'); return;
    }

    final tplRow = await db.getTemplate(_templateId!);
    if (tplRow == null) { _toast('Template not found'); return; }

    final prefix   = await db.getSetting('serial_prefix', def: 'GS-');
    final suffix   = await db.getSetting('serial_suffix', def: '');
    final padLen   = int.tryParse(await db.getSetting('serial_pad', def: '5')) ?? 5;
    final serial   = await db.nextSerial(prefix, padLen: padLen, suffix: suffix);
    final ctx      = _buildCtx(serial);
    final elements = _resolveTemplate(tplRow, ctx);

    if (elements.isEmpty) { _toast('Template has no content — add lines or design elements'); return; }

    final darkStr = await db.getSetting('default_darkness', def: '8');
    final dirStr  = await db.getSetting('print_direction', def: '0');
    final copies  = int.tryParse(_copiesCtrl.text) ?? 1;
    final job = {
      'cmd': 'print',
      'label': {
        'w': tplRow['width_mm'], 'h': tplRow['height_mm'],
        'gap': tplRow['gap_mm'], 'darkness': int.tryParse(darkStr) ?? 8,
        'dir': int.tryParse(dirStr) ?? 0,
      },
      'copies': copies,
      'elements': elements,
    };

    bool sent = false;
    try {
      sent = await ble.sendPrintJob(job);
    } catch (e) {
      _toast('BLE error: $e');
      return;
    }
    if (!sent) {
      await db.enqueuePrint(job, labelInfo: '${_productCtrl.text} – $serial');
      await _refreshQueueCount();
      _toast('Saved to offline queue ($_queueCount pending)');
    } else { _toast('Printed $serial'); }

    // Extract barcode and QR data from resolved elements for print log
    String barcodeData = '';
    String qrData = '';
    for (final el in elements) {
      if (el['type'] == 'barcode' && barcodeData.isEmpty) barcodeData = el['data'] as String? ?? '';
      if (el['type'] == 'qr'      && qrData.isEmpty)      qrData      = el['data'] as String? ?? '';
    }

    await db.logPrint({
      'serial': serial, 'product': _productCtrl.text,
      'purity': _purityCtrl.text, 'hsn': _hsnCtrl.text,
      'gross_g': _resolvedGross, 'tare_g': _resolvedTare, 'net_g': _resolvedNet,
      'stone_g': _stoneG,
      'rate': _rate, 'making': _making, 'amount': _amount,
      'barcode': barcodeData, 'qr_data': qrData,
      'operator_name': _shopName,
      'printer_name': ble.deviceName,
      'copies': copies,
      'ts': DateTime.now().millisecondsSinceEpoch, 'template': tplRow['name'],
      'job_snapshot': jsonEncode(job),  // full resolved job for report preview/reprint
    });
    _refreshNextSerial();
  }

  Future<void> _quickPrint() async {
    final ble  = context.read<BleService>();
    final db   = context.read<DbService>();
    final lines = [_qp1Ctrl.text, _qp2Ctrl.text, _qp3Ctrl.text]
        .where((s) => s.trim().isNotEmpty).toList();
    if (lines.isEmpty) { _toast('Enter at least one line'); return; }

    int wMm = 50, hMm = 25, gap = 3;
    if (_templateId != null) {
      final tpl = await db.getTemplate(_templateId!);
      if (tpl != null) {
        wMm = tpl['width_mm'] as int? ?? 50;
        hMm = tpl['height_mm'] as int? ?? 25;
        gap = tpl['gap_mm'] as int? ?? 3;
      }
    }
    final elems = lines.asMap().entries.map((e) =>
        {'type': 'text', 'x': 8, 'y': 8 + e.key * 32,
         'font': '3', 'xs': 1, 'ys': 1, 'rot': 0, 'text': e.value}).toList();

    final dirStr2 = await db.getSetting('print_direction', def: '0');
    final job = {'cmd': 'print',
        'label': {'w': wMm, 'h': hMm, 'gap': gap, 'dir': int.tryParse(dirStr2) ?? 0},
        'copies': 1, 'elements': elems};
    final sent = await ble.sendPrintJob(job);
    if (!sent) {
      await db.enqueuePrint(job, labelInfo: lines.first);
      await _refreshQueueCount();
      _toast('Saved to offline queue');
    } else { _toast('Quick print sent'); }
  }

  void _toast(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  @override Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    return SafeArea(
      child: ListView(padding: const EdgeInsets.all(14), children: [

        // ── Weight mode toggle ──────────────────────────────────────────────
        Row(children: [
          const Text('Source:', style: TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(width: 10),
          ChoiceChip(label: const Text('Live Scale'), selected: !_manualMode,
              onSelected: (_) => setState(() => _manualMode = false)),
          const SizedBox(width: 8),
          ChoiceChip(label: const Text('Manual'), selected: _manualMode,
              onSelected: (_) => setState(() => _manualMode = true)),
        ]),
        const SizedBox(height: 8),

        // ── Weight display ──────────────────────────────────────────────────
        _manualMode
            ? _ManualWeightPanel(
                grossCtrl: _manGrossCtrl, tareCtrl: _manTareCtrl,
                net: _resolvedNet, unit: _unit,
                onCapture: ble.isConnected ? _captureFromScale : null,
                onChanged: () => setState(() {}))
            : _WeightCard(
                ble: ble, unit: _unit,
                appTareCtrl: _appTareCtrl, appTareG: _appTareG,
                onTareChanged: (v) => setState(() => _appTareG = v),
              ),
        const SizedBox(height: 4),

        // ── Scale raw debug (collapsed by default) ──────────────────────────
        if (!_manualMode)
          InkWell(
            onTap: () => setState(() => _showScaleDebug = !_showScaleDebug),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(Icons.bug_report_outlined, size: 14,
                    color: Colors.grey.shade500),
                const SizedBox(width: 4),
                Text('Scale diagnostics', style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade500)),
                const Spacer(),
                Icon(_showScaleDebug ? Icons.expand_less : Icons.expand_more,
                    size: 14, color: Colors.grey.shade500),
              ]),
            ),
          ),
        if (!_manualMode && _showScaleDebug)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.grey.shade800),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('RAW UART via BLE',
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600,
                      letterSpacing: 1.5)),
              const SizedBox(height: 4),
              Text(
                _scaleRaw.isEmpty ? '(waiting for first scale packet…)' : _scaleRaw,
                style: TextStyle(
                    fontFamily: 'monospace', fontSize: 11,
                    color: _scaleRaw.isEmpty ? Colors.grey : Colors.greenAccent),
              ),
              const SizedBox(height: 4),
              Text('Parsed: ${ble.grossG.toStringAsFixed(3)} g  '
                  'Stable: ${ble.stable}  '
                  'Updated: ${ble.lastSeen != null ? "${DateTime.now().difference(ble.lastSeen!).inSeconds}s ago" : "never"}',
                  style: const TextStyle(fontFamily: 'monospace',
                      fontSize: 10, color: Colors.white54)),
            ]),
          ),
        const SizedBox(height: 4),

        // ── Scale controls ──────────────────────────────────────────────────
        Row(children: [
          if (!_manualMode) ...[
            Expanded(child: FilledButton.icon(
              onPressed: ble.isConnected ? () {
                final g = ble.grossG;
                setState(() {
                  _appTareG = g;
                  _appTareCtrl.text = g.toStringAsFixed(3);
                });
                ble.tare();
              } : null,
              icon: const Icon(Icons.exposure_zero, size: 18), label: const Text('TARE'),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: () => setState(() {
                _appTareG = 0;
                _appTareCtrl.text = '0.000';
                if (ble.isConnected) ble.zero();
              }),
              icon: const Icon(Icons.restart_alt, size: 18), label: const Text('ZERO'),
            )),
            const SizedBox(width: 8),
          ],
          DropdownButton<String>(
            value: _unit, isDense: true,
            items: _unitFactors.keys
                .map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
            onChanged: (v) => setState(() => _unit = v ?? 'g'),
          ),
        ]),

        // ── Stone weight ────────────────────────────────────────────────────
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(
            controller: _stoneCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Stone Weight (g)', prefixIcon: Icon(Icons.diamond_outlined),
              suffixText: 'g', border: OutlineInputBorder(), isDense: true,
            ),
          )),
          if (_stoneG > 0) ...[
            const SizedBox(width: 10),
            Expanded(child: Card(
              color: Colors.amber.shade50,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Metal Net', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  Text(_fmt(_metalNet, _unit),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ]),
              ),
            )),
          ],
        ]),

        const Divider(height: 24),

        // ── Amount preview ──────────────────────────────────────────────────
        if (_rate > 0) Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Net: ${_fmt(_resolvedNet, _unit)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (_stoneG > 0) ...[
                  Text('Stone: − ${_fmt(_stoneG, _unit)}',
                      style: const TextStyle(color: Colors.deepOrange)),
                  Text('Metal: ${_fmt(_metalNet, _unit)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
                Text('Making: ${_making.toStringAsFixed(1)}%  '
                    '= ₹${(_metalNet * _rate * _making / 100).toStringAsFixed(2)}'),
              ])),
              Text('₹${_amount.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary)),
            ]),
          ),
        ),
        const SizedBox(height: 8),

        // ── Product picker ──────────────────────────────────────────────────
        InkWell(
          onTap: _pickProduct,
          child: InputDecorator(
            decoration: const InputDecoration(
                labelText: 'Product / Item', prefixIcon: Icon(Icons.inventory_2_outlined),
                suffixIcon: Icon(Icons.search), border: OutlineInputBorder()),
            child: Text(
              _productCtrl.text.isEmpty ? 'Tap to search product…' : _productCtrl.text,
              style: TextStyle(color: _productCtrl.text.isEmpty ? Colors.grey : null),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _tf(_purityCtrl, 'Purity', TextInputType.text)),
          const SizedBox(width: 8),
          Expanded(child: _tf(_hsnCtrl, 'HSN Code', TextInputType.number)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _tf(_rateCtrl, 'Rate/g (₹)', TextInputType.number,
              onChanged: (_) => setState(() {}))),
          const SizedBox(width: 8),
          SizedBox(width: 110, child: _tf(_makingCtrl, 'Making %',
              TextInputType.number, onChanged: (_) => setState(() {}))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: DropdownButtonFormField<int>(
            initialValue: _templateId,
            decoration: const InputDecoration(labelText: 'Template', border: OutlineInputBorder()),
            items: _templates.map((t) => DropdownMenuItem<int>(
                value: t['id'] as int, child: Text(t['name'] as String))).toList(),
            onChanged: (v) => setState(() => _templateId = v),
          )),
          const SizedBox(width: 8),
          SizedBox(width: 90, child: _tf(_copiesCtrl, 'Copies', TextInputType.number)),
        ]),
        const SizedBox(height: 10),

        // ── Next serial preview ─────────────────────────────────────────────
        if (_nextSerialStr.isNotEmpty)
          Row(children: [
            const Icon(Icons.confirmation_num_outlined, size: 15, color: Colors.grey),
            const SizedBox(width: 4),
            Text('Next serial: ', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            Text(_nextSerialStr, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, size: 16),
              tooltip: 'Refresh serial preview',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: _refreshNextSerial,
            ),
          ]),
        const SizedBox(height: 8),

        // ── Preview + Print ─────────────────────────────────────────────────
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: _showPreview,
            icon: const Icon(Icons.preview_outlined, size: 22),
            label: const Text('PREVIEW', style: TextStyle(fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 60)),
          )),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: Stack(alignment: Alignment.topRight, children: [
            FilledButton.icon(
              onPressed: _print,
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(60),
                  backgroundColor: Theme.of(context).colorScheme.primary),
              icon: const Icon(Icons.print, size: 26),
              label: Text(ble.isConnected ? 'PRINT LABEL' : 'QUEUE OFFLINE',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            if (_queueCount > 0)
              Positioned(top: 6, right: 6, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.orange,
                    borderRadius: BorderRadius.circular(10)),
                child: Text('$_queueCount queued',
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              )),
          ])),
        ]),

        if (ble.isReconnecting)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
              SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('Reconnecting…', style: TextStyle(color: Colors.orange)),
            ]),
          ),

        const SizedBox(height: 12),

        // ── Quick Print ─────────────────────────────────────────────────────
        Card(child: Column(children: [
          InkWell(
            onTap: () => setState(() => _showQuickPrint = !_showQuickPrint),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                const Icon(Icons.flash_on, color: Colors.amber),
                const SizedBox(width: 8),
                const Expanded(child: Text('Quick Print',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                const Text('custom 3-line print',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(width: 8),
                Icon(_showQuickPrint ? Icons.expand_less : Icons.expand_more),
              ]),
            ),
          ),
          if (_showQuickPrint)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(children: [
                const Divider(height: 8),
                const SizedBox(height: 8),
                _tf(_qp1Ctrl, 'Line 1', TextInputType.text),
                const SizedBox(height: 8),
                _tf(_qp2Ctrl, 'Line 2', TextInputType.text),
                const SizedBox(height: 8),
                _tf(_qp3Ctrl, 'Line 3', TextInputType.text),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _quickPrint,
                  icon: const Icon(Icons.flash_on, size: 20),
                  label: const Text('Quick Print'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: Colors.amber.shade700),
                ),
              ]),
            ),
        ])),
        const SizedBox(height: 24),
      ]),
    );
  }

  Widget _tf(TextEditingController c, String label, TextInputType type,
      {void Function(String)? onChanged}) =>
      TextField(
        controller: c, keyboardType: type, onChanged: onChanged,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );
}

// =============================================================================
// Green-on-black live weight card with editable tare
class _WeightCard extends StatelessWidget {
  final BleService ble;
  final String unit;
  final TextEditingController appTareCtrl;
  final double appTareG;
  final ValueChanged<double> onTareChanged;

  const _WeightCard({
    required this.ble,
    required this.unit,
    required this.appTareCtrl,
    required this.appTareG,
    required this.onTareChanged,
  });

  @override Widget build(BuildContext context) {
    final stable = ble.stable;
    final col    = stable ? Colors.greenAccent : Colors.orange;
    final net    = (ble.grossG - appTareG).clamp(0.0, double.infinity);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: stable ? Colors.green.shade700 : Colors.orange.shade700, width: 1.5),
      ),
      child: Column(children: [
        // ── NET (app-computed: gross − appTare) ──────────────────────────────
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('NET', style: TextStyle(fontSize: 13, color: Colors.grey.shade400,
                letterSpacing: 2, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Row(children: [
              Icon(Icons.circle, size: 9, color: col),
              const SizedBox(width: 5),
              Text(stable ? 'STABLE' : 'MOTION',
                  style: TextStyle(fontSize: 10, color: col,
                      fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            ]),
          ]),
          const Spacer(),
          Flexible(child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(_fmt(net, unit),
                style: TextStyle(fontSize: 44, fontWeight: FontWeight.bold,
                    fontFamily: 'monospace', color: col, letterSpacing: 1)),
          )),
        ]),
        const SizedBox(height: 10),
        Divider(color: Colors.grey.shade800, height: 1),
        const SizedBox(height: 10),
        // ── GROSS (read-only) + TARE (editable) ─────────────────────────────
        Row(children: [
          Expanded(child: _wCard('GROSS', _fmt(ble.grossG, unit), Colors.white)),
          const SizedBox(width: 8),
          Expanded(child: _editableTare()),
        ]),
        if (appTareG == 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(Icons.info_outline, size: 12, color: Colors.orange.shade400),
              const SizedBox(width: 4),
              Flexible(child: Text('Tare=0: label will print Gross=Net. Set tare first.',
                  style: TextStyle(fontSize: 10, color: Colors.orange.shade400))),
            ]),
          ),
      ]),
    );
  }

  // Editable tare tile — matches the visual style of _wCard but with a TextField
  Widget _editableTare() => Container(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
    decoration: BoxDecoration(
      color: Colors.grey.shade900,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.orange.shade800),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('TARE (edit)', style: TextStyle(fontSize: 9, color: Colors.orange.shade400,
          letterSpacing: 1.5, fontWeight: FontWeight.w500)),
      const SizedBox(height: 2),
      TextField(
        controller: appTareCtrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (s) {
          final v = double.tryParse(s);
          if (v != null && v >= 0) onTareChanged(v);
        },
        style: TextStyle(fontSize: 22, color: Colors.orange.shade300,
            fontFamily: 'monospace', fontWeight: FontWeight.w500),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.zero,
          suffixText: 'g',
          suffixStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.transparent)),
          focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.orange.shade400, width: 1.5)),
        ),
      ),
    ]),
  );

  Widget _wCard(String label, String value, Color valueColor) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.grey.shade900,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.grey.shade800),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade500,
          letterSpacing: 2.0, fontWeight: FontWeight.w500)),
      const SizedBox(height: 3),
      Text(value, style: TextStyle(fontSize: 22, color: valueColor,
          fontFamily: 'monospace', fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis, maxLines: 1),
    ]),
  );
}

// =============================================================================
// Manual weight panel — Net = Gross − Tare (read-only)
class _ManualWeightPanel extends StatelessWidget {
  final TextEditingController grossCtrl, tareCtrl;
  final double net; final String unit;
  final VoidCallback? onCapture; final VoidCallback onChanged;
  const _ManualWeightPanel({required this.grossCtrl, required this.tareCtrl,
      required this.net, required this.unit, required this.onCapture, required this.onChanged});

  @override Widget build(BuildContext context) {
    Widget wf(TextEditingController c, String label, Color labelColor, Color textColor) =>
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 9, color: labelColor,
          letterSpacing: 2.0, fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => onChanged(),
        style: TextStyle(color: textColor, fontSize: 22,
            fontFamily: 'monospace', fontWeight: FontWeight.w500),
        decoration: InputDecoration(
          suffixText: 'g',
          suffixStyle: TextStyle(color: Colors.grey.shade500, fontSize: 14),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.grey.shade700),
            borderRadius: BorderRadius.circular(6),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: Colors.green, width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    ]));

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade700, width: 1.5),
      ),
      child: Column(children: [
        Row(children: [
          Icon(Icons.edit_note, size: 16, color: Colors.grey.shade400),
          const SizedBox(width: 6),
          Text('Manual Entry', style: TextStyle(color: Colors.grey.shade300,
              fontWeight: FontWeight.w500)),
          const Spacer(),
          if (onCapture != null)
            TextButton.icon(
              onPressed: onCapture,
              icon: const Icon(Icons.download, size: 15, color: Colors.green),
              label: const Text('From Scale',
                  style: TextStyle(color: Colors.green, fontSize: 12)),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2)),
            ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          wf(grossCtrl, 'GROSS', Colors.grey.shade400, Colors.white),
          const SizedBox(width: 10),
          wf(tareCtrl,  'TARE',  Colors.orange.shade400, Colors.orange.shade200),
        ]),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.green.shade900.withOpacity(0.25),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.green.shade800),
          ),
          child: Row(children: [
            Text('NET', style: TextStyle(fontSize: 11, color: Colors.grey.shade400,
                letterSpacing: 2, fontWeight: FontWeight.w500)),
            const Spacer(),
            Flexible(child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(_fmt(net < 0 ? 0 : net, unit),
                  style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold,
                      fontFamily: 'monospace', color: Colors.greenAccent)),
            )),
          ]),
        ),
      ]),
    );
  }
}

// =============================================================================
// PRINT PREVIEW — renders a full visual canvas of the label
class _PrintPreview extends StatelessWidget {
  final String templateName;
  final int wMm, hMm;
  final List<Map<String, dynamic>> elements;
  final LabelContext ctx;
  final VoidCallback onPrint;

  const _PrintPreview({
    required this.templateName, required this.wMm, required this.hMm,
    required this.elements, required this.ctx, required this.onPrint,
  });

  @override Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9, minChildSize: 0.5, maxChildSize: 0.95, expand: false,
      builder: (ctx2, scroll) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(children: [
          Container(margin: const EdgeInsets.only(top: 10), width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Icon(Icons.preview_outlined, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(templateName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Text('$wMm × $hMm mm  •  ${elements.length} element(s)',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ])),
              IconButton(icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          const Divider(),
          Expanded(child: SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              // ── Visual label canvas ──────────────────────────────────────
              Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  const Text('LABEL PREVIEW',
                      style: TextStyle(fontSize: 10, letterSpacing: 2, color: Colors.grey)),
                  const SizedBox(height: 8),
                  LabelCanvas(elements: elements, wMm: wMm, hMm: hMm),
                ]),
              ),
              const SizedBox(height: 20),

              // ── Data summary cards ───────────────────────────────────────
              _summaryCard(context, 'Weight', [
                _row(context, 'Net',   ctx.netStr,   Colors.green.shade700),
                _row(context, 'Gross', ctx.grossStr, Colors.black87),
                _row(context, 'Tare',  ctx.tareStr,  Colors.black87),
                if (ctx.stoneStr.isNotEmpty)
                  _row(context, 'Stone (deduction)', ctx.stoneStr, Colors.deepOrange),
                if (ctx.metalStr.isNotEmpty)
                  _row(context, 'Metal Net', ctx.metalStr, Colors.green.shade700),
              ]),
              if (ctx.product.isNotEmpty || ctx.purity.isNotEmpty) ...[
                const SizedBox(height: 10),
                _summaryCard(context, 'Product', [
                  if (ctx.product.isNotEmpty) _row(context, 'Item', ctx.product, Colors.black87),
                  if (ctx.purity.isNotEmpty)  _row(context, 'Purity', ctx.purity, Colors.black87),
                  if (ctx.hsn.isNotEmpty)     _row(context, 'HSN', ctx.hsn, Colors.black54),
                ]),
              ],
              if (ctx.rateStr != '0.00') ...[
                const SizedBox(height: 10),
                _summaryCard(context, 'Pricing', [
                  _row(context, 'Rate/g', '₹${ctx.rateStr}', Colors.black87),
                  _row(context, 'Making', '₹${ctx.makingStr}', Colors.black87),
                  _row(context, 'TOTAL', '₹${ctx.amountStr}',
                      Theme.of(context).colorScheme.primary),
                ]),
              ],
              const SizedBox(height: 10),
              _summaryCard(context, 'Label Info', [
                _row(context, 'Serial', ctx.serial, Colors.black87),
                _row(context, 'Date', ctx.dateStr, Colors.black54),
                _row(context, 'Time', ctx.timeStr, Colors.black54),
              ]),
            ]),
          )),

          // ── Confirm buttons ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                child: const Text('Cancel'),
              )),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: FilledButton.icon(
                onPressed: onPrint,
                icon: const Icon(Icons.print),
                label: const Text('Confirm & Print',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
              )),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _summaryCard(BuildContext context, String title, List<Widget> rows) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 11, color: Colors.grey.shade600,
            letterSpacing: 1.5, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        ...rows,
      ]),
    ),
  );

  Widget _row(BuildContext context, String label, String value, Color valueColor) =>
      Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(color: Colors.grey))),
        Flexible(child: Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: valueColor),
            overflow: TextOverflow.ellipsis)),
      ]));
}

// =============================================================================
class _ProductPicker extends StatefulWidget {
  final List<Map<String, dynamic>> products;
  final void Function(Map<String, dynamic>) onSelect;
  const _ProductPicker({required this.products, required this.onSelect});
  @override State<_ProductPicker> createState() => _ProductPickerState();
}
class _ProductPickerState extends State<_ProductPicker> {
  String _q = '';
  List<Map<String, dynamic>> get _filtered => _q.isEmpty
      ? widget.products
      : widget.products.where((p) =>
          (p['name'] as String? ?? '').toLowerCase().contains(_q.toLowerCase()) ||
          (p['code'] as String? ?? '').toLowerCase().contains(_q.toLowerCase())).toList();

  @override Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        const Text('Select Product',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Padding(
          padding: const EdgeInsets.all(12),
          child: SearchBar(
            hintText: 'Search name or SKU…', leading: const Icon(Icons.search),
            onChanged: (s) => setState(() => _q = s),
          ),
        ),
        SizedBox(
          height: 320,
          child: _filtered.isEmpty
              ? const Center(child: Text('No products found'))
              : ListView.builder(
                  itemCount: _filtered.length,
                  itemBuilder: (_, i) {
                    final p = _filtered[i];
                    return ListTile(
                      title: Text(p['name'] as String? ?? ''),
                      subtitle: Text('${p['purity'] ?? ''}  •  '
                          '₹${(p['rate'] as num? ?? 0).toStringAsFixed(0)}/g'),
                      trailing: Text(p['code'] as String? ?? ''),
                      onTap: () { widget.onSelect(p); Navigator.pop(context); },
                    );
                  }),
        ),
      ]),
    );
  }
}