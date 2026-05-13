import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// BLE service wrapping flutter_blue_plus to talk to the ESP32 bridge.
/// Mirrors the GATT layout defined in firmware/GoldSilverLabelPrinter.ino.
class BleService extends ChangeNotifier {
  static const String _devName = 'GS-LABEL-BRIDGE';
  static final Guid _svc      = Guid('6f0a0001-7b9a-4e9f-9b46-1d7b3a2c0001');
  static final Guid _chWeight = Guid('6f0a0002-7b9a-4e9f-9b46-1d7b3a2c0001');
  static final Guid _chCmd    = Guid('6f0a0003-7b9a-4e9f-9b46-1d7b3a2c0001');
  static final Guid _chStatus = Guid('6f0a0004-7b9a-4e9f-9b46-1d7b3a2c0001');

  BluetoothDevice?         _device;
  BluetoothCharacteristic? _weight;
  BluetoothCharacteristic? _command;
  BluetoothCharacteristic? _status;

  StreamSubscription<List<int>>? _weightSub;
  StreamSubscription<List<int>>? _statusSub;

  // ----- public state -----
  bool   isScanning  = false;
  bool   isConnected = false;
  String lastStatus  = '';

  /// Latest live reading from the scale.
  double grossG = 0.0;
  double tareG  = 0.0;
  double netG   = 0.0;
  bool   stable = false;
  DateTime? lastSeen;

  Future<void> requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,   // older Android
    ].request();
  }

  Future<void> scanAndConnect({Duration timeout = const Duration(seconds: 10)}) async {
    await requestPermissions();
    if (!(await FlutterBluePlus.isSupported)) return;

    isScanning = true; notifyListeners();
    final completer = Completer<BluetoothDevice?>();
    late StreamSubscription sub;
    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName == _devName) {
          if (!completer.isCompleted) completer.complete(r.device);
        }
      }
    });
    await FlutterBluePlus.startScan(timeout: timeout, withNames: [_devName]);
    final found = await completer.future
        .timeout(timeout, onTimeout: () => null);
    await sub.cancel();
    await FlutterBluePlus.stopScan();
    isScanning = false;

    if (found == null) {
      lastStatus = 'No device found'; notifyListeners(); return;
    }
    await _connectTo(found);
  }

  Future<void> _connectTo(BluetoothDevice d) async {
    _device = d;
    await d.connect(autoConnect: false, timeout: const Duration(seconds: 8));
    await d.requestMtu(247);

    final services = await d.discoverServices();
    final svc = services.firstWhere((s) => s.uuid == _svc);
    for (final c in svc.characteristics) {
      if (c.uuid == _chWeight) _weight  = c;
      if (c.uuid == _chCmd)    _command = c;
      if (c.uuid == _chStatus) _status  = c;
    }
    if (_weight != null) {
      await _weight!.setNotifyValue(true);
      _weightSub = _weight!.lastValueStream.listen(_onWeight);
    }
    if (_status != null) {
      await _status!.setNotifyValue(true);
      _statusSub = _status!.lastValueStream.listen(_onStatus);
    }
    isConnected = true;
    lastStatus  = 'Connected';
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _weightSub?.cancel();
    await _statusSub?.cancel();
    await _device?.disconnect();
    isConnected = false;
    notifyListeners();
  }

  // ---- notifications ----
  void _onWeight(List<int> data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      grossG = (json['g'] as num).toDouble();
      tareG  = (json['t'] as num).toDouble();
      netG   = (json['n'] as num).toDouble();
      stable = (json['s'] as num) == 1;
      lastSeen = DateTime.now();
      notifyListeners();
    } catch (_) {/* malformed packet - ignore */}
  }

  void _onStatus(List<int> data) {
    try {
      final j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      lastStatus = '${j['status']}: ${j['msg']}';
      notifyListeners();
    } catch (_) {}
  }

  // ---- outgoing commands ----
  Future<void> _send(Map<String, dynamic> payload) async {
    if (_command == null) return;
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    // flutter_blue_plus splits writes automatically if > MTU
    await _command!.write(bytes, withoutResponse: false);
  }

  Future<void> tare()  => _send({'cmd': 'tare'});
  Future<void> zero()  => _send({'cmd': 'zero'});
  Future<void> feed([int mm = 5]) => _send({'cmd': 'feed', 'mm': mm});
  Future<void> sendPrintJob(Map<String, dynamic> job) => _send(job);
}
