import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ble_service.dart';
import 'db_service.dart';
import '../models/label_element.dart';

/// Keeps the ESP32 in step with the app and records the labels it prints on
/// its own.
///
/// On every connect (and when Settings are saved) the app sends a `sync`:
/// auto-print on/off + minimum weight, the serial counter and the clock. The
/// ESP32 prints labels from the physical button and from auto print using the
/// last template the app sent; each one comes back as a `rec` event and is
/// saved here as a normal print record. App, button and auto prints share one
/// running serial sequence.
class DeviceLink extends ChangeNotifier {
  final DbService  db;
  final BleService ble;

  bool _wasConnected = false;
  late final StreamSubscription<Map<String, dynamic>> _sub;
  Future<void> _chain = Future.value();   // handle events strictly in order

  // Device millis() at the last sync reply, and when that reply arrived —
  // turns a record's device timestamp into wall-clock time, which matters for
  // labels printed while the app was away and delivered on reconnect.
  int?      _syncMs;
  DateTime? _syncAt;

  /// Serial and source ('btn' / 'auto') of the last label the device printed.
  String lastSerial = '';
  String lastSource = '';

  DeviceLink(this.db, this.ble) {
    ble.addListener(_onBle);
    _sub = ble.deviceEvents.listen((j) {
      _chain = _chain.then((_) => _handle(j)).catchError((_) {});
    });
  }

  @override
  void dispose() {
    ble.removeListener(_onBle);
    _sub.cancel();
    super.dispose();
  }

  void _onBle() {
    if (ble.isConnected && !_wasConnected) sync();
    _wasConnected = ble.isConnected;
  }

  /// Push settings, serial counter and clock to the ESP32.
  Future<void> sync() async {
    if (!ble.isConnected) return;
    final s     = await db.getAllSettings();
    final force = s['serial_reset_pending'] == '1';
    final now   = DateTime.now();
    try {
      await ble.sync({
        // Local wall-clock time as epoch seconds — the ESP32 has no time zone.
        'now':   now.millisecondsSinceEpoch ~/ 1000 + now.timeZoneOffset.inSeconds,
        'auto':  s['auto_print'] == '1' ? 1 : 0,
        'min':   double.tryParse(s['auto_min_wt'] ?? '') ?? 0.05,
        'sn':    await db.serialCounter(),
        'force': force ? 1 : 0,
      });
      if (force) await db.setSetting('serial_reset_pending', '0');
    } catch (_) {
      // Not connected any more — the next connect syncs again.
    }
  }

  Future<void> _handle(Map<String, dynamic> j) async {
    if (j['status'] == 'sync') {
      _syncMs = (j['ms'] as num?)?.toInt();
      _syncAt = DateTime.now();
      await db.raiseSerialCounter((j['sn'] as num?)?.toInt() ?? 0);
      notifyListeners();
    } else if (j['status'] == 'rec') {
      await _saveRecord(j);
    }
  }

  DateTime _printedAt(Map<String, dynamic> ev) {
    final ms = (ev['ms'] as num?)?.toInt();
    if (ms == null || _syncMs == null || _syncAt == null) return DateTime.now();
    final t = _syncAt!.add(Duration(milliseconds: ms - _syncMs!));
    return t.isAfter(DateTime.now()) ? DateTime.now() : t;
  }

  Future<void> _saveRecord(Map<String, dynamic> ev) async {
    final serial = ev['v'] as String? ?? '';
    final n      = (ev['n'] as num?)?.toInt() ?? 0;
    if (n > 0) await db.raiseSerialCounter(n);
    // A record can arrive twice if the link dropped mid-delivery.
    if (serial.isNotEmpty && await db.hasPrintSerial(serial)) return;

    // Product, rate, template… come from the last app print, which is the
    // template the ESP32 printed from.
    Map<String, dynamic> base = {};
    try {
      final b = jsonDecode(await db.getSetting('last_print_base', def: '{}'));
      if (b is Map<String, dynamic>) base = b;
    } catch (_) {}

    double d(String k) => (ev[k] as num?)?.toDouble() ?? 0;
    final dec  = (ev['d'] as num?)?.toInt() ?? 3;
    final unit = ev['u'] as String? ?? '';
    String w(double v) => '${v.toStringAsFixed(dec)}${unit.isEmpty ? '' : ' $unit'}';

    // Rebuild the label exactly as the ESP32 filled it (mirrors fillLiveJob in
    // the firmware), so Reports preview/reprint shows what was printed.
    final job = base['job'] is Map
        ? jsonDecode(jsonEncode(base['job'])) as Map<String, dynamic> : null;
    String barcode = '', qr = '';
    if (job != null) {
      final vals = {
        '{net}':    w(d('nt')),
        '{gross}':  w(d('g')),
        '{tare}':   w(d('t')),
        '{metal}':  w(d('m')),
        '{amount}': d('a').toStringAsFixed(2),
        '{making}': d('mk').toStringAsFixed(2),
        '{serial}': serial,
        '{date}':   ev['dt'] as String? ?? '',
        '{time}':   ev['tm'] as String? ?? '',
      };
      for (final e in (job['elements'] as List? ?? const []).whereType<Map>()) {
        final tpl = e['tpl'];
        if (tpl is String && tpl.isNotEmpty) {
          var s = tpl;
          vals.forEach((k, v) => s = s.replaceAll(k, v));
          if (e['qr'] == 1) {
            // QR drawn as a bitmap: redraw it with the printed values.
            e.addAll(qrBitmap(s, e['ecc'] as String? ?? 'M', (e['size'] as num? ?? 4).toInt()));
          } else if (e['type'] == 'qr' || e['type'] == 'bar') { e['data'] = s; } else { e['text'] = s; }
        } else if (e['wt_var'] is String) {
          final g = switch (e['wt_var']) {
            'net' => d('nt'), 'gross' => d('g'), 'tare' => d('t'), 'metal' => d('m'),
            _ => null,
          };
          if (g != null) {
            final u = e['unit'] as String? ?? unit;
            e['text'] = '${e['pre'] ?? ''}${g.toStringAsFixed(dec)}'
                '${u.isEmpty ? '' : ' $u'}${e['suf'] ?? ''}';
          }
        }
        if (e['type'] == 'bar' && barcode.isEmpty) barcode = e['data'] as String? ?? '';
        if ((e['type'] == 'qr' || e['qr'] == 1) && qr.isEmpty) qr = e['data'] as String? ?? '';
      }
      job['sn'] = {...?(job['sn'] as Map?), 'v': serial, 'n': n};
    }

    final src = ev['src'] as String? ?? '';
    final tpl = base['template'] as String? ?? '';
    await db.logPrint({
      'serial': serial,
      'product': base['product'] ?? '', 'purity': base['purity'] ?? '',
      'hsn': base['hsn'] ?? '',
      'gross_g': d('g'), 'tare_g': d('t'), 'net_g': d('nt'), 'stone_g': d('st'),
      'rate': base['rate'] ?? 0, 'making': base['making'] ?? 0, 'amount': d('a'),
      'barcode': barcode, 'qr_data': qr,
      'operator_name': base['operator'] ?? '',
      'printer_name': ble.deviceName,
      'copies': job?['copies'] ?? 1,
      'ts': _printedAt(ev).millisecondsSinceEpoch,
      // Marks where the label came from in Reports.
      'template': '$tpl (${src == 'auto' ? 'Auto' : 'Button'})',
      'job_snapshot': job == null ? '' : jsonEncode(job),
    });

    lastSerial = serial;
    lastSource = src;
    notifyListeners();
  }
}
