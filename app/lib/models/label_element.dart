enum ElType { text, qr, bar, box, logo, weight, dateTime, serial }

class LabelElement {
  ElType type;
  int x, y;

  String text;
  String font;
  int xScale, yScale;
  int rotation;

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

  LabelElement({
    required this.type, this.x = 10, this.y = 10,
    this.text = '', this.font = '3', this.xScale = 1, this.yScale = 1,
    this.rotation = 0,
    this.data = '', this.barcodeType = '128', this.barcodeHeight = 60, this.barcodeWidth = 120,
    this.qrEcc = 'M', this.qrSize = 4,
    this.xEnd = 100, this.yEnd = 100, this.thickness = 2,
    this.logoName = 'LOGO.BMP',
    this.logoPath = '', this.logoBmpHex = '', this.logoBmpW = 0,
    this.logoWidthDots = 80, this.logoHeightDots = 48,
    this.prefix = '', this.suffix = '', this.decimals = 3, this.unit = 'g',
  });

  Map<String, dynamic> toJson(LabelContext ctx) {
    String resolve(String s) => s
        .replaceAll('{net}',      ctx.netStr)
        .replaceAll('{gross}',    ctx.grossStr)
        .replaceAll('{tare}',     ctx.tareStr)
        .replaceAll('{stone}',    ctx.stoneStr)
        .replaceAll('{metal}',    ctx.metalStr)
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

    switch (type) {
      case ElType.text:
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale,
                'text': '$prefix${resolve(text)}$suffix'};
      case ElType.weight:
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale,
                'text': '$prefix${ctx.netStr}$suffix',
                'wt_var': 'net', 'pre': prefix, 'suf': suffix};
      case ElType.serial:
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale,
                'text': '$prefix${ctx.serial}$suffix'};
      case ElType.dateTime:
        return {'type': 'text', 'x': x, 'y': y, 'font': font, 'rot': rotation,
                'xs': xScale, 'ys': yScale,
                'text': '${ctx.dateStr} ${ctx.timeStr}'};
      case ElType.qr:
        return {'type': 'qr', 'x': x, 'y': y, 'ecc': qrEcc, 'size': qrSize,
                'rot': rotation, 'mode': 'A', 'data': resolve(data)};
      case ElType.bar:
        return {'type': 'bar', 'x': x, 'y': y, 'btype': barcodeType,
                'height': barcodeHeight, 'bw': barcodeWidth, 'hr': 1, 'rot': rotation,
                'narrow': 2, 'wide': 2, 'data': resolve(data)};
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
