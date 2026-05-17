import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';
import '../services/license_service.dart';
import 'login_page.dart';
import 'scale_page.dart';
import 'label_studio_page.dart';
import 'reports_page.dart';
import 'connect_page.dart';
import 'settings_page.dart';

class HomeShell extends StatefulWidget {
  final LicenseService license;
  const HomeShell({super.key, required this.license});
  @override State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _idx = 0;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _recheckIfIdle();
    }
  }

  Future<void> _recheckIfIdle() async {
    if (_pausedAt == null) return;
    final idle = DateTime.now().difference(_pausedAt!);
    _pausedAt = null;
    if (idle.inMinutes < 60) return;

    final err = await widget.license.verifyOnline();
    if (!mounted) return;

    // Network error during recheck — skip silently (user is mid-work)
    if (err != null && err.startsWith(LicenseService.networkErrorPrefix)) return;

    // License rejected — deactivate and go back to login
    if (err != null) {
      await widget.license.deactivate();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => LoginPage(license: widget.license)),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();

    Color statusColor() {
      if (ble.isConnected)    return Colors.green;
      if (ble.isReconnecting) return Colors.orange;
      return Colors.red;
    }

    String statusLabel() {
      if (ble.isConnected)    return 'Linked';
      if (ble.isReconnecting) return 'Sync…';
      return 'Offline';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('JBC-GS-PRINTER'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(children: [
              Icon(Icons.circle, size: 10, color: statusColor()),
              const SizedBox(width: 4),
              Text(statusLabel(), style: const TextStyle(fontSize: 12)),
            ]),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      // IndexedStack keeps all tabs alive — state is preserved on tab switch.
      body: IndexedStack(
        index: _idx,
        children: const [
          ScalePage(),        // 0 — Scale / Print
          LabelStudioPage(),  // 1 — WYSIWYG Label Studio (designer + templates merged)
          ReportsPage(),      // 2 — Print history
          ConnectPage(),      // 3 — BLE device
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.scale),              label: 'Scale'),
          NavigationDestination(icon: Icon(Icons.auto_awesome),       label: 'Studio'),
          NavigationDestination(icon: Icon(Icons.assessment_outlined), label: 'Reports'),
          NavigationDestination(icon: Icon(Icons.bluetooth),          label: 'Device'),
        ],
      ),
    );
  }
}
