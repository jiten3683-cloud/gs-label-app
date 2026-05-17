import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/db_service.dart';
import '../models/label_element.dart';

// TSPL font heights in dots (203 DPI ≈ 8 dots/mm)
const _fontDotH = {
  '1': 12, '2': 20, '3': 24, '4': 32, '5': 48,
  '6': 19, '7': 27, '8': 21,
};

class DesignerPage extends StatefulWidget {
  final Map<String, dynamic>? initialTemplate;
  final VoidCallback? onBack;
  const DesignerPage({super.key, this.initialTemplate, this.onBack});

  @override
  State<DesignerPage> createState() => _DesignerPageState();
}

class _DesignerPageState extends State<DesignerPage> {
  int    _wMm = 50;
  int    _hMm = 25;
  int    _gap = 3;
  final  _nameCtrl = TextEditingController(text: 'New Template');
  final  List<LabelElement> _elements = [];
  LabelElement? _selected;
  int?   _editingId;

  final _transformCtrl   = TransformationController();
  double _pinchScaleRef  = 1.0;

  @override
  void initState() {
    super.initState();
    if (widget.initialTemplate != null) _applyTemplate(widget.initialTemplate!);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  void _applyTemplate(Map<String, dynamic> tmpl) {
    _nameCtrl.text = tmpl['name']      as String? ?? 'Template';
    _wMm           = tmpl['width_mm']  as int?    ?? 50;
    _hMm           = tmpl['height_mm'] as int?    ?? 25;
    _gap           = tmpl['gap_mm']    as int?    ?? 3;
    _editingId     = tmpl['id']        as int?;
    _elements.clear();
    _selected = null;
    final raw  = tmpl['json'];
    final list = raw is String ? jsonDecode(raw) : raw;
    if (list is List) {
      for (final m in list) {
        _elements.add(_fromMap(m as Map<String, dynamic>));
      }
    }
    setState(() {});
  }

  LabelElement _fromMap(Map<String, dynamic> m) {
    final t = ElType.values.firstWhere(
      (e) => e.name == (m['t'] as String? ?? 'text'),
      orElse: () => ElType.text,
    );
    return LabelElement(
      type: t,
      x: m['x'] as int? ?? 10, y: m['y'] as int? ?? 10,
      text: m['text'] as String? ?? '', font: m['font'] as String? ?? '3',
      xScale: m['xs'] as int? ?? 1, yScale: m['ys'] as int? ?? 1,
      rotation: m['rot'] as int? ?? 0,
      data: m['data'] as String? ?? '',
      barcodeType: m['btype'] as String? ?? '128',
      barcodeHeight: m['bh'] as int? ?? 60,
      qrEcc: m['ecc'] as String? ?? 'M', qrSize: m['qs'] as int? ?? 4,
      xEnd: m['xe'] as int? ?? 100, yEnd: m['ye'] as int? ?? 100,
      thickness: m['th'] as int? ?? 2,
      logoName: m['logo'] as String? ?? 'LOGO.BMP',
      prefix: m['pre'] as String? ?? '', suffix: m['suf'] as String? ?? '',
      decimals: m['dec'] as int? ?? 3, unit: m['unit'] as String? ?? 'g',
    );
  }

  void _add(ElType t) {
    final el = LabelElement(type: t, x: 16, y: 16);
    if (t == ElType.weight)   { el.prefix = 'Net: '; el.suffix = ' g'; }
    if (t == ElType.serial)   { el.prefix = 'SN: '; }
    if (t == ElType.qr)       { el.data = '{serial}|{net}'; }
    if (t == ElType.bar)      { el.data = '{serial}'; }
    if (t == ElType.text)     { el.text = 'Pure Gold'; }
    setState(() { _elements.add(el); _selected = el; });
  }

  Future<void> _save() async {
    final db = context.read<DbService>();
    final id = await db.saveTemplate(
      id: _editingId, name: _nameCtrl.text.trim().isEmpty ? 'Template' : _nameCtrl.text.trim(),
      wMm: _wMm, hMm: _hMm, gapMm: _gap,
      json: _elements.map(_toMap).toList(),
      // preserve existing lines when saving from designer
    );
    _editingId = id;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved "${_nameCtrl.text}"')));
    }
  }

