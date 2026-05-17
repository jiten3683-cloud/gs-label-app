import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';
import '../services/db_service.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  bool _flushing = false;

  Future<void> _flushQueue() async {
    final db  = context.read<DbService>();
    final ble = context.read<BleService>();
    if (!ble.isConnected) return;
    final pending = await db.getPendingQueue();
    if (pending.isEmpty) return;
    setState(() => _flushing = true);
    int sent = 0;
    for (final row in pending) {
      try {
        final job = jsonDecode(row['job_json'] as String) as Map<String, dynamic>;
        if (await ble.sendPrintJob(job)) {
          await db.dequeueprint(row['id'] as int);
          sent++;
        }
      } catch (_) {}
    }
    setState(() => _flushing = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Flushed $sent queued job(s)')));
    }
  }

  Future<void> _sendOrientationTest(
      BuildContext context, BleService ble, DbService db) async {
    final dirStr = await db.getSetting('print_direction', def: '0');
    final dir    = int.tryParse(dirStr) ?? 0;
    await ble.sendPrintJob({'cmd': 'test_print', 'dir': dir});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Orientation test sent (DIRECTION $dir)'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _quickConnect() async {
    final ble = context.read<BleService>();
    await ble.scanAndConnect();
    if (ble.isConnected) await _flushQueue();
  }

  Future<void> _connectDevice(BluetoothDevice d) async {
    final ble = context.read<BleService>();
    await ble.connectToDevice(d);
    if (ble.isConnected) await _flushQueue();
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    final db  = context.read<DbService>();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Status card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Row(children: [
                Icon(
                  ble.isConnected      ? Icons.bluetooth_connected
                  : ble.isReconnecting ? Icons.bluetooth_searching
                  : Icons.bluetooth_disabled,
                  color: ble.isConnected      ? Colors.green
                       : ble.isReconnecting   ? Colors.orange
                       : Colors.red,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                    ble.isConnected      ? 'Connected'
                    : ble.isReconnecting ? 'Reconnecting…'
                    : 'Disconnected',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold,
                        color: ble.isConnected      ? Colors.green
                             : ble.isReconnecting   ? Colors.orange
                             : Colors.red),
                  ),
                  if (ble.lastStatus.isNotEmpty)
                    Text(ble.lastStatus,
                        style: const TextStyle(fontSize: 12)),
                ])),
              ]),
              if (ble.lastSeen != null) ...[
                const SizedBox(height: 8),
                Text('Last weight: ${ble.lastSeen}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 12),

        if (ble.isConnected) ...[
          // Offline queue flush
          FutureBuilder<int>(
            future: db.queueCount(),
            builder: (_, snap) {
              final count = snap.data ?? 0;
              if (count == 0) return const SizedBox.shrink();
              return Card(
                color: Colors.orange.shade50,
                child: ListTile(
                  leading: const Icon(Icons.queue, color: Colors.orange),
                  title: Text('$count offline job(s) queued'),
                  subtitle: const Text('Tap to send now'),
                  trailing: _flushing
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : FilledButton(
                          onPressed: _flushQueue,
                          child: const Text('Send')),
                  onTap: _flushing ? null : _flushQueue,
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: () => ble.tare(),
              icon: const Icon(Icons.exposure_zero),
              label: const Text('Scale Tare'),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: () => ble.feed(5),
              icon: const Icon(Icons.print),
              label: const Text('Feed 5 mm'),
            )),
          ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _sendOrientationTest(context, ble, db),
            icon: const Icon(Icons.rotate_90_degrees_ccw),
            label: const Text('Print Orientation Test Label'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: ble.disconnect,
            icon: const Icon(Icons.bluetooth_disabled),
            label: const Text('Disconnect'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
          ),
        ] else ...[
          if (ble.isScanning)
            const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Scanning…'),
              ]),
            ))
          else ...[
            FilledButton.icon(
              onPressed: _quickConnect,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Quick Connect  (auto-find bridge)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => context.read<BleService>().startGeneralScan(),
              icon: const Icon(Icons.search),
              label: const Text('Scan All Nearby Devices'),
            ),
          ],
        ],

        if (ble.nearbyDevices.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Devices found:',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...ble.nearbyDevices.map((r) => _DeviceTile(
            result:   r,
            isBridge: r.device.platformName == ble.deviceName,
            onConnect: () => _connectDevice(r.device),
          )),
        ],

        const SizedBox(height: 16),
        const Card(child: Padding(
          padding: EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text('Setup tips',
                style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 6),
            Text('1. Power on the ESP32 bridge first.'),
            Text('2. Grant Bluetooth permissions if prompted.'),
            Text('3. Use Quick Connect to auto-find the bridge.'),
            Text('4. Offline prints queue automatically '
                 'and send when reconnected.'),
          ]),
        )),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _DeviceTile extends StatelessWidget {
  final ScanResult result;
  final bool isBridge;
  final VoidCallback onConnect;
  const _DeviceTile(
      {required this.result, required this.isBridge, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    final d    = result.device;
    final name = d.platformName.isNotEmpty ? d.platformName : 'Unknown';
    return Card(
      color: isBridge ? Theme.of(context).colorScheme.primaryContainer : null,
      child: ListTile(
        leading: Icon(Icons.bluetooth,
            color: isBridge ? Theme.of(context).colorScheme.primary : null),
        title: Text(name),
        subtitle: Text(
            '${d.remoteId.str}  •  RSSI ${result.rssi} dBm'),
        trailing: FilledButton(
            onPressed: onConnect, child: const Text('Connect')),
      ),
    );
  }
}