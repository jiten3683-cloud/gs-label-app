import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';
import 'scale_page.dart';
import 'designer_page.dart';
import 'templates_page.dart';
import 'reports_page.dart';
import 'connect_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _idx = 0;

  final _pages = const [
    ScalePage(),
    DesignerPage(),
    TemplatesPage(),
    ReportsPage(),
    ConnectPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gold & Silver Label'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Icon(Icons.circle, size: 10,
                  color: ble.isConnected ? Colors.green : Colors.red),
              const SizedBox(width: 4),
              Text(ble.isConnected ? 'Linked' : 'Offline',
                  style: const TextStyle(fontSize: 12)),
            ]),
          )
        ],
      ),
      body: _pages[_idx],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.scale),         label: 'Scale'),
          NavigationDestination(icon: Icon(Icons.design_services),label: 'Designer'),
          NavigationDestination(icon: Icon(Icons.dashboard),     label: 'Templates'),
          NavigationDestination(icon: Icon(Icons.assessment),    label: 'Reports'),
          NavigationDestination(icon: Icon(Icons.bluetooth),     label: 'Device'),
        ],
      ),
    );
  }
}
