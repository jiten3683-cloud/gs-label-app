import 'package:qr/qr.dart';

enum ElType { text, qr, bar, box, logo, weight, dateTime, serial }

// ── Barcode sizing ───────────────────────────────────────────────────────────
// A barcode is a whole number of "modules" (narrowest bar), and TSPL takes the
// module width in dots — so the printed width can only be a multiple of the
// module count the data needs. The Width set in the studio is the target; the
// closest width the printer can actually make is what gets printed and drawn.

/// Modules the barcode needs for [data], quiet zones excluded.
int barcodeModules(String type, String data) {
  final n = data.isEmpty ? 10 : data.length;
  switch (type) {
    case 'EAN13':
    case 'UPC':   return 95;                  // fixed-length symbologies
    case 'EAN8':  return 67;
    case '39':    return 13 * (n + 2) - 1;    // 6 narrow + 3 wide (2:1) + gap, plus start/stop
    default:                                  // Code128, printer picks the subset
      return 11 * (code128Symbols(data.isEmpty ? '0123456789' : data) + 2) + 13;
  }
}

/// Data symbols Code 128 needs when the printer switches subsets itself:
/// runs of 4+ digits (or an all-digit code) go in subset C, two digits per
/// symbol; everything else in subset B, one per symbol; each switch between
/// them costs one symbol. Start, check and stop are counted by the caller.
int code128Symbols(String data) {
  final allDigits = RegExp(r'^\d+$').hasMatch(data);
  var sym = 0;
  String? cur;                                // 'B' or 'C'
  void use(String set) {
    if (cur != null && cur != set) sym++;     // CODE B / CODE C switch
    cur = set;
  }
  for (final m in RegExp(r'\d+|\D+').allMatches(data)) {
    final run = m.group(0)!;
    final digits = RegExp(r'^\d').hasMatch(run);
    if (digits && (run.length >= 4 || (allDigits && run.length >= 2))) {
      if (run.length.isOdd) { use('B'); sym++; }   // odd digit out in subset B
      use('C');
      sym += run.length ~/ 2;
    } else {
      use('B');
      sym += run.length;
    }
  }
  return sym;
}

/// Module width in dots that lands closest to [targetDots]. Never 0 — one dot
/// per module is the thinnest any printer can go.
int barcodeNarrow(String type, String data, int targetDots) =>
    (targetDots / barcodeModules(type, data)).round().clamp(1, 10);

// ── "Numbers only" barcodes ─────────────────────────────────────────────────
// Each {field} is replaced by digits only; anything typed between fields (a
// '-' or '/' separator) is kept. Weights always get 3 decimals so the digits
// are unambiguous: 20.58 g and 20.580 g both become 20580. The ESP32 does the
// same on button/auto prints (fillLiveJob, 'dig').

String _onlyDigits(String s) => s.replaceAll(RegExp(r'\D'), '');

/// [value] (e.g. "20.58 g") as digits with exactly [decimals] decimals.
String fixedDigits(String value, int decimals) {
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(value);
  if (m == null) return '';
  final v = double.tryParse(m.group(0)!) ?? 0;
  return _onlyDigits(v.abs().toStringAsFixed(decimals));
}

/// [template] with every placeholder filled as digits only.
String digitsOnlyFields(String template, LabelContext ctx) {
  final w = <String, String>{
    '{net}': ctx.netStr, '{gross}': ctx.grossStr, '{tare}': ctx.tareStr,
    '{metal}': ctx.metalStr, '{stone}': ctx.stoneStr,
  };
  final m = <String, String>{
    '{rate}': ctx.rateStr, '{amount}': ctx.amountStr, '{making}': ctx.makingStr,
  };
  var s = template;
  w.forEach((k, v) => s = s.replaceAll(k, fixedDigits(v, 3)));
  m.forEach((k, v) => s = s.replaceAll(k, fixedDigits(v, 2)));
  s = s.replaceAll('{serial}', _onlyDigits(ctx.serial));
  for (final k in ['{date}', '{time}', '{product}', '{purity}', '{hsn}', '{category}',
      '{code}', '{shop}', '{company}', '{address}', '{phone}', '{gst}']) {
    final v = switch (k) {
      '{date}' => ctx.dateStr, '{time}' => ctx.timeStr, '{product}' => ctx.product,
      '{purity}' => ctx.purity, '{hsn}' => ctx.hsn, '{category}' => ctx.category,
      '{code}' => ctx.code, '{shop}' => ctx.shopName, '{company}' => ctx.companyName,
      '{address}' => ctx.companyAddress, '{phone}' => ctx.companyPhone, _ => ctx.companyGst,
    };
    s = s.replaceAll(k, _onlyDigits(v));
  }
  return s;
}