  void _moveUp() {
    if (_selected == null) return;
    final i = _elements.indexOf(_selected!);
    if (i < _elements.length - 1) {
      setState(() { _elements.removeAt(i); _elements.insert(i + 1, _selected!); });
    }
  }

  void _moveDown() {
    if (_selected == null) return;
    final i = _elements.indexOf(_selected!);
    if (i > 0) {
      setState(() { _elements.removeAt(i); _elements.insert(i - 1, _selected!); });
    }
  }

  void _zoomIn() {
    final next = (_transformCtrl.value.getMaxScaleOnAxis() * 1.3).clamp(0.3, 5.0);
    _transformCtrl.value = Matrix4.diagonal3Values(next, next, 1.0);
  }

  void _zoomOut() {
    final next = (_transformCtrl.value.getMaxScaleOnAxis() / 1.3).clamp(0.3, 5.0);
    _transformCtrl.value = Matrix4.diagonal3Values(next, next, 1.0);
  }

  void _zoomReset() => _transformCtrl.value = Matrix4.identity();

  void _resizeEl(LabelElement el, double delta) {
    switch (el.type) {
      case ElType.text:
      case ElType.weight:
      case ElType.serial:
      case ElType.dateTime:
        final ny = (el.yScale * delta).round().clamp(1, 10);
        el.yScale = ny; el.xScale = ny;
        break;
      case ElType.qr:
        el.qrSize = (el.qrSize * delta).round().clamp(1, 10);
        break;
      case ElType.bar:
        el.barcodeHeight = (el.barcodeHeight * delta).round().clamp(10, 400);
        break;
      case ElType.box:
        final w = ((el.xEnd - el.x) * delta).round();
        final h = ((el.yEnd - el.y) * delta).round();
        el.xEnd = (el.x + w).clamp(el.x + 8, _wMm * 8);
        el.yEnd = (el.y + h).clamp(el.y + 8, _hMm * 8);
        break;
      case ElType.logo:
        break;
    }
  }

