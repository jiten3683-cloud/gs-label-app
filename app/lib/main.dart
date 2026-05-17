import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/ble_service.dart';
import 'services/db_service.dart';
import 'services/license_service.dart';
import 'services/theme_service.dart';
import 'pages/home_shell.dart';
import 'pages/login_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db      = DbService();
  final theme   = ThemeService();
  final license = LicenseService();

  await Future.wait([
    db.init(),
    license.init(),
  ]);
  await theme.load(db);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleService()),
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
