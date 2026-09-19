enum ElType { text, qr, bar, box, logo, weight, dateTime, serial }

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
    this.qrEcc = 'M', this.qrSize = 4,
    this.xEnd = 100, this.yEnd = 100, this.thickness = 2,
    this.logoName = 'LOGO.BMP',
    this.logoPath = '', this.logoBmpHex = '', this.logoBmpW = 0,
    this.logoWidthDots = 80, this.logoHeightDots = 48,
    this.prefix = '', this.suffix = '', this.decimals = 3, this.unit = 'g',
    this.wtType = 0,
  });

  Map<String, dynamic> toJson(LabelContext ctx) {
    // keepLive leaves the scale-driven tokens in place for the ESP32 to fill with
    // the live reading on a physical-button reprint. {stone} is operator-entered,
    // not read from the scale, so it is always resolved here.
    String resolve(String s, {bool keepLive = false}) => (keepLive ? s : s
        .replaceAll('{net}',      ctx.netStr)
        .replaceAll('{gross}',    ctx.grossStr)
        .replaceAll('{tare}',     ctx.tareStr)
        .replaceAll('{metal}',    ctx.metalStr))
        .replaceAll('{stone}',    ctx.stoneStr)
        .replaceAll('{serial}',   ctx.serial)
        .replaceAll('{date}',     ctx.dateStr)
        .replaceAll('{time}',     ctx.timeStr)
        .replaceAll('{product}',  ctx.product)
        .replaceAll('{purity}',   ctx.purity)
        .replaceAll('{hsn}',      ctx.hsn)
        .replaceAll('{category}', ctx.category)
        .replaceAll('{code}',     ctx.code)
        .replaceAll('{rate}',     ctx.rateStr)
        .replaceAll('{amount}',   ctx.amountStr)
        .replaceAll('{making}',   ctx.makingStr)
        .replaceAll('{shop}',     ctx.shopName)
        .replaceAll('{company}',  ctx.companyName)
        .replaceAll('{address}',  ctx.companyAddress)
        .replaceAll('{phone}',    ctx.companyPhone)
        .replaceAll('{gst}',      ctx.companyGst);

    // {nl}/{tab} only mean something inside a QR: there they become real CR+LF
    // and TAB bytes, so a keyboard-mode scanner types each field on its own line
    // (Enter) or into the next column/field (Tab). A line break typed straight
    // into the QR data box is treated the same as {nl}.
    // Text and barcodes can't carry control characters, so they get a space.
    String flat(String s) =>
        resolve(s).replaceAll('{nl}', ' ').replaceAll('{tab}', ' ');
    String qrResolve(String s, {bool keepLive = false}) => resolve(s, keepLive: keepLive)
        .replaceAll('\r\n', '{nl}').replaceAll('\n', '{nl}')
        .replaceAll('{nl}', '\r\n').replaceAll('{tab}', '\t');

    switch (type) {
      case ElType.text:
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale, 'bold': bold,
                'text': '$prefix${flat(text)}$suffix'};
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
                'text': '$prefix${ctx.serial}$suffix'};
      case ElType.dateTime:
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale, 'bold': bold,
                'text': '${ctx.dateStr} ${ctx.timeStr}'};
      case ElType.qr:
        final q = <String, dynamic>{'type': 'qr', 'x': x, 'y': y, 'ecc': qrEcc,
            'size': qrSize, 'rot': rotation, 'mode': 'A', 'data': qrResolve(data)};
        // A QR carrying scale weight also gets 'tpl' (weight tokens unresolved)
        // so a physical-button reprint on the ESP32 encodes the live weight.
        // The weight strings are "<number> <unit>" (or just "<number>" for
        // unit None), so the suffix and the stone number are read back from them.
        if (RegExp(r'\{(net|gross|tare|metal)\}').hasMatch(data)) {
          final sp = ctx.netStr.indexOf(' ');
          q['tpl']   = qrResolve(data, keepLive: true);
          q['unit']  = sp < 0 ? '' : ctx.netStr.substring(sp + 1);
          q['stone'] = double.tryParse(ctx.stoneStr.split(' ').first) ?? 0;
        }
        return q;
      case ElType.bar:
        return {'type': 'bar', 'x': x, 'y': y, 'btype': barcodeType,
                'height': barcodeHeight, 'bw': barcodeWidth, 'hr': 1, 'rot': rotation,
                'narrow': 2, 'wide': 2, 'data': flat(data)};
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