  Map<String, dynamic> _toMap(LabelElement el) => {
    't': el.type.name, 'x': el.x, 'y': el.y,
    'text': el.text, 'font': el.font,
    'xs': el.xScale, 'ys': el.yScale, 'rot': el.rotation,
    'data': el.data, 'btype': el.barcodeType, 'bh': el.barcodeHeight,
    'ecc': el.qrEcc, 'qs': el.qrSize,
    'xe': el.xEnd, 'ye': el.yEnd, 'th': el.thickness,
    'logo': el.logoName,
    'pre': el.prefix, 'suf': el.suffix,
    'dec': el.decimals, 'unit': el.unit,
  };

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // ── Header ────────────────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Row 1: back + name + Save (always visible)
          Row(children: [
            if (widget.onBack != null) ...[
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back to Templates',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                onPressed: widget.onBack,
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Template name', isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('Save'),
            ),
          ]),
          const SizedBox(height: 6),
          // Row 2: label dimensions (scrollable)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              const Text('W:', style: TextStyle(fontSize: 13)),
              _LiveNumField(value: _wMm, hint: 'mm', min: 10, max: 200,
                  onChanged: (v) => setState(() => _wMm = v)),
              const SizedBox(width: 4),
              const Text('H:', style: TextStyle(fontSize: 13)),
              _LiveNumField(value: _hMm, hint: 'mm', min: 5, max: 200,
                  onChanged: (v) => setState(() => _hMm = v)),
              const SizedBox(width: 4),
              const Text('Gap:', style: TextStyle(fontSize: 13)),
              _LiveNumField(value: _gap, hint: 'mm', min: 0, max: 20,
                  onChanged: (v) => setState(() => _gap = v)),
              const SizedBox(width: 12),
              Text('$_wMm × $_hMm mm',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
          ),
        ]),
      ),
      const Divider(height: 1),
      // ── Zoom toolbar ──────────────────────────────────────────────────────
      Container(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(children: [
          const Text('Zoom:', style: TextStyle(fontSize: 12)),
          _iconBtn(Icons.zoom_in,   'Zoom in',    _zoomIn),
          _iconBtn(Icons.zoom_out,  'Zoom out',   _zoomOut),
          _iconBtn(Icons.fit_screen,'Reset zoom', _zoomReset),
          const Spacer(),
          if (_selected != null)
            Text('Pinch to resize  •  drag to move',
                style: TextStyle(fontSize: 11,
                    color: Theme.of(context).colorScheme.primary)),
        ]),
      ),
      // ── Canvas ────────────────────────────────────────────────────────────
      Expanded(
        child: LayoutBuilder(builder: (ctx, constraints) {
          final availW  = constraints.maxWidth - 32.0;
          final scale   = (availW / (_wMm * 8.0)).clamp(0.2, 2.5);
          final canvasW = _wMm * 8.0 * scale;
          final canvasH = _hMm * 8.0 * scale;

          return InteractiveViewer(
            transformationController: _transformCtrl,
            minScale: 0.3, maxScale: 5.0,
            boundaryMargin: const EdgeInsets.all(80),
            scaleEnabled: _selected == null,
            child: Center(
              child: Container(
                margin: const EdgeInsets.all(16),
                width: canvasW, height: canvasH,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.black54),
                  boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
                ),
                child: Stack(children: [
                  Positioned.fill(child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => setState(() => _selected = null),
                  )),
                  ..._elements.map((el) => Positioned(
                    left: el.x * scale, top: el.y * scale,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _selected = el),
                      onScaleStart: (_) {
                        _pinchScaleRef = 1.0;
                        setState(() => _selected = el);
                      },
                      onScaleUpdate: (d) {
                        setState(() {
                          if (d.pointerCount >= 2 && d.scale > 0) {
                            final delta = d.scale / _pinchScaleRef;
                            _pinchScaleRef = d.scale;
                            _resizeEl(el, delta);
                          } else {
                            el.x = (el.x + d.focalPointDelta.dx / scale)
                                .round().clamp(0, _wMm * 8);
                            el.y = (el.y + d.focalPointDelta.dy / scale)
                                .round().clamp(0, _hMm * 8);
                          }
                        });
                      },
                      child: _ElementPreview(
                          el: el, selected: el == _selected, scale: scale),
                    ),
                  )),
                ]),
              ),
            ),
          );
        }),
      ),
      // ── Toolbox ───────────────────────────────────────────────────────────
      _Toolbox(onAdd: _add),
      // ── Inspector ─────────────────────────────────────────────────────────
      if (_selected != null)
        _Inspector(
          el: _selected!,
          onChange: () => setState(() {}),
          onDelete: () => setState(() { _elements.remove(_selected); _selected = null; }),
          onMoveUp: _moveUp, onMoveDown: _moveDown,
        ),
    ]);
  }

  Widget _iconBtn(IconData ic, String tip, VoidCallback fn) => IconButton(
    icon: Icon(ic, size: 20), tooltip: tip, onPressed: fn,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
  );
}

// =============================================================================
// StatefulWidget number field — controller persists across rebuilds
class _LiveNumField extends StatefulWidget {
  final int value; final String hint; final int min, max;
  final ValueChanged<int> onChanged;
  const _LiveNumField({required this.value, required this.hint,
      this.min = 0, this.max = 9999, required this.onChanged});
  @override State<_LiveNumField> createState() => _LiveNumFieldState();
}
class _LiveNumFieldState extends State<_LiveNumField> {
  late final TextEditingController _c;
  @override void initState() { super.initState(); _c = TextEditingController(text: '${widget.value}'); }
  @override void didUpdateWidget(_LiveNumField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final s = '${widget.value}';
      if (_c.text != s) _c.value = TextEditingValue(
        text: s, selection: TextSelection.collapsed(offset: s.length));
    }
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => SizedBox(width: 56, child: TextField(
    controller: _c, keyboardType: TextInputType.number,
    decoration: InputDecoration(hintText: widget.hint, isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
    onChanged: (s) { final v = int.tryParse(s); if (v != null) widget.onChanged(v.clamp(widget.min, widget.max)); },
  ));
}

// Inspector number field — same pattern
class _InspNumField extends StatefulWidget {
  final String label; final int value; final int min, max;
  final ValueChanged<int> onChanged;
  const _InspNumField({required this.label, required this.value,
      this.min = 0, this.max = 9999, required this.onChanged});
  @override State<_InspNumField> createState() => _InspNumFieldState();
}
class _InspNumFieldState extends State<_InspNumField> {
  late final TextEditingController _c;
  @override void initState() { super.initState(); _c = TextEditingController(text: '${widget.value}'); }
  @override void didUpdateWidget(_InspNumField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final s = '${widget.value}';
      if (_c.text != s) _c.value = TextEditingValue(
        text: s, selection: TextSelection.collapsed(offset: s.length));
    }
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => SizedBox(width: 80, child: TextField(
    controller: _c, keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: widget.label, isDense: true),
    onChanged: (s) { final v = int.tryParse(s); if (v != null) widget.onChanged(v.clamp(widget.min, widget.max)); },
  ));
}

// Inspector text field — StatefulWidget controller
class _InspTextField extends StatefulWidget {
  final String label; final String value; final double width;
  final ValueChanged<String> onChanged;
  const _InspTextField({required this.label, required this.value,
      this.width = 150, required this.onChanged});
  @override State<_InspTextField> createState() => _InspTextFieldState();
}
class _InspTextFieldState extends State<_InspTextField> {
  late final TextEditingController _c;
  @override void initState() { super.initState(); _c = TextEditingController(text: widget.value); }
  @override void didUpdateWidget(_InspTextField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _c.text != widget.value) {
      _c.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length));
    }
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => SizedBox(width: widget.width, child: TextField(
    controller: _c,
    decoration: InputDecoration(labelText: widget.label, isDense: true),
    onChanged: widget.onChanged,
  ));
}

// =============================================================================
class _Toolbox extends StatelessWidget {
  final void Function(ElType) onAdd;
  const _Toolbox({required this.onAdd});
  @override Widget build(BuildContext context) {
    Widget chip(ElType t, IconData ic, String lbl) => Padding(
      padding: const EdgeInsets.all(3),
      child: ActionChip(
          avatar: Icon(ic, size: 16),
          label: Text(lbl, style: const TextStyle(fontSize: 12)),
          onPressed: () => onAdd(t)));
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            chip(ElType.text,     Icons.text_fields,      'Text'),
            chip(ElType.weight,   Icons.scale,            'Weight'),
            chip(ElType.serial,   Icons.confirmation_num, 'Serial'),
            chip(ElType.dateTime, Icons.calendar_today,   'Date/Time'),
            chip(ElType.qr,       Icons.qr_code_2,        'QR'),
            chip(ElType.bar,      Icons.barcode_reader,   'Barcode'),
            chip(ElType.box,      Icons.crop_square,      'Box'),
            chip(ElType.logo,     Icons.image,            'Logo'),
          ])));
  }
}

// =============================================================================
Barcode _barcodeForType(String t) {
  switch (t) {
    case '39':    return Barcode.code39();
    case 'EAN13': return Barcode.ean13();
    case 'EAN8':  return Barcode.ean8();
    case 'UPC':   return Barcode.upcA();
    default:      return Barcode.code128();
  }
}
int _qrEcc(String e) {
  switch (e) {
    case 'L': return QrErrorCorrectLevel.L;
    case 'Q': return QrErrorCorrectLevel.Q;
    case 'H': return QrErrorCorrectLevel.H;
    default:  return QrErrorCorrectLevel.M;
  }
}

class _ElementPreview extends StatelessWidget {
  final LabelElement el; final bool selected; final double scale;
  const _ElementPreview({required this.el, required this.selected, required this.scale});

