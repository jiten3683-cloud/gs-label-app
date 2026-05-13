import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Local SQLite store. Three tables: templates (label designs),
/// products (item master with HSN, rate, purity), prints (job history).
class DbService {
  late Database _db;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _db = await openDatabase(
      p.join(dir.path, 'gs_label.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE templates (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            name      TEXT NOT NULL,
            width_mm  INTEGER NOT NULL,
            height_mm INTEGER NOT NULL,
            gap_mm    INTEGER NOT NULL DEFAULT 3,
            json      TEXT NOT NULL,
            updated   INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE products (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            code      TEXT UNIQUE,
            name      TEXT,
            purity    TEXT,      -- "22K", "92.5", etc.
            hsn       TEXT,
            rate      REAL,      -- per gram
            making    REAL,      -- making charge %
            template_id INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE prints (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            serial    TEXT NOT NULL,
            product   TEXT,
            purity    TEXT,
            gross_g   REAL,
            tare_g    REAL,
            net_g     REAL,
            rate      REAL,
            amount    REAL,
            ts        INTEGER NOT NULL,
            template  TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_prints_ts ON prints(ts)');
      },
    );
  }

  // ----- templates -----
  /// [json] may be a List (of element maps) or a Map. It will be JSON-encoded.
  Future<int> saveTemplate({
    int? id, required String name,
    required int wMm, required int hMm, int gapMm = 3,
    required Object json,
  }) async {
    final row = {
      'name': name, 'width_mm': wMm, 'height_mm': hMm, 'gap_mm': gapMm,
      'json': jsonEncode(json), 'updated': DateTime.now().millisecondsSinceEpoch,
    };
    if (id == null) return _db.insert('templates', row);
    await _db.update('templates', row, where: 'id=?', whereArgs: [id]);
    return id;
  }

  Future<List<Map<String, dynamic>>> listTemplates() =>
      _db.query('templates', orderBy: 'updated DESC');

  Future<Map<String, dynamic>?> getTemplate(int id) async {
    final r = await _db.query('templates', where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  // ----- prints -----
  Future<int> logPrint(Map<String, dynamic> row) =>
      _db.insert('prints', row);

  Future<List<Map<String, dynamic>>> queryPrints({
    DateTime? from, DateTime? to, String? productLike,
  }) {
    final where = <String>[];
    final args  = <Object?>[];
    if (from != null) { where.add('ts >= ?'); args.add(from.millisecondsSinceEpoch); }
    if (to   != null) { where.add('ts <= ?'); args.add(to.millisecondsSinceEpoch); }
    if (productLike != null && productLike.isNotEmpty) {
      where.add('product LIKE ?'); args.add('%$productLike%');
    }
    return _db.query('prints',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args,
      orderBy: 'ts DESC');
  }

  Future<String> nextSerial(String prefix) async {
    final r = await _db.rawQuery(
      "SELECT serial FROM prints WHERE serial LIKE ? ORDER BY id DESC LIMIT 1",
      ['$prefix%']);
    int n = 0;
    if (r.isNotEmpty) {
      final s = r.first['serial'] as String;
      final tail = s.substring(prefix.length);
      n = int.tryParse(tail) ?? 0;
    }
    return '$prefix${(n + 1).toString().padLeft(5, '0')}';
  }
}
