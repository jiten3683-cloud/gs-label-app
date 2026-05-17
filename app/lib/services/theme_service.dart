import 'package:flutter/material.dart';
import 'db_service.dart';

class ThemeService extends ChangeNotifier {
  Color     primaryColor = const Color(0xFFB8860B); // dark goldenrod
  ThemeMode mode         = ThemeMode.light;

  static const presets = <Color>[
    Color(0xFFB8860B), // Gold (default)
    Color(0xFFFFAB00), // Amber
    Color(0xFF4CAF50), // Green
    Color(0xFF2196F3), // Blue
    Color(0xFF9C27B0), // Purple
    Color(0xFFF44336), // Red
    Color(0xFF009688), // Teal
    Color(0xFF795548), // Brown
  ];

  Future<void> load(DbService db) async {
    final cv = await db.getSetting('theme_color', def: '');
    final mv = await db.getSetting('theme_mode',  def: '0');
    if (cv.isNotEmpty) {
      final iv = int.tryParse(cv);
      if (iv != null) primaryColor = Color(iv);
    }
    final mi = int.tryParse(mv) ?? 0;
    mode = ThemeMode.values[mi.clamp(0, ThemeMode.values.length - 1)];
    notifyListeners();
  }

  Future<void> setColor(Color c, DbService db) async {
    primaryColor = c;
    notifyListeners();
    await db.setSetting('theme_color', '${c.value}');
  }

  Future<void> setMode(ThemeMode m, DbService db) async {
    mode = m;
    notifyListeners();
    await db.setSetting('theme_mode', '${m.index}');
  }
}