  @override Widget build(BuildContext context) {
    final border = selected
        ? Border.all(color: Colors.blue, width: 2)
        : Border.all(color: Colors.transparent);
    Widget body;
    switch (el.type) {
      case ElType.text:
      case ElType.weight:
      case ElType.serial:
      case ElType.dateTime:
        final preview = el.type == ElType.text
            ? '${el.prefix}${el.text}${el.suffix}'
            : '${el.prefix}${el.type.name}${el.suffix}';
        final dotH = (_fontDotH[el.font] ?? 24).toDouble();
        final fs   = (dotH * el.yScale * scale).clamp(6.0, 120.0);
        body = Text(preview.isEmpty ? '[${el.type.name}]' : preview,
            style: TextStyle(fontSize: fs, fontWeight: FontWeight.w600, height: 1.1));
        break;
      case ElType.qr:
        final data = el.data.replaceAll(RegExp(r'\{[^}]+\}'), 'X');
        final size = (el.qrSize * 8.0 * scale).clamp(24.0, 200.0);
        body = SizedBox(width: size, height: size, child: QrImageView(
          data: data.isEmpty ? 'QR' : data, version: QrVersions.auto, size: size,
          errorCorrectionLevel: _qrEcc(el.qrEcc),
          errorStateBuilder: (_, __) => Container(color: Colors.black12,
              child: const Center(child: Text('QR', style: TextStyle(fontSize: 10)))),
        ));
        break;
      case ElType.bar:
        final rawData = el.data.replaceAll(RegExp(r'\{[^}]+\}'), '1234');
        final bw = (120.0 * scale).clamp(40.0, 300.0);
        final bh = (el.barcodeHeight * scale).clamp(20.0, 200.0);
        try {
          body = BarcodeWidget(barcode: _barcodeForType(el.barcodeType),
              data: rawData.isEmpty ? '123456' : rawData,
              width: bw, height: bh, drawText: false, color: Colors.black);
        } catch (_) {
          body = Container(width: bw, height: bh, color: Colors.black12,
              child: const Center(child: Text('BAR')));
        }
        break;
      case ElType.box:
        body = Container(
          width:  ((el.xEnd - el.x) * scale).abs().clamp(4.0, 400.0),
          height: ((el.yEnd - el.y) * scale).abs().clamp(4.0, 400.0),
          decoration: BoxDecoration(border: Border.all(width: el.thickness.toDouble())));
        break;
      case ElType.logo:
        body = Container(width: 60, height: 30,
            decoration: BoxDecoration(color: Colors.amber.shade100,
                border: Border.all(color: Colors.amber)),
            alignment: Alignment.center,
            child: const Icon(Icons.image, size: 20));
        break;
    }
    return Container(
        decoration: BoxDecoration(border: border),
        padding: const EdgeInsets.all(1), child: body);
  }
}

// =============================================================================
class _Inspector extends StatelessWidget {
  final LabelElement el;
  final VoidCallback onChange, onDelete, onMoveUp, onMoveDown;
  const _Inspector({required this.el, required this.onChange,
      required this.onDelete, required this.onMoveUp, required this.onMoveDown});

