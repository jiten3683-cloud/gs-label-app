import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/db_service.dart';
import '../models/label_element.dart';

/// Drag-and-drop label designer.
/// - Top: canvas (a Stack of draggable elements, sized to label W x H in mm).
/// - Bottom: toolbox + element inspector for the currently-selected element.
///
/// Coordinates on the canvas are stored as printer **dots** (8 dots = 1 mm)
/// so that what you place is what gets printed. The canvas is rendered with
/// a fixed dots-per-pixel scale so a 50x25 mm label fits on the phone screen.
class DesignerPage extends StatefulWidget {
  const DesignerPage({super.key});
  @override
  State<DesignerPage> createState() => _DesignerPageState();
}

class _DesignerPageState extends State<DesignerPage> {
  int    _wMm = 50;
  int    _hMm = 25;
  int    _gap = 3;
  String _name = 'New Template';
  final  List<LabelElement> _elements = [];
  LabelElement? _selected;
  int?   _editingId;

  static const double _scale = 0.4;  // pixels per dot (0.4 px/dot => 1 mm = 3.2 px)

  int get _canvasWpx => (_wMm * 8 * _scale).round();
  int get _canvasHpx => (_hMm * 8 * _scale).round();

  void _add(ElType t) {
    final el = LabelElement(type: t, x: 16, y: 16);
    if (t == ElType.weight)   { el.prefix = 'Net: '; el.suffix = ' g'; }
    if (t == ElType.serial)   { el.prefix = 'SN: '; }
    if (t == ElType.dateTime) { /* default */ }
    if (t == ElType.qr)       { el.data = '{serial}|{net}'; }
    if (t == ElType.bar)      { el.data = '{serial}'; }
    if (t == ElType.text)     { el.text = 'Pure Gold'; }
    setState(() { _elements.add(el); _selected = el; });
  }

  Future<void> _save() async {
    final db = context.read<DbService>();
    final asMaps = _elements.map(_toMap).toList();
    final id = await db.saveTemplate(
      id: _editingId, name: _name, wMm: _wMm, hMm: _hMm, gapMm: _gap,
      json: asMaps,                 // bare list — scale_page decodes the same way
    );
    _editingId = id;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved "$_name" (id=$id)')));
    }
  }

  /// Serialize a LabelElement back to the compact map shape we persist.
  Map<String, dynamic> _toMap(LabelElement el) => {
    't'   : el.type.name,
    'x'   : el.x, 'y': el.y,
    'text': el.text, 'font': el.font,
    'xs'  : el.xScale, 'ys': el.yScale, 'rot': el.rotation,
    'data': el.data, 'btype': el.barcodeType, 'bh': el.barcodeHeight,
    'ecc' : el.qrEcc, 'qs': el.qrSize,
    'xe'  : el.xEnd, 'ye': el.yEnd, 'th': el.thickness,
    'logo': el.logoName,
    'pre' : el.prefix, 'suf': el.suffix,
    'dec' : el.decimals, 'unit': el.unit,
  };

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _Header(name: _name, wMm: _wMm, hMm: _hMm,
        onNameChanged: (s) => setState(() => _name = s),
        onSizeChanged: (w, h) => setState(() { _wMm = w; _hMm = h; }),
        onSave: _save,
      ),
      const Divider(height: 1),
      Expanded(
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              margin: const EdgeInsets.all(16),
              width:  _canvasWpx.toDouble(),
              height: _canvasHpx.toDouble(),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black54),
                boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
              ),
              child: Stack(children: [
                ..._elements.map((el) => Positioned(
                  left: el.x * _scale, top: el.y * _scale,
                  child: GestureDetector(
                    onTap: () => setState(() => _selected = el),
                    onPanUpdate: (d) => setState(() {
                      el.x = (el.x + d.delta.dx / _scale).round().clamp(0, _wMm * 8);
                      el.y = (el.y + d.delta.dy / _scale).round().clamp(0, _hMm * 8);
                    }),
                    child: _ElementPreview(
                      el: el, selected: el == _selected, scale: _scale),
                  ),
                )),
              ]),
            ),
          ),
        ),
      ),
      _Toolbox(onAdd: _add),
      if (_selected != null)
        _Inspector(
          el: _selected!,
          onChange: () => setState(() {}),
          onDelete: () => setState(() {
            _elements.remove(_selected); _selected = null;
          }),
        ),
    ]);
  }
}

