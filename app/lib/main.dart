import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/ble_service.dart';
import 'services/db_service.dart';
import 'pages/home_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = DbService();
  await db.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleService()),
        Provider<DbService>.value(value: db),
      ],
      child: const GsLabelApp(),
    ),
  );
}

class GsLabelApp extends StatelessWidget {
  const GsLabelApp({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB8860B),       // dark goldenrod
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'GS Label Printer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        appBarTheme: AppBarTheme(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          elevation: 0,
        ),
      ),
      home: const HomeShell(),
    );
  }
}
