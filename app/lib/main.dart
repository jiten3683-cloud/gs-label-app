import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiMode;
import 'package:provider/provider.dart';

import 'services/ble_service.dart';
import 'services/db_service.dart';
import 'services/device_link.dart';
import 'services/license_service.dart';
import 'services/theme_service.dart';
import 'pages/home_shell.dart';
import 'pages/login_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final db      = DbService();
  final theme   = ThemeService();
  final license = LicenseService();

  await Future.wait([
    db.init(),
    license.init(),
  ]);
  await theme.load(db);
  unawaited(db.ensureBuiltinTemplates());
  // Migrate default print direction from 0 → 1 (180°) for existing installs
  final storedDir = await db.getSetting('print_direction', def: '');
  if (storedDir.isEmpty || storedDir == '0') {
    await db.setSetting('print_direction', '1');
  }

  final ble  = BleService();
  final link = DeviceLink(db, ble);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ble),
        ChangeNotifierProvider.value(value: link),
        Provider<DbService>.value(value: db),
        Provider<LicenseService>.value(value: license),
        ChangeNotifierProvider.value(value: theme),
      ],
      child: GsLabelApp(license: license),
    ),
  );
}

class GsLabelApp extends StatelessWidget {
  final LicenseService license;
  const GsLabelApp({super.key, required this.license});

  @override
  Widget build(BuildContext context) {
    final thSvc = context.watch<ThemeService>();

    ThemeData buildTheme(Brightness brightness) {
      final scheme = ColorScheme.fromSeed(
        seedColor: thSvc.primaryColor,
        brightness: brightness,
      );
      return ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        appBarTheme: AppBarTheme(
          backgroundColor: brightness == Brightness.dark
              ? scheme.surfaceContainerHigh
              : scheme.primaryContainer,
          foregroundColor: brightness == Brightness.dark
              ? scheme.onSurface
              : scheme.onPrimaryContainer,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(elevation: 2),
      );
    }

    // Always start at LoginPage — it handles online verify before entering HomeShell
    final Widget home = LoginPage(license: license);

    return MaterialApp(
      title: 'JBC-GS-PRINTER',
      debugShowCheckedModeBanner: false,
      theme:     buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: thSvc.mode,
      home: home,
    );
  }
}
