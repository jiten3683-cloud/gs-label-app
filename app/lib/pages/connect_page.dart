import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';

class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key});
  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Bridge status',
              style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.circle, size: 12,
                color: ble.isConnected ? Colors.green : Colors.red),
              const SizedBox(width: 8),
              Text(ble.isConnected
                ? 'Connected to GS-LABEL-BRIDGE'
                : 'Not connected'),
            ]),
            const SizedBox(height: 8),
            Text('Last status: ${ble.lastStatus.isEmpty ? "-" : ble.lastStatus}'),
            if (ble.lastSeen != null)
              Text('Last reading: ${ble.lastSeen}'),
          ]))),
        const SizedBox(height: 12),
        if (!ble.isConnected)
          FilledButton.icon(
            onPressed: ble.isScanning ? null : ble.scanAndConnect,
            icon: ble.isScanning
              ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.bluetooth_searching),
            label: Text(ble.isScanning ? 'Scanning...' : 'Scan & connect'),
          )
        else
          OutlinedButton.icon(
            onPressed: ble.disconnect,
            icon: const Icon(Icons.bluetooth_disabled),
            label: const Text('Disconnect'),
          ),
        const SizedBox(height: 24),
        const Text('Tips:'),
        const Text('• Make sure the ESP32 bridge is powered on'),
        const Text('• Grant Bluetooth + Location permission when prompted'),
        const Text('• The device advertises as "GS-LABEL-BRIDGE"'),
      ]),
    );
  }
}
