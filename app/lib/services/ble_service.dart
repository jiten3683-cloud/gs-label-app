import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class BleService extends ChangeNotifier {
  static const String _defaultDeviceName = 'GS-LABEL-BRIDGE';
  static final Guid _svc      = Guid('6f0a0001-7b9a-4e9f-9b46-1d7b3a2c0001');
  static final Guid _chWeight = Guid('6f0a0002-7b9a-4e9f-9b46-1d7b3a2c0001');
  static final Guid _chCmd    = Guid('6f0a0003-7b9a-4e9f-9b46-1d7b3a2c0001');
  static final Guid _chStatus = Guid('6f0a0004-7b9a-4e9f-9b46-1d7b3a2c0001');

  String deviceName = _defaultDeviceName;

  BluetoothDevice?         _device;
  BluetoothCharacteristic? _weight;
  BluetoothCharacteristic? _command;
  BluetoothCharacteristic? _status;

  StreamSubscription<List<int>>?             _weightSub;
  StreamSubscription<List<int>>?             _statusSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer?                                     _reconnectTimer;

  bool   isScanning  = false;
  bool   isConnected = false;
  bool   isReconnecting = false;
  String lastStatus  = '';

  List<ScanResult> nearbyDevices = [];

  double grossG = 0.0;
  double tareG  = 0.0;
  double netG   = 0.0;
  bool   stable = false;
  DateTime? lastSeen;

  BleService() {
    // Auto-connect when Bluetooth adapter turns on (e.g. user enables BT after opening app)
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on &&
          !isConnected && !isScanning && !isReconnecting) {
        Future.delayed(const Duration(seconds: 2), () {
          if (!isConnected && !isScanning && !isReconnecting) {
            scanAndConnect();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _adapterSub?.cancel();
    super.dispose();
  }

  Future<void> requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> startGeneralScan(
      {Duration timeout = const Duration(seconds: 8)}) async {
    await requestPermissions();
    if (!(await FlutterBluePlus.isSupported)) return;
    nearbyDevices = [];
    isScanning = true;
    notifyListeners();

    final sub = FlutterBluePlus.scanResults.listen((results) {
      bool changed = false;
      for (final r in results) {
        final id = r.device.remoteId.str;
        if (!nearbyDevices.any((d) => d.device.remoteId.str == id)) {
          nearbyDevices.add(r);
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });

    await FlutterBluePlus.startScan(timeout: timeout);
    await Future<void>.delayed(timeout);
    await sub.cancel();
    await FlutterBluePlus.stopScan();

    isScanning = false;
    notifyListeners();
  }

  Future<void> scanAndConnect(
      {Duration timeout = const Duration(seconds: 10)}) async {
    await requestPermissions();
    if (!(await FlutterBluePlus.isSupported)) return;

    isScanning = true;
    notifyListeners();
    final completer = Completer<BluetoothDevice?>();
    late StreamSubscription sub;
    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName == deviceName) {
          if (!completer.isCompleted) completer.complete(r.device);
        }
      }
    });
    await FlutterBluePlus.startScan(timeout: timeout, withNames: [deviceName]);
    final found =
        await completer.future.timeout(timeout, onTimeout: () => null);
    await sub.cancel();
    await FlutterBluePlus.stopScan();
    isScanning = false;

    if (found == null) {
      lastStatus = 'Device not found';
      notifyListeners();
      return;
    }
    await _connectTo(found);
  }

  Future<void> connectToDevice(BluetoothDevice d) => _connectTo(d);

  Future<void> _connectTo(BluetoothDevice d) async {
    _reconnectTimer?.cancel();
    _device = d;
    await d.connect(autoConnect: false, timeout: const Duration(seconds: 8));
    await d.requestMtu(247);

    _connSub?.cancel();
    _connSub = d.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && isConnected) {
        isConnected = false;
        lastStatus  = 'Disconnected – reconnecting…';
        notifyListeners();
        _scheduleReconnect();
      }
    });

    final services = await d.discoverServices();
    for (final svc in services) {
      if (svc.uuid != _svc) continue;
      for (final c in svc.characteristics) {
        if (c.uuid == _chWeight) _weight  = c;
        if (c.uuid == _chCmd)    _command = c;
        if (c.uuid == _chStatus) _status  = c;
      }
    }
    if (_weight != null) {
      await _weight!.setNotifyValue(true);
      _weightSub?.cancel();
      _weightSub = _weight!.lastValueStream.listen(_onWeight);
    }
    if (_status != null) {
      await _status!.setNotifyValue(true);
      _statusSub?.cancel();
      _statusSub = _status!.lastValueStream.listen(_onStatus);
    }
    isConnected   = true;
    isReconnecting = false;
    lastStatus    = 'Connected to ${d.platformName.isNotEmpty ? d.platformName : d.remoteId.str}';
    notifyListeners();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    isReconnecting = true;
    notifyListeners();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      if (isConnected) { _reconnectTimer?.cancel(); isReconnecting = false; return; }
      if (_device == null) { _reconnectTimer?.cancel(); isReconnecting = false; return; }
      try {
        await _connectTo(_device!);
        _reconnectTimer?.cancel();
      } catch (_) {}
    });
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _connSub?.cancel();
    await _weightSub?.cancel();
    await _statusSub?.cancel();
    await _device?.disconnect();
    _device       = null;
    isConnected   = false;
    isReconnecting = false;
    lastStatus    = '';
    notifyListeners();
  }

  void _onWeight(List<int> data) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      grossG  = (json['g'] as num).toDouble();
      tareG   = (json['t'] as num).toDouble();
      netG    = (json['n'] as num).toDouble();
      stable  = (json['s'] as num) == 1;
      lastSeen = DateTime.now();
      notifyListeners();
    } catch (_) {}
  }

  void _onStatus(List<int> data) {
    try {
      final j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      lastStatus = '${j['status']}: ${j['msg']}';
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _send(Map<String, dynamic> payload) async {
    if (_command == null) throw Exception('Not connected');
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    // flutter_blue_plus throws PlatformException if a single write > 244 bytes.
    // Manually chunk into 200-byte pieces; ESP32 bleBuffer reassembles them.
    const chunkSize = 200;
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final chunk = bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length));
      await _command!.write(chunk, withoutResponse: false);
      if (i + chunkSize < bytes.length) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  Future<void> tare()  => _send({'cmd': 'tare'});
  Future<void> zero()  => _send({'cmd': 'zero'});
  Future<void> feed([int mm = 5]) => _send({'cmd': 'feed', 'mm': mm});

  Future<bool> sendPrintJob(Map<String, dynamic> job) async {
    if (!isConnected || _command == null) return false;
    await _send(job);
    return true;
  }
}