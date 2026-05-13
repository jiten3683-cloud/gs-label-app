/// In-memory model for one element on a label. The label designer manipulates
/// a List<LabelElement>; serialization to JSON happens via [toJson] and is
/// directly compatible with the ESP32 firmware's TSPL builder.
///
/// Coordinates are in **printer dots** (203 dpi -> 8 dots / mm).
enum ElType { text, qr, bar, box, logo, weight, dateTime, serial }

class LabelElement {
  ElType type;
  int x, y;

  // text props
  String text;         // for static text OR for dynamic placeholders
  String font;         // TSPL font 1..8 (3 is a good default)
  int xScale, yScale;
  int rotation;        // 0,90,180,270

  // barcode / qr
  String data;         // can contain placeholders like "{serial}|{net}"
  String barcodeType;  // "128","39","EAN13"
  int    barcodeHeight;
  String qrEcc;        // L,M,Q,H
  int    qrSize;

  // box / line
  int xEnd, yEnd, thickness;

  // logo (stored in printer flash, see firmware PUTBMP)
  String logoName;

  // For dynamic fields:
  // text: ElType.weight prints latest net (with unit), ElType.serial prints next serial.
  String prefix;       // e.g. "GS-" for serials, "Rs. " for amounts
  String suffix;       // e.g. " g" for weight
  int    decimals;     // for weight
  String unit;         // 'g' or 'mg' (display only - ESP receives final string)

  LabelElement({
    required this.type, this.x = 10, this.y = 10,
    this.text = '', this.font = '3', this.xScale = 1, this.yScale = 1,
    this.rotation = 0,
    this.data = '', this.barcodeType = '128', this.barcodeHeight = 60,
    this.qrEcc = 'M', this.qrSize = 4,
    this.xEnd = 100, this.yEnd = 100, this.thickness = 2,
    this.logoName = 'LOGO.BMP',
    this.prefix = '', this.suffix = '', this.decimals = 3, this.unit = 'g',
  });

  /// Render this element into the JSON shape the ESP32 firmware understands.
  /// [ctx] supplies live values (weight, serial, datetime).
  Map<String, dynamic> toJson(LabelContext ctx) {
    String resolve(String s) =>
        s.replaceAll('{net}',    ctx.netStr)
         .replaceAll('{gross}',  ctx.grossStr)
         .replaceAll('{tare}',   ctx.tareStr)
         .replaceAll('{serial}', ctx.serial)
         .replaceAll('{date}',   ctx.dateStr)
         .replaceAll('{time}',   ctx.timeStr)
         .replaceAll('{product}',ctx.product)
         .replaceAll('{purity}', ctx.purity)
         .replaceAll('{rate}',   ctx.rateStr)
         .replaceAll('{amount}', ctx.amountStr);

    switch (type) {
      case ElType.text:
        return {'type':'text','x':x,'y':y,'font':font,'rot':rotation,
                'xs':xScale,'ys':yScale,'text':'$prefix${resolve(text)}$suffix'};
      case ElType.weight:
        return {'type':'text','x':x,'y':y,'font':font,'rot':rotation,
                'xs':xScale,'ys':yScale,
                'text':'$prefix${ctx.netStr}$suffix'};
      case ElType.serial:
        return {'type':'text','x':x,'y':y,'font':font,'rot':rotation,
                'xs':xScale,'ys':yScale,
                'text':'$prefix${ctx.serial}$suffix'};
      case ElType.dateTime:
        return {'type':'text','x':x,'y':y,'font':font,'rot':rotation,
                'xs':xScale,'ys':yScale,
                'text':'${ctx.dateStr} ${ctx.timeStr}'};
      case ElType.qr:
        return {'type':'qr','x':x,'y':y,'ecc':qrEcc,'size':qrSize,
                'rot':rotation,'mode':'A','data':resolve(data)};
      case ElType.bar:
        return {'type':'bar','x':x,'y':y,'btype':barcodeType,
                'height':barcodeHeight,'hr':1,'rot':rotation,
                'narrow':2,'wide':2,'data':resolve(data)};
      case ElType.box:
        return {'type':'box','x':x,'y':y,'xe':xEnd,'ye':yEnd,'t':thickness};
      case ElType.logo:
        return {'type':'logo','x':x,'y':y,'name':logoName};
    }
  }
}

/// Live values substituted into element placeholders at print-time.
class LabelContext {
  final String netStr, grossStr, tareStr;
  final String serial;
  final String dateStr, timeStr;
  final String product, purity;
  final String rateStr, amountStr;
  const LabelContext({
    required this.netStr, required this.grossStr, required this.tareStr,
    required this.serial,
    required this.dateStr, required this.timeStr,
    this.product = '', this.purity = '',
    this.rateStr = '', this.amountStr = '',
  });
}
