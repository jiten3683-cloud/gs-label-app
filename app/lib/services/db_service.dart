import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class DbService {
  late Database _db;

  /// Incremented whenever templates are created, updated, or deleted.
  final templateVersion = ValueNotifier<int>(0);

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _db = await openDatabase(
      p.join(dir.path, 'gs_label.db'),
      version: 6,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int v) async {
    await db.execute('''
      CREATE TABLE templates (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        name      TEXT NOT NULL,
        width_mm  INTEGER NOT NULL,
        height_mm INTEGER NOT NULL,
        gap_mm    INTEGER NOT NULL DEFAULT 3,
        json      TEXT NOT NULL DEFAULT '[]',
        lines     TEXT NOT NULL DEFAULT '[]',
        updated   INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE products (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        code        TEXT,
        name        TEXT NOT NULL,
        category    TEXT NOT NULL DEFAULT '',
        purity      TEXT NOT NULL DEFAULT '',
        hsn         TEXT NOT NULL DEFAULT '',
        rate        REAL NOT NULL DEFAULT 0,
        making      REAL NOT NULL DEFAULT 0,
        template_id INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE prints (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        serial       TEXT NOT NULL,
        product      TEXT,
        purity       TEXT,
        hsn          TEXT,
        gross_g      REAL,
        tare_g       REAL,
        net_g        REAL,
        stone_g      REAL DEFAULT 0,
        rate         REAL,
        making       REAL,
        amount       REAL,
        barcode      TEXT DEFAULT '',
        qr_data      TEXT DEFAULT '',
        operator_name TEXT DEFAULT '',
        printer_name TEXT DEFAULT '',
        copies       INTEGER DEFAULT 1,
        ts           INTEGER NOT NULL,
        template     TEXT,
        job_snapshot TEXT DEFAULT ''
      )
    ''');
    await db.execute('CREATE INDEX idx_prints_ts     ON prints(ts)');
    await db.execute('CREATE INDEX idx_prints_serial ON prints(serial)');
    await db.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE print_queue (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        job_json   TEXT NOT NULL,
        label_info TEXT NOT NULL DEFAULT '',
        ts         INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT ''
        )
      ''');
    }
    if (oldV < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS print_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          job_json TEXT NOT NULL, label_info TEXT NOT NULL DEFAULT '',
          ts INTEGER NOT NULL
        )
      ''');
      for (final sql in [
        'ALTER TABLE prints ADD COLUMN hsn TEXT',
        'ALTER TABLE prints ADD COLUMN making REAL',
        "ALTER TABLE products ADD COLUMN category TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE products ADD COLUMN hsn TEXT NOT NULL DEFAULT ''",
        'ALTER TABLE products ADD COLUMN making REAL NOT NULL DEFAULT 0',
      ]) { try { await db.execute(sql); } catch (_) {} }
    }
    if (oldV < 4) {
      try { await db.execute("ALTER TABLE templates ADD COLUMN lines TEXT NOT NULL DEFAULT '[]'"); } catch (_) {}
    }
    if (oldV < 5) {
      // Add extended print log columns (safe: ALTER TABLE ADD COLUMN is idempotent via try/catch)
      for (final sql in [
        'ALTER TABLE prints ADD COLUMN stone_g REAL DEFAULT 0',
        "ALTER TABLE prints ADD COLUMN barcode TEXT DEFAULT ''",
        "ALTER TABLE prints ADD COLUMN qr_data TEXT DEFAULT ''",
        "ALTER TABLE prints ADD COLUMN operator_name TEXT DEFAULT ''",
        "ALTER TABLE prints ADD COLUMN printer_name TEXT DEFAULT ''",
        'ALTER TABLE prints ADD COLUMN copies INTEGER DEFAULT 1',
      ]) { try { await db.execute(sql); } catch (_) {} }
      try { await db.execute('CREATE INDEX IF NOT EXISTS idx_prints_serial ON prints(serial)'); } catch (_) {}
    }
    if (oldV < 6) {
      // Store complete resolved job JSON for label preview & reprint from reports
      try { await db.execute("ALTER TABLE prints ADD COLUMN job_snapshot TEXT DEFAULT ''"); } catch (_) {}
    }
  }

  // ── Templates ────────────────────────────────────────────────────────────────

  Future<void> seedDefaultTemplates() async {
    if ((await _db.query('templates', limit: 1)).isNotEmpty) return;
    await saveTemplate(
      name: 'Gold/Silver Tag (50×25)', wMm: 50, hMm: 25, gapMm: 3, json: [],
      lines: ['{product}  {purity}', 'G:{gross}  N:{net}', 'T:{tare}  {date}', 'SN:{serial}'],
    );
  }

  static List<String> parseLines(Map<String, dynamic> row) {
    try {
      final raw = row['lines'] as String? ?? '[]';
      final list = jsonDecode(raw);
      if (list is List) {
        final r = list.map((e) => e.toString()).toList();
        while (r.length < 4) r.add('');
        return r;
      }
    } catch (_) {}
    return ['', '', '', ''];
  }

  Future<int> saveTemplate({
    int? id, required String name,
    required int wMm, required int hMm, int gapMm = 3,
    required Object json, List<String>? lines,
  }) async {
    final row = <String, dynamic>{
      'name': name, 'width_mm': wMm, 'height_mm': hMm, 'gap_mm': gapMm,
      'json': jsonEncode(json),
      'updated': DateTime.now().millisecondsSinceEpoch,
    };
    if (lines != null) row['lines'] = jsonEncode(lines);
    if (id == null) {
      final newId = await _db.insert('templates', row);
      templateVersion.value++;
      return newId;
    }
    await _db.update('templates', row, where: 'id=?', whereArgs: [id]);
    templateVersion.value++;
    return id;
  }

  Future<void> saveTemplateLines(int id, List<String> lines) async {
    await _db.update('templates',
        {'lines': jsonEncode(lines), 'updated': DateTime.now().millisecondsSinceEpoch},
        where: 'id=?', whereArgs: [id]);
    templateVersion.value++;
  }

  Future<List<Map<String, dynamic>>> listTemplates() =>
      _db.query('templates', orderBy: 'updated DESC');

  Future<Map<String, dynamic>?> getTemplate(int id) async {
    final r = await _db.query('templates', where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  Future<void> deleteTemplate(int id) async {
    await _db.delete('templates', where: 'id=?', whereArgs: [id]);
    templateVersion.value++;
  }

  Future<int> duplicateTemplate(int id) async {
    final t = await getTemplate(id);
    if (t == null) throw Exception('Template not found');
    return saveTemplate(
      name: '${t['name']} (copy)', wMm: t['width_mm'] as int,
      hMm: t['height_mm'] as int, gapMm: t['gap_mm'] as int,
      json: jsonDecode(t['json'] as String) as Object,
      lines: parseLines(t),
    );
  }

  // ── Products ─────────────────────────────────────────────────────────────────

  Future<int> saveProduct({
    int? id, required String name, String code = '',
    String category = '', String purity = '', String hsn = '',
    double rate = 0, double making = 0, int? templateId,
  }) async {
    final row = <String, dynamic>{
      'name': name, 'code': code.isEmpty ? null : code,
      'category': category, 'purity': purity, 'hsn': hsn,
      'rate': rate, 'making': making, 'template_id': templateId,
    };
    if (id == null) return _db.insert('products', row);
    await _db.update('products', row, where: 'id=?', whereArgs: [id]);
    return id;
  }

  Future<List<Map<String, dynamic>>> listProducts({String? search}) {
    if (search != null && search.isNotEmpty) {
      return _db.query('products',
          where: 'name LIKE ? OR code LIKE ?',
          whereArgs: ['%$search%', '%$search%'],
          orderBy: 'name ASC');
    }
    return _db.query('products', orderBy: 'name ASC');
  }

  Future<Map<String, dynamic>?> getProduct(int id) async {
    final r = await _db.query('products', where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  Future<void> deleteProduct(int id) =>
      _db.delete('products', where: 'id=?', whereArgs: [id]);

  // ── Prints ───────────────────────────────────────────────────────────────────

  Future<int> logPrint(Map<String, dynamic> row) => _db.insert('prints', row);

  /// Advanced filtered query.
  /// [search] matches against serial, product, barcode, qr_data (any contains).
  Future<List<Map<String, dynamic>>> queryPrints({
    DateTime? from,
    DateTime? to,
    String?   search,
    String?   productLike,  // kept for backward compat
  }) {
    final where = <String>[];
    final args  = <Object?>[];

    if (from != null) { where.add('ts >= ?'); args.add(from.millisecondsSinceEpoch); }
    if (to   != null) {
      // Include the whole day of 'to'
      final endOfDay = DateTime(to.year, to.month, to.day, 23, 59, 59);
      where.add('ts <= ?');
      args.add(endOfDay.millisecondsSinceEpoch);
    }

    final term = (search?.trim().isNotEmpty == true ? search : productLike)?.trim();
    if (term != null && term.isNotEmpty) {
      where.add('(serial LIKE ? OR product LIKE ? OR barcode LIKE ? OR qr_data LIKE ?)');
      args.addAll(['%$term%', '%$term%', '%$term%', '%$term%']);
    }

    return _db.query('prints',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args,
        orderBy: 'ts DESC');
  }

  /// Summary totals for a filtered set — returns count, total net, total gross, total amount.
  Future<Map<String, dynamic>> querySummary({DateTime? from, DateTime? to, String? search}) async {
    final where = <String>[];
    final args  = <Object?>[];
    if (from != null) { where.add('ts >= ?'); args.add(from.millisecondsSinceEpoch); }
    if (to   != null) {
      final endOfDay = DateTime(to.year, to.month, to.day, 23, 59, 59);
      where.add('ts <= ?'); args.add(endOfDay.millisecondsSinceEpoch);
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add('(serial LIKE ? OR product LIKE ? OR barcode LIKE ?)');
      args.addAll(['%${search.trim()}%', '%${search.trim()}%', '%${search.trim()}%']);
    }
    final w = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final r = await _db.rawQuery(
        'SELECT COUNT(*) as cnt, SUM(net_g) as net, SUM(gross_g) as gross, '
        'SUM(amount) as amt FROM prints $w', args);
    return r.isNotEmpty ? r.first : {'cnt': 0, 'net': 0.0, 'gross': 0.0, 'amt': 0.0};
  }

  // Delete a single print record
  Future<void> deletePrint(int id) => _db.delete('prints', where: 'id=?', whereArgs: [id]);

  // Delete multiple print records by id list
  Future<void> deletePrints(List<int> ids) async {
    if (ids.isEmpty) return;
    final placeholders = ids.map((_) => '?').join(',');
    await _db.delete('prints', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  // Delete all prints in a date range
  Future<void> deletePrintsByRange(DateTime from, DateTime to) async {
    final endOfDay = DateTime(to.year, to.month, to.day, 23, 59, 59);
    await _db.delete('prints',
        where: 'ts >= ? AND ts <= ?',
        whereArgs: [from.millisecondsSinceEpoch, endOfDay.millisecondsSinceEpoch]);
  }

  // Clear all print history
  Future<void> clearAllPrints() => _db.delete('prints');

  // ── Serial number ─────────────────────────────────────────────────────────────

  /// Returns the next serial and atomically increments the persistent counter.
  ///
  /// Uses the `serial_counter` settings key as the source of truth.
  /// On first call (no counter stored), bootstraps from print history or `serial_start`.
  /// Duplicate serials are impossible as long as all prints go through this method.
  Future<String> nextSerial(String prefix, {int padLen = 5, String suffix = ''}) async {
    const counterKey = 'serial_counter';
    final currentStr = await getSetting(counterKey, def: '');
    int current;

    if (currentStr.isEmpty) {
      // Bootstrap: try to derive the current counter from existing print history
      final r = await _db.rawQuery(
          "SELECT serial FROM prints WHERE serial LIKE ? ORDER BY id DESC LIMIT 1",
          ['$prefix%']);
      if (r.isNotEmpty) {
        final s = (r.first['serial'] as String).replaceFirst(prefix, '');
        final noSuf = suffix.isNotEmpty ? s.replaceAll(suffix, '') : s;
        current = int.tryParse(noSuf) ?? 0;
      } else {
        // No history — start from serial_start setting (default 1)
        final startStr = await getSetting('serial_start', def: '1');
        current = (int.tryParse(startStr) ?? 1) - 1;
      }
    } else {
      current = int.tryParse(currentStr) ?? 0;
    }

    final next = current + 1;
    final safeNext = next < 1 ? 1 : (next > 9999999 ? 9999999 : next);
    await setSetting(counterKey, safeNext.toString());
    return '$prefix${safeNext.toString().padLeft(padLen, '0')}$suffix';
  }

  /// Read-only preview of the next serial — does NOT increment the counter.
  /// Use this for UI display only; use [nextSerial] only when actually printing.
  Future<String> peekNextSerial(String prefix, {int padLen = 5, String suffix = ''}) async {
    const counterKey = 'serial_counter';
    final currentStr = await getSetting(counterKey, def: '');
    int current;
    if (currentStr.isEmpty) {
      final r = await _db.rawQuery(
          "SELECT serial FROM prints WHERE serial LIKE ? ORDER BY id DESC LIMIT 1",
          ['$prefix%']);
      if (r.isNotEmpty) {
        final s = (r.first['serial'] as String).replaceFirst(prefix, '');
        final noSuf = suffix.isNotEmpty ? s.replaceAll(suffix, '') : s;
        current = int.tryParse(noSuf) ?? 0;
      } else {
        final startStr = await getSetting('serial_start', def: '1');
        current = (int.tryParse(startStr) ?? 1) - 1;
      }
    } else {
      current = int.tryParse(currentStr) ?? 0;
    }
    final next = current + 1;
    final safeNext = next < 1 ? 1 : (next > 9999999 ? 9999999 : next);
    return '$prefix${safeNext.toString().padLeft(padLen, '0')}$suffix';
  }

  /// Reset the serial counter.  The very next print will use [startFrom].
  Future<void> resetSerialCounter(int startFrom) async {
    if (startFrom < 1) startFrom = 1;
    await setSetting('serial_start',   startFrom.toString());
    await setSetting('serial_counter', (startFrom - 1).toString());
  }

  // ── Settings ─────────────────────────────────────────────────────────────────

  Future<String> getSetting(String key, {String def = ''}) async {
    final r = await _db.query('settings', where: 'key=?', whereArgs: [key]);
    return r.isEmpty ? def : (r.first['value'] as String? ?? def);
  }

  Future<void> setSetting(String key, String value) => _db.insert(
      'settings', {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<Map<String, String>> getAllSettings() async {
    final rows = await _db.query('settings');
    return {for (final r in rows) r['key'] as String: r['value'] as String? ?? ''};
  }

  // ── Offline queue ─────────────────────────────────────────────────────────────

  Future<int> enqueuePrint(Map<String, dynamic> job, {String labelInfo = ''}) =>
      _db.insert('print_queue', {
        'job_json': jsonEncode(job), 'label_info': labelInfo,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

  Future<List<Map<String, dynamic>>> getPendingQueue() =>
      _db.query('print_queue', orderBy: 'ts ASC');

  Future<void> dequeueprint(int id) =>
      _db.delete('print_queue', where: 'id=?', whereArgs: [id]);

  Future<int> queueCount() async {
    final r = await _db.rawQuery('SELECT COUNT(*) as c FROM print_queue');
    return (r.first['c'] as int?) ?? 0;
  }
}