  @override Widget build(BuildContext context) {
    Widget quickSizes() {
      const presets = [
        ('Tiny','1',1,1), ('Sm','2',1,1), ('Md','3',1,1),
        ('Lg','4',1,1), ('XL','3',2,2), ('XXL','4',2,2),
      ];
      return Row(mainAxisSize: MainAxisSize.min, children: presets.map((p) {
        final (lbl, f, xs, ys) = p;
        final active = el.font == f && el.xScale == xs && el.yScale == ys;
        return Padding(padding: const EdgeInsets.only(right: 3),
          child: FilterChip(
            label: Text(lbl, style: const TextStyle(fontSize: 11)), selected: active,
            onSelected: (_) { el.font = f; el.xScale = xs; el.yScale = ys; onChange(); },
            padding: const EdgeInsets.symmetric(horizontal: 2), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ));
      }).toList());
    }

    Widget fontPicker() => DropdownButton<String>(
      value: el.font, isDense: true,
      items: ['1','2','3','4','5','6','7','8']
          .map((f) => DropdownMenuItem(value: f, child: Text('F$f'))).toList(),
      onChanged: (v) { el.font = v ?? '3'; onChange(); },
    );
    Widget scalePickers() => Row(mainAxisSize: MainAxisSize.min, children: [
      _InspNumField(label: 'XS', value: el.xScale, min: 1, max: 10,
          onChanged: (v) { el.xScale = v; onChange(); }),
      const SizedBox(width: 4),
      _InspNumField(label: 'YS', value: el.yScale, min: 1, max: 10,
          onChanged: (v) { el.yScale = v; onChange(); }),
    ]);

    final widgets = <Widget>[
      Text(el.type.name.toUpperCase(),
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
      _InspNumField(label: 'X', value: el.x, onChanged: (v) { el.x = v; onChange(); }),
      _InspNumField(label: 'Y', value: el.y, onChanged: (v) { el.y = v; onChange(); }),
      _InspNumField(label: 'Rot', value: el.rotation, max: 270,
          onChanged: (v) { el.rotation = v; onChange(); }),
    ];

    switch (el.type) {
      case ElType.text:
        widgets.addAll([
          quickSizes(),
          _InspTextField(label: 'Text', value: el.text, width: 180,
              onChanged: (s) { el.text = s; onChange(); }),
          _InspTextField(label: 'Pre', value: el.prefix, width: 80,
              onChanged: (s) { el.prefix = s; onChange(); }),
          _InspTextField(label: 'Suf', value: el.suffix, width: 80,
              onChanged: (s) { el.suffix = s; onChange(); }),
          fontPicker(), scalePickers(),
        ]);
        break;
      case ElType.weight:
        widgets.addAll([
          quickSizes(),
          _InspTextField(label: 'Pre', value: el.prefix, width: 90,
              onChanged: (s) { el.prefix = s; onChange(); }),
          _InspTextField(label: 'Suf', value: el.suffix, width: 60,
              onChanged: (s) { el.suffix = s; onChange(); }),
          _InspNumField(label: 'Dec', value: el.decimals, max: 6,
              onChanged: (v) { el.decimals = v; onChange(); }),
          fontPicker(), scalePickers(),
        ]);
        break;
      case ElType.serial:
        widgets.addAll([
          quickSizes(),
          _InspTextField(label: 'Pre', value: el.prefix, width: 90,
              onChanged: (s) { el.prefix = s; onChange(); }),
          _InspTextField(label: 'Suf', value: el.suffix, width: 60,
              onChanged: (s) { el.suffix = s; onChange(); }),
          fontPicker(), scalePickers(),
        ]);
        break;
      case ElType.dateTime:
        widgets.addAll([quickSizes(), fontPicker(), scalePickers()]);
        break;
      case ElType.qr:
        widgets.addAll([
          _InspTextField(label: 'Data', value: el.data, width: 200,
              onChanged: (s) { el.data = s; onChange(); }),
          DropdownButton<String>(
            value: el.qrEcc, isDense: true,
            items: ['L','M','Q','H']
                .map((e) => DropdownMenuItem(value: e, child: Text('ECC-$e'))).toList(),
            onChanged: (v) { el.qrEcc = v ?? 'M'; onChange(); }),
          _InspNumField(label: 'Sz', value: el.qrSize, min: 1, max: 10,
              onChanged: (v) { el.qrSize = v; onChange(); }),
        ]);
        break;
      case ElType.bar:
        widgets.addAll([
          _InspTextField(label: 'Data', value: el.data, width: 180,
              onChanged: (s) { el.data = s; onChange(); }),
          DropdownButton<String>(
            value: el.barcodeType, isDense: true,
            items: ['128','39','EAN13','EAN8','UPC']
                .map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (v) { el.barcodeType = v ?? '128'; onChange(); }),
          _InspNumField(label: 'H', value: el.barcodeHeight, min: 10, max: 400,
              onChanged: (v) { el.barcodeHeight = v; onChange(); }),
        ]);
        break;
      case ElType.box:
        widgets.addAll([
          _InspNumField(label: 'Xe', value: el.xEnd,
              onChanged: (v) { el.xEnd = v; onChange(); }),
          _InspNumField(label: 'Ye', value: el.yEnd,
              onChanged: (v) { el.yEnd = v; onChange(); }),
          _InspNumField(label: 'Th', value: el.thickness, min: 1, max: 12,
              onChanged: (v) { el.thickness = v; onChange(); }),
        ]);
        break;
      case ElType.logo:
        widgets.add(_InspTextField(label: 'File', value: el.logoName, width: 120,
            onChanged: (s) { el.logoName = s; onChange(); }));
        break;
    }

    widgets.addAll([
      IconButton(icon: const Icon(Icons.arrow_upward, size: 18),
          tooltip: 'Bring forward', onPressed: onMoveUp),
      IconButton(icon: const Icon(Icons.arrow_downward, size: 18),
          tooltip: 'Send back', onPressed: onMoveDown),
      IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 18),
          tooltip: 'Delete', onPressed: onDelete),
    ]);

    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: widgets.map((w) =>
              Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: w))
              .toList(),
        ),
      ),
    );
  }
}