/// Barcode content as it prints, from [data] filled with realistic sample
/// values (serial GS-00001, weights like 12.345 g).
String barcodeSample(String data, {bool digitsOnly = false}) {
  const ctx = LabelContext(
    netStr: '12.345 g', grossStr: '12.500 g', tareStr: '0.155 g',
    stoneStr: '0.100 g', metalStr: '12.245 g', serial: 'GS-00001',
    dateStr: '23-09-2026', timeStr: '14:30', product: 'Ring', purity: '22K',
    hsn: '7113', code: 'AB123', rateStr: '6500.00', amountStr: '79462.50',
    makingStr: '1200.00',
  );
  final s = digitsOnly ? digitsOnlyFields(data, ctx) : data
      .replaceAll('{serial}', ctx.serial)
      .replaceAll(RegExp(r'\{(net|gross|tare|metal|stone)\}'), '12.345 g')
      .replaceAll(RegExp(r'\{(rate|amount|making)\}'), '6500.00')
      .replaceAll(RegExp(r'\{[a-z]+\}'), 'AB123');
  return s.replaceAll('{nl}', ' ').replaceAll('{tab}', ' ');
}

/// Rewrites QR [data] so a keyboard-mode scanner types its fields down one
/// column (Enter between them) or across one row (Tab between them).
/// No trailing {nl}: the scanner adds its own Enter after every scan, which
/// already moves the next scan to a fresh row.
/// Fields are the parts between line breaks, {nl} and {tab}.
String qrScanLayout(String data, {required bool columns}) {
  final fields = data
      .replaceAll('\r\n', '{nl}').replaceAll('\n', '{nl}')
      .split(RegExp(r'\{nl\}|\{tab\}'))
      .map((f) => f.trim())
      .where((f) => f.isNotEmpty);
  if (fields.isEmpty) return data;
  return fields.join(columns ? '{tab}' : '{nl}');
}

/// True when resolved QR text holds a TAB or line break ({tab}/{nl}).
bool hasQrControl(String s) => RegExp(r'[\t\r\n]').hasMatch(s);

/// Draws the QR for [s] as TSPL BITMAP data (the logo format: 1 bit per dot,
/// MSB first, black = 1), [cell] dots per module, no quiet zone, like QRCODE.
/// TSC printers strip TAB from QRCODE text in every mode and turn the \[R]
/// escape into CR+LF plus a repeated character, so a QR that must make the
/// scanner press Tab/Enter is sent as a picture instead.
/// Returns the 'bw' (bytes per row), 'lh' (rows) and 'bmp' (hex) fields.
Map<String, dynamic> qrBitmap(String s, String ecc, int cell) {
  final img = QrImage(QrCode.fromData(data: s, errorCorrectLevel: switch (ecc) {
    'L' => QrErrorCorrectLevel.L,
    'Q' => QrErrorCorrectLevel.Q,
    'H' => QrErrorCorrectLevel.H,
    _   => QrErrorCorrectLevel.M,
  }));
  cell = cell.clamp(1, 10);
  final n = img.moduleCount, dots = n * cell, bw = (dots + 7) ~/ 8;
  final sb = StringBuffer();
  for (var y = 0; y < dots; y++) {
    final row = List<int>.filled(bw, 0);
    for (var x = 0; x < dots; x++) {
      if (img.isDark(y ~/ cell, x ~/ cell)) row[x >> 3] |= 0x80 >> (x & 7);
    }
    for (final b in row) { sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase()); }
  }
  return {'bw': bw, 'lh': dots, 'bmp': sb.toString()};
}

/// Width that will actually be printed when aiming for [targetDots].
int barcodePrintedWidth(String type, String data, int targetDots) =>
    barcodeNarrow(type, data, targetDots) * barcodeModules(type, data);

class LabelElement {
  ElType type;
  int x, y;

  String text;
  String font;
  int xScale, yScale;
  int rotation;
  bool bold;

  String data;
  String barcodeType;
  int    barcodeHeight;
  int    barcodeWidth;
  /// Keep only the digits of the content: the printer then uses Code 128-C,
  /// two digits per symbol — about half as long, so bars can be thicker and
  /// the code scans easily.
  bool   barcodeDigitsOnly;
  /// Bar thickness in dots chosen by the user (1–4). Stays fixed whatever the
  /// content or weight length — only the barcode's length follows the data.
  /// 0 = older template: thickness derived from the target width [barcodeWidth].
  int    barcodeBarDots;
  String qrEcc;
  int    qrSize;