// =============================================================================
class _Header extends StatelessWidget {
  final String name; final int wMm, hMm;
  final ValueChanged<String> onNameChanged;
  final void Function(int, int) onSizeChanged;
  final VoidCallback onSave;
  const _Header({required this.name, required this.wMm, required this.hMm,
    required this.onNameChanged, required this.onSizeChanged, required this.onSave});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(children: [
        SizedBox(width: 160, child: TextField(
          controller: TextEditingController(text: name)
            ..selection = TextSelection.collapsed(offset: name.length),
          decoration: const InputDecoration(labelText: 'Template name', isDense: true),
          onChanged: onNameChanged,
        )),
        const SizedBox(width: 12),
        const Text('Size:'),
        const SizedBox(width: 4),
        _NumField(value: wMm, hint: 'W mm', onChanged: (v) => onSizeChanged(v, hMm)),
        const Text('×'),
        _NumField(value: hMm, hint: 'H mm', onChanged: (v) => onSizeChanged(wMm, v)),
        const Spacer(),
        FilledButton.icon(onPressed: onSave,
          icon: const Icon(Icons.save), label: const Text('Save')),
      ]),
    );
  }
}

class _NumField extends StatelessWidget {
  final int value; final String hint; final ValueChanged<int> onChanged;
  const _NumField({required this.value, required this.hint, required this.onChanged});
  @override
  Widget build(BuildContext context) => SizedBox(width: 56, child: TextField(
    controller: TextEditingController(text: '$value'),
    keyboardType: TextInputType.number,
    decoration: InputDecoration(hintText: hint, isDense: true),
    onSubmitted: (s) => onChanged(int.tryParse(s) ?? value),
  ));
}

// =============================================================================
class _Toolbox extends StatelessWidget {
  final void Function(ElType) onAdd;
  const _Toolbox({required this.onAdd});
  @override
  Widget build(BuildContext context) {
    Widget tile(ElType t, IconData ic, String lbl) =>
      Padding(padding: const EdgeInsets.all(4),
        child: ActionChip(avatar: Icon(ic, size: 18), label: Text(lbl),
          onPressed: () => onAdd(t)));
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        tile(ElType.text,     Icons.text_fields,      'Text'),
        tile(ElType.weight,   Icons.scale,            'Weight'),
        tile(ElType.serial,   Icons.confirmation_num, 'Serial'),
        tile(ElType.dateTime, Icons.calendar_today,   'Date/Time'),
        tile(ElType.qr,       Icons.qr_code_2,        'QR'),
        tile(ElType.bar,      Icons.barcode_reader,   'Barcode'),
        tile(ElType.box,      Icons.crop_square,      'Box'),
        tile(ElType.logo,     Icons.image,            'Logo'),
      ])));
  }
}

// =============================================================================
class _ElementPreview extends StatelessWidget {
  final LabelElement el; final bool selected; final double scale;
  const _ElementPreview({required this.el, required this.selected, required this.scale});
  @override
  Widget build(BuildContext context) {
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
            ? el.text
            : '${el.prefix}${el.type.name}${el.suffix}';
        body = Text(preview,
          style: TextStyle(
            fontSize: 8.0 * scale * 8 * el.yScale, // crude TSPL font 3 ≈ 24 dots
            fontWeight: FontWeight.w600));
        break;
      case ElType.qr:
        body = Container(width: el.qrSize * 8.0, height: el.qrSize * 8.0,
          color: Colors.black, child: const Center(child: Text('QR',
            style: TextStyle(color: Colors.white, fontSize: 10))));
        break;
      case ElType.bar:
        body = Container(width: 100, height: el.barcodeHeight * scale,
          color: Colors.black12, alignment: Alignment.center,
          child: const Text('||||||', style: TextStyle(letterSpacing: 1)));
        break;
      case ElType.box:
        body = Container(
          width: (el.xEnd - el.x) * scale, height: (el.yEnd - el.y) * scale,
          decoration: BoxDecoration(border: Border.all(width: el.thickness.toDouble())));
        break;
      case ElType.logo:
        body = Container(width: 60, height: 30, color: Colors.amber.shade100,
          alignment: Alignment.center, child: const Icon(Icons.image, size: 20));
        break;
    }
    return Container(decoration: BoxDecoration(border: border), padding: const EdgeInsets.all(2), child: body);
  }
}

