import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';
import '../services/db_service.dart';
import '../services/theme_service.dart';
import 'products_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _shopNameCtrl     = TextEditingController();
  final _companyNameCtrl  = TextEditingController();
  final _gstCtrl          = TextEditingController();
  final _addressCtrl      = TextEditingController();
  final _phoneCtrl        = TextEditingController();
  final _serialPrefixCtrl = TextEditingController(text: 'GS-');
  final _serialSuffixCtrl = TextEditingController();
  final _serialPadCtrl    = TextEditingController(text: '5');
  final _serialStartCtrl  = TextEditingController(text: '1');
  String _serialResetMode = 'manual';
  final _gapCtrl          = TextEditingController(text: '3');
  final _darknessCtrl     = TextEditingController(text: '8');
  final _topMarginCtrl    = TextEditingController(text: '1');
  final _leftMarginCtrl   = TextEditingController(text: '0');
  final _bleNameCtrl      = TextEditingController(text: 'GS-LABEL-BRIDGE');
  String _defaultUnit     = 'g';
  int    _printDirection  = 0;   // 0 = Normal, 1 = Rotated 180°
  bool   _loading         = true;

  static const _units = ['g', 'mg', 'Tola', 'Carat', 'Kg'];

  @override void initState() { super.initState(); _load(); }

  @override void dispose() {
    _shopNameCtrl.dispose(); _companyNameCtrl.dispose();
    _gstCtrl.dispose(); _addressCtrl.dispose(); _phoneCtrl.dispose();
    _serialPrefixCtrl.dispose(); _serialSuffixCtrl.dispose();
    _serialPadCtrl.dispose(); _serialStartCtrl.dispose();
    _gapCtrl.dispose(); _darknessCtrl.dispose();
    _topMarginCtrl.dispose(); _leftMarginCtrl.dispose();
    _bleNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = context.read<DbService>();
    final s  = await db.getAllSettings();
    _shopNameCtrl.text     = s['shop_name']        ?? '';
    _companyNameCtrl.text  = s['company_name']    ?? '';
    _gstCtrl.text          = s['company_gst']     ?? '';
    _addressCtrl.text      = s['company_address'] ?? '';
    _phoneCtrl.text        = s['company_phone']   ?? '';
    _serialPrefixCtrl.text = s['serial_prefix']    ?? 'GS-';
    _serialSuffixCtrl.text = s['serial_suffix']    ?? '';
    _serialPadCtrl.text    = s['serial_pad']       ?? '5';
    _serialStartCtrl.text  = s['serial_start']     ?? '1';
    _serialResetMode       = s['serial_reset_mode'] ?? 'manual';
    _gapCtrl.text          = s['default_gap']      ?? '3';
    _darknessCtrl.text     = s['default_darkness']     ?? '8';
    _topMarginCtrl.text    = s['print_top_margin_mm']  ?? '1';
    _leftMarginCtrl.text   = s['print_left_margin_mm'] ?? '0';
    _bleNameCtrl.text      = s['ble_device_name']      ?? 'GS-LABEL-BRIDGE';
    _defaultUnit           = s['default_unit']     ?? 'g';
    _printDirection        = int.tryParse(s['print_direction'] ?? '0') ?? 0;
    if (!_units.contains(_defaultUnit)) _defaultUnit = 'g';
    setState(() => _loading = false);
  }

  Future<void> _confirmResetSerial(DbService db) async {
    final start = int.tryParse(_serialStartCtrl.text) ?? 1;
    final prefix = _serialPrefixCtrl.text;
    final suffix = _serialSuffixCtrl.text;
    final pad    = int.tryParse(_serialPadCtrl.text) ?? 5;
    final preview = '$prefix${start.toString().padLeft(pad, '0')}$suffix';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Serial Counter?'),
        content: Text(
          'The counter will restart from $start.\n'
          'Next serial will be: $preview\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('RESET'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await db.resetSerialCounter(start);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Serial counter reset — next will be $preview')));
  }

  Future<void> _save() async {
    final db  = context.read<DbService>();
    final ble = context.read<BleService>();
    final entries = {
      'shop_name':       _shopNameCtrl.text,
      'company_name':    _companyNameCtrl.text,
      'company_gst':     _gstCtrl.text,
      'company_address': _addressCtrl.text,
      'company_phone':   _phoneCtrl.text,
      'serial_prefix':    _serialPrefixCtrl.text,
      'serial_suffix':    _serialSuffixCtrl.text,
      'serial_pad':       _serialPadCtrl.text,
      'serial_start':     _serialStartCtrl.text,
      'serial_reset_mode': _serialResetMode,
      'default_gap':     _gapCtrl.text,
      'default_darkness':    _darknessCtrl.text,
      'print_top_margin_mm':  _topMarginCtrl.text,
      'print_left_margin_mm': _leftMarginCtrl.text,
      'ble_device_name':      _bleNameCtrl.text,
      'default_unit':    _defaultUnit,
      'print_direction': _printDirection.toString(),
    };
    for (final e in entries.entries) await db.setSetting(e.key, e.value);
    ble.deviceName = _bleNameCtrl.text.trim().isNotEmpty
        ? _bleNameCtrl.text.trim() : 'GS-LABEL-BRIDGE';
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved')));
    }
  }

  @override Widget build(BuildContext context) {
    final thSvc = context.watch<ThemeService>();
    final db    = context.read<DbService>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [

              // ── Company Profile ─────────────────────────────────────────────
              _section('Company Profile', [
                _field(_shopNameCtrl,    'Shop / Display Name', Icons.storefront,
                    hint: 'Used in {shop} variable on labels'),
                _field(_companyNameCtrl, 'Company / Legal Name', Icons.store,
                    hint: 'Used in {company} variable'),
                _field(_gstCtrl,         'GST Number',   Icons.receipt_long),
                _field(_addressCtrl,     'Address',      Icons.location_on, maxLines: 2,
                    hint: 'Used in {address} variable'),
                _field(_phoneCtrl,       'Phone',        Icons.phone,
                    type: TextInputType.phone, hint: 'Used in {phone} variable'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 6,
                    children: const [
                      Chip(label: Text('{shop}'),    padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      Chip(label: Text('{company}'), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      Chip(label: Text('{address}'), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      Chip(label: Text('{phone}'),   padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      Chip(label: Text('{gst}'),     padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 16),

              // ── Label & Serial Defaults ─────────────────────────────────────
              _section('Label & Serial Defaults', [
                Row(children: [
                  Expanded(child: _field(_serialPrefixCtrl, 'Serial Prefix',
                      Icons.confirmation_num)),
                  const SizedBox(width: 8),
                  Expanded(child: _field(_serialSuffixCtrl, 'Serial Suffix',
                      Icons.confirmation_num_outlined)),
                  const SizedBox(width: 8),
                  SizedBox(width: 80, child: _field(_serialPadCtrl, 'Digits',
                      Icons.format_list_numbered, type: TextInputType.number)),
                ]),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _defaultUnit,
                  decoration: const InputDecoration(
                      labelText: 'Default Weight Unit',
                      prefixIcon: Icon(Icons.scale),
                      border: OutlineInputBorder()),
                  items: _units.map((u) =>
                      DropdownMenuItem(value: u, child: Text(u))).toList(),
                  onChanged: (v) => setState(() => _defaultUnit = v ?? 'g'),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _field(_gapCtrl, 'Label Gap (mm)',
                      Icons.space_bar, type: TextInputType.number)),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_darknessCtrl, 'Darkness (1-15)',
                      Icons.brightness_6, type: TextInputType.number)),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _field(_topMarginCtrl, 'Top Margin (mm)',
                      Icons.vertical_align_top, type: TextInputType.number,
                      hint: 'Shift content down from top edge')),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_leftMarginCtrl, 'Left Margin (mm)',
                      Icons.border_left, type: TextInputType.number,
                      hint: 'Shift content right from left edge')),
                ]),
                DropdownButtonFormField<int>(
                  value: _printDirection,
                  decoration: const InputDecoration(
                      labelText: 'Print Direction',
                      prefixIcon: Icon(Icons.rotate_90_degrees_ccw),
                      border: OutlineInputBorder(),
                      helperText: 'Use "Rotated 180°" if content prints upside-down'),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Normal (DIRECTION 0)')),
                    DropdownMenuItem(value: 1, child: Text('Rotated 180° (DIRECTION 1)')),
                  ],
                  onChanged: (v) => setState(() => _printDirection = v ?? 0),
                ),
              ]),
              const SizedBox(height: 16),

              // ── Serial Number Management ────────────────────────────────────
              _section('Serial Number Management', [
                Row(children: [
                  Expanded(child: _field(_serialStartCtrl, 'Start Number',
                      Icons.looks_one_outlined, type: TextInputType.number,
                      hint: 'Counter begins at this value after a reset')),
                ]),
                const SizedBox(height: 4),
                // Preview
                Builder(builder: (ctx) {
                  final prefix = _serialPrefixCtrl.text;
                  final suffix = _serialSuffixCtrl.text;
                  final pad    = int.tryParse(_serialPadCtrl.text) ?? 5;
                  final start  = int.tryParse(_serialStartCtrl.text) ?? 1;
                  final preview = '$prefix${start.toString().padLeft(pad, '0')}$suffix';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(children: [
                      const Icon(Icons.confirmation_num_outlined, size: 16, color: Colors.grey),
                      const SizedBox(width: 6),
                      Text('Preview: ', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                      Text(preview, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    ]),
                  );
                }),
                DropdownButtonFormField<String>(
                  value: _serialResetMode,
                  decoration: const InputDecoration(
                      labelText: 'Auto-Reset Counter',
                      prefixIcon: Icon(Icons.autorenew),
                      border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'manual',  child: Text('Manual only')),
                    DropdownMenuItem(value: 'daily',   child: Text('Daily (at midnight)')),
                    DropdownMenuItem(value: 'monthly', child: Text('Monthly (1st of month)')),
                    DropdownMenuItem(value: 'yearly',  child: Text('Yearly (Jan 1st)')),
                  ],
                  onChanged: (v) => setState(() => _serialResetMode = v ?? 'manual'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _confirmResetSerial(db),
                  icon: const Icon(Icons.restart_alt, color: Colors.red),
                  label: const Text('Reset Serial Counter Now',
                      style: TextStyle(color: Colors.red)),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      minimumSize: const Size.fromHeight(44)),
                ),
              ]),
              const SizedBox(height: 16),

              // ── Appearance / Theme ──────────────────────────────────────────
              _section('Appearance', [
                // Theme mode toggle
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(children: [
                    const Icon(Icons.dark_mode_outlined, size: 20),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('Theme Mode')),
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(value: ThemeMode.light,  icon: Icon(Icons.light_mode, size: 16),  label: Text('Light')),
                        ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto, size: 16), label: Text('Auto')),
                        ButtonSegment(value: ThemeMode.dark,   icon: Icon(Icons.dark_mode, size: 16),   label: Text('Dark')),
                      ],
                      selected: {thSvc.mode},
                      onSelectionChanged: (s) => thSvc.setMode(s.first, db),
                      style: ButtonStyle(
                          visualDensity: VisualDensity.compact),
                    ),
                  ]),
                ),
                // Colour picker
                const Text('App Colour Theme',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 8),
                Wrap(spacing: 10, runSpacing: 10,
                  children: ThemeService.presets.map((c) {
                    final selected = thSvc.primaryColor.value == c.value;
                    return GestureDetector(
                      onTap: () => thSvc.setColor(c, db),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 42, height: 42,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.white : Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: selected
                              ? [BoxShadow(color: c.withOpacity(0.6), blurRadius: 8, spreadRadius: 2)]
                              : [],
                        ),
                        child: selected
                            ? const Icon(Icons.check, color: Colors.white, size: 20)
                            : null,
                      ),
                    );
                  }).toList(),
                ),
              ]),
              const SizedBox(height: 16),

              // ── Bluetooth ───────────────────────────────────────────────────
              _section('Bluetooth', [
                _field(_bleNameCtrl, 'BLE Device Name', Icons.bluetooth),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Must match the name in ESP32 firmware (BLEDevice::init).',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ]),
              const SizedBox(height: 16),

              // ── Product Master ──────────────────────────────────────────────
              Card(child: ListTile(
                leading: const Icon(Icons.inventory_2),
                title: const Text('Product Master'),
                subtitle: const Text('Add / edit products & rates'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ProductsPage())),
              )),
              const SizedBox(height: 24),

              // ── Save ────────────────────────────────────────────────────────
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('Save Settings'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              ),
              const SizedBox(height: 16),

              // ── App Version ─────────────────────────────────────────────────
              Center(
                child: Text(
                  'GS Label Printer  v1.0.2 (build 4)',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ),
              const SizedBox(height: 24),
            ]),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ...children,
      ]),
    ),
  );

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType type = TextInputType.text, int maxLines = 1, String? hint}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: ctrl, keyboardType: type, maxLines: maxLines,
          decoration: InputDecoration(
              labelText: label, prefixIcon: Icon(icon),
              helperText: hint,
              border: const OutlineInputBorder()),
        ),
      );
}