  int xEnd, yEnd, thickness;

  String logoName;
  // Logo image fields (set by image picker in designer)
  String logoPath;       // absolute path to PNG file on device (for canvas preview)
  String logoBmpHex;     // hex-encoded TSPL BITMAP data, precomputed at pick time
  int    logoBmpW;       // bytes per row for BITMAP command (= ceil(logoWidthDots/8))
  int    logoWidthDots;  // width in printer dots
  int    logoHeightDots; // height in printer dots

  String prefix;
  String suffix;
  int    decimals;
  String unit;
  // 0 = net, 1 = gross, 2 = tare — explicit weight type, independent of prefix text
  int    wtType;

  LabelElement({
    required this.type, this.x = 10, this.y = 10,
    this.text = '', this.font = '3', this.xScale = 1, this.yScale = 1,
    this.rotation = 0, this.bold = false,
    this.data = '', this.barcodeType = '128', this.barcodeHeight = 60, this.barcodeWidth = 120,
    this.barcodeDigitsOnly = false,
    this.barcodeBarDots = 0,
    this.qrEcc = 'M', this.qrSize = 4,
    this.xEnd = 100, this.yEnd = 100, this.thickness = 2,
    this.logoName = 'LOGO.BMP',
    this.logoPath = '', this.logoBmpHex = '', this.logoBmpW = 0,
    this.logoWidthDots = 80, this.logoHeightDots = 48,
    this.prefix = '', this.suffix = '', this.decimals = 3, this.unit = 'g',
    this.wtType = 0,
  });