// =============================================================================
class _Inspector extends StatelessWidget {
  final LabelElement el; final VoidCallback onChange; final VoidCallback onDelete;
  const _Inspector({required this.el, required this.onChange, required this.onDelete});
  @override
  Widget build(BuildContext context) {
    Widget num(String lbl, int v, ValueChanged<int> set, {int min = 0, int max = 999}) =>
      SizedBox(width: 100, child: TextField(
        controller: TextEditingController(text: '$v'),
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: lbl, isDense: true),
        onSubmitted: (s) { set((int.tryParse(s) ?? v).clamp(min, max)); onChange(); },
      ));
    Widget txt(String lbl, String v, ValueChanged<String> set, {double w = 160}) =>
      SizedBox(width: w, child: TextField(
        controller: TextEditingController(text: v)
          ..selection = TextSelection.collapsed(offset: v.length),
        decoration: InputDecoration(labelText: lbl, isDense: true),
        onChanged: (s) { set(s); onChange(); },
      ));
    final widgets = <Widget>[
      Text('${el.type.name.toUpperCase()}  @ (${el.x},${el.y})',
        style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(width: 8),
      num('x',  el.x,  (v) => el.x = v),
      num('y',  el.y,  (v) => el.y = v),
      num('rot',el.rotation, (v) => el.rotation = v, max: 270),
    ];
    if (el.type == ElType.text) {
      widgets.addAll([
        txt('Text', el.text, (s) => el.text = s, w: 220),
        DropdownButton<String>(value: el.font,
          items: ['1','2','3','4','5','6','7','8']
            .map((f) => DropdownMenuItem(value: f, child: Text('Font $f'))).toList(),
          onChanged: (v) { el.font = v ?? '3'; onChange(); }),
        num('xs', el.xScale, (v) => el.xScale = v, min: 1, max: 10),
        num('ys', el.yScale, (v) => el.yScale = v, min: 1, max: 10),
      ]);
    } else if (el.type == ElType.qr) {
      widgets.addAll([
        txt('Data (placeholders ok)', el.data, (s) => el.data = s, w: 240),
        DropdownButton<String>(value: el.qrEcc,
          items: ['L','M','Q','H'].map((e) => DropdownMenuItem(value: e, child: Text('ECC $e'))).toList(),
          onChanged: (v) { el.qrEcc = v ?? 'M'; onChange(); }),
        num('size', el.qrSize, (v) => el.qrSize = v, min: 1, max: 10),
      ]);
    } else if (el.type == ElType.bar) {
      widgets.addAll([
        txt('Data', el.data, (s) => el.data = s, w: 220),
        DropdownButton<String>(value: el.barcodeType,
          items: ['128','39','EAN13','EAN8']
            .map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
          onChanged: (v) { el.barcodeType = v ?? '128'; onChange(); }),
        num('height', el.barcodeHeight, (v) => el.barcodeHeight = v, min: 10, max: 400),
      ]);
    } else if (el.type == ElType.weight || el.type == ElType.serial) {
      widgets.addAll([
        txt('Prefix', el.prefix, (s) => el.prefix = s),
        txt('Suffix', el.suffix, (s) => el.suffix = s),
      ]);
    } else if (el.type == ElType.box) {
      widgets.addAll([
        num('xEnd',  el.xEnd, (v) => el.xEnd = v),
        num('yEnd',  el.yEnd, (v) => el.yEnd = v),
        num('thick', el.thickness, (v) => el.thickness = v, min: 1, max: 12),
      ]);
    } else if (el.type == ElType.logo) {
      widgets.add(txt('Stored name', el.logoName, (s) => el.logoName = s));
    }
    widgets.add(IconButton(
      tooltip: 'Delete', onPressed: onDelete,
      icon: const Icon(Icons.delete, color: Colors.red)));
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center,
          children: widgets.map((w) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4), child: w)).toList())),
    );
  }
}