  Map<String, dynamic> toJson(LabelContext ctx) {
    // Tokens the ESP32 re-fills on a physical-button or auto print: the live
    // scale reading, values derived from it, the next serial and the clock.
    // {stone} is operator-entered, not read from the scale, so it is always
    // resolved here.
    String live(String s) => s
        .replaceAll('{net}',      ctx.netStr)
        .replaceAll('{gross}',    ctx.grossStr)
        .replaceAll('{tare}',     ctx.tareStr)
        .replaceAll('{metal}',    ctx.metalStr)
        .replaceAll('{amount}',   ctx.amountStr)
        .replaceAll('{making}',   ctx.makingStr)
        .replaceAll('{serial}',   ctx.serial)
        .replaceAll('{date}',     ctx.dateStr)
        .replaceAll('{time}',     ctx.timeStr);
    // keepLive leaves the live tokens in place (for 'tpl').
    String resolve(String s, {bool keepLive = false}) => (keepLive ? s : live(s))
        .replaceAll('{stone}',    ctx.stoneStr)
        .replaceAll('{product}',  ctx.product)
        .replaceAll('{purity}',   ctx.purity)
        .replaceAll('{hsn}',      ctx.hsn)
        .replaceAll('{category}', ctx.category)
        .replaceAll('{code}',     ctx.code)
        .replaceAll('{rate}',     ctx.rateStr)
        .replaceAll('{shop}',     ctx.shopName)
        .replaceAll('{company}',  ctx.companyName)
        .replaceAll('{address}',  ctx.companyAddress)
        .replaceAll('{phone}',    ctx.companyPhone)
        .replaceAll('{gst}',      ctx.companyGst);

    // {nl}/{tab} only mean something inside a QR: there they become a real CR
    // and TAB byte, so a keyboard-mode scanner types each field on its own line
    // (Enter) or into the next column/field (Tab). A line break typed straight
    // into the QR data box is treated the same as {nl}.
    // CR alone, not CR+LF: scanners turn each of CR and LF into an Enter key,
    // so CR+LF left a blank row between fields in Excel.
    // Text and barcodes can't carry control characters, so they get a space.
    String flat(String s, {bool keepLive = false}) => resolve(s, keepLive: keepLive)
        .replaceAll('{nl}', ' ').replaceAll('{tab}', ' ');
    String qrResolve(String s, {bool keepLive = false}) => resolve(s, keepLive: keepLive)
        .replaceAll('\r\n', '{nl}').replaceAll('\n', '{nl}')
        .replaceAll('{nl}', '\r').replaceAll('{tab}', '\t');

    // Elements using a live token also get 'tpl': the same content with those
    // tokens unresolved, which the ESP32 fills in on button/auto prints.
    final hasLive = RegExp(r'\{(net|gross|tare|metal|amount|making|serial|date|time)\}');
    Map<String, dynamic> withTpl(Map<String, dynamic> m, String src, String Function() tpl) {
      if (hasLive.hasMatch(src)) m['tpl'] = tpl();
      return m;
    }

    switch (type) {
      case ElType.text:
        return withTpl({'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale, 'bold': bold,
                'text': '$prefix${flat(text)}$suffix'},
            text, () => '$prefix${flat(text, keepLive: true)}$suffix');
      case ElType.weight:
        final String wtStr;
        final String wtVar;
        if (wtType == 1) {
          wtStr = ctx.grossStr; wtVar = 'gross';
        } else if (wtType == 2) {
          wtStr = ctx.tareStr; wtVar = 'tare';
        } else {
          wtStr = ctx.netStr; wtVar = 'net';
        }
        // 'unit' rides along so a physical-button reprint on the ESP32 appends the
        // same suffix the app chose, instead of falling back to a hardcoded "g".
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale, 'bold': bold,
                'text': '$prefix$wtStr$suffix',
                'wt_var': wtVar, 'pre': prefix, 'suf': suffix,
                'unit': unit == 'None' ? '' : unit};
      case ElType.serial:
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale, 'bold': bold,
                'text': '$prefix${ctx.serial}$suffix',
                'tpl': '$prefix{serial}$suffix'};
      case ElType.dateTime:
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale, 'bold': bold,
                'text': '${ctx.dateStr} ${ctx.timeStr}',
                'tpl': '{date} {time}'};
      case ElType.qr:
        final q = qrResolve(data);
        final m = {'type': 'qr', 'x': x, 'y': y, 'ecc': qrEcc,
                'size': qrSize, 'rot': rotation, 'mode': 'A', 'data': q};
        // With {tab}/{nl} the QR goes as a bitmap ('logo' + 'qr': 1): the
        // printer can't be trusted with those bytes (see qrBitmap). Firmware
        // from 2026-09-30 redraws it from 'data'/'tpl' on button/auto prints.
        if (hasQrControl(q)) m.addAll({'type': 'logo', 'qr': 1, ...qrBitmap(q, qrEcc, qrSize)});
        return withTpl(m, data, () => qrResolve(data, keepLive: true));
      case ElType.bar:
        // 'narrow' is what actually sizes the printed barcode; 'bw' is the
        // resulting width, which the preview draws.
        // 'dig' tells the ESP32 to strip non-digits after filling in live
        // values on button/auto prints, like the app does here.
        final bdata  = barcodeDigitsOnly
            ? flat(digitsOnlyFields(data, ctx))
            : flat(data);
        // Numbers-only barcodes saved before the thickness was stored get
        // easy-to-scan 2-dot bars.
        final narrow = barcodeBarDots > 0
            ? barcodeBarDots.clamp(1, 10)
            : barcodeDigitsOnly ? 2 : barcodeNarrow(barcodeType, bdata, barcodeWidth);
        return withTpl({'type': 'bar', 'x': x, 'y': y, 'btype': barcodeType,
                'height': barcodeHeight,
                'bw': narrow * barcodeModules(barcodeType, bdata),
                'hr': 1, 'rot': rotation,
                'narrow': narrow, 'wide': narrow * 2, 'data': bdata,
                if (barcodeDigitsOnly) 'dig': 1},
            data, () => flat(data, keepLive: true));
      case ElType.box:
        return {'type': 'box', 'x': x, 'y': y, 'xe': xEnd, 'ye': yEnd, 't': thickness};
      case ElType.logo:
        final m = <String, dynamic>{
          'type': 'logo', 'x': x, 'y': y, 'name': logoName,
          'lw': logoWidthDots, 'lh': logoHeightDots, 'path': logoPath,
        };
        if (logoBmpHex.isNotEmpty) {
          m['bmp'] = logoBmpHex;
          m['bw']  = logoBmpW;
        }
        return m;
    }
  }
}

class LabelContext {
  final String netStr, grossStr, tareStr;
  final String stoneStr, metalStr;   // stone deduction & metal net
  final String serial;
  final String dateStr, timeStr;
  final String product, purity, hsn, category, code;
  final String rateStr, amountStr, makingStr;
  final String shopName, companyName, companyAddress, companyPhone, companyGst;

  const LabelContext({
    required this.netStr, required this.grossStr, required this.tareStr,
    required this.serial,
    required this.dateStr, required this.timeStr,
    this.stoneStr = '', this.metalStr = '',
    this.product = '', this.purity = '',
    this.hsn = '', this.category = '', this.code = '',
    this.rateStr = '', this.amountStr = '', this.makingStr = '',
    this.shopName = '', this.companyName = '',
    this.companyAddress = '', this.companyPhone = '', this.companyGst = '',
  });
}
