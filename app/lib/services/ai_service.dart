import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AiService {
  static const _kKeyPref = 'ANTHROPIC_API_KEY';
  static const _kModel   = 'claude-haiku-4-5-20251001';
  static const _endpoint = 'https://api.anthropic.com/v1/messages';

  // TSPL font dot heights (height of a character in dots, xs=ys=1)
  static const _fontH = {'1': 12, '2': 20, '3': 24, '4': 32, '5': 48};

  Future<String?> getKey() async =>
      (await SharedPreferences.getInstance()).getString(_kKeyPref);
  Future<void> setKey(String k) async =>
      (await SharedPreferences.getInstance()).setString(_kKeyPref, k.trim());
  Future<void> clearKey() async =>
      (await SharedPreferences.getInstance()).remove(_kKeyPref);
  Future<bool> get hasKey async => (await getKey())?.isNotEmpty == true;

  // ── Public entry point ────────────────────────────────────────────────────────
  Future<AiResult> generate({
    required String prompt,
    required int widthMm,
    required int heightMm,
  }) async {
    final key = await getKey();
    if (key != null && key.isNotEmpty) {
      try {
        final els = await _callClaude(prompt, widthMm, heightMm, key);
        return AiResult(elements: els, source: AiSource.claude);
      } catch (e) {
        debugPrint('Claude failed, falling back: $e');
        return AiResult(
          elements: _ruleBased(prompt, widthMm, heightMm),
          source: AiSource.ruleBasedFallback,
          error: e.toString(),
        );
      }
    }
    return AiResult(
      elements: _ruleBased(prompt, widthMm, heightMm),
      source: AiSource.ruleBased,
    );
  }

  // ── Claude API ────────────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _callClaude(
      String userPrompt, int wMm, int hMm, String apiKey) async {
    final wDots = wMm * 8;
    final hDots = hMm * 8;
    final margin = _margin(hDots);
    final availH = hDots - 2 * margin;
    final availW = wDots - 2 * margin;

    // Pre-compute recommended sizes so Claude doesn't guess wrong
    final recFont  = _pickFont(availH ~/ 4).$1;
    final maxQrW   = (availW * 0.38).round();
    final maxQrH   = (availH * 0.75).round();
    final recQs    = _bestQs((maxQrW < maxQrH ? maxQrW : maxQrH).clamp(0, availH));
    final recBh    = (availH * 0.25).clamp(16, 80).round();
    final recQrX   = wDots - margin - recQs * 25;
    final recTextW = availW - recQs * 25 - 6;

    final system = '''
You are a label layout engine for jewellery price tags printed on a TSC TTP-244 Pro thermal printer (203 dpi, 8 dots/mm).

LABEL: $wMm mm × $hMm mm  =  $wDots × $hDots dots.
SAFE AREA: x ∈ [$margin, ${wDots - margin}]  y ∈ [$margin, ${hDots - margin}]
AVAILABLE: $availW × $availH dots inside margins.

STRICT CONTENT RULE: Include ONLY the element types the user explicitly requests.
  • If user says "gross" → use pre:"Gross: " NOT "Net:"
  • If user says "net" → use pre:"Net: "
  • If user says both → include both
  • NEVER add elements not mentioned by the user

BOUNDARY RULES — every element must fully fit inside the safe area:
  • Text at (x,y) with font "$recFont" occupies ${_fontH[recFont] ?? 20} dots height
  • QR qs=$recQs occupies ≈${recQs * 25}×${recQs * 25} dots — ensure x+${recQs * 25} ≤ ${wDots - margin}  y+${recQs * 25} ≤ ${hDots - margin}
  • Barcode at (x,y) height $recBh: ensure y+$recBh ≤ ${hDots - margin}
  • Elements must not overlap

FONT HEIGHTS (dots, xs=ys=1):
  "1"=12  "2"=20  "3"=24  "4"=32  "5"=48
RECOMMENDED for this label: font "$recFont" (${_fontH[recFont] ?? 20} dots)
Use font "1" or "2" for labels under 20 mm tall.

ELEMENT TYPES:
  {"t":"text",    "x":int,"y":int,"font":"$recFont","xs":1,"ys":1,"rot":0,"text":"...","pre":"","suf":""}
  {"t":"weight",  "x":int,"y":int,"font":"$recFont","xs":1,"ys":1,"pre":"Gross: ","suf":" g"}
  {"t":"serial",  "x":int,"y":int,"font":"$recFont","xs":1,"ys":1,"pre":"SN: ","suf":""}
  {"t":"dateTime","x":int,"y":int,"font":"$recFont","xs":1,"ys":1}
  {"t":"qr",      "x":$recQrX,"y":$margin,"qs":$recQs,"ecc":"M","data":"{serial}|{net}"}  ← physical size ≈${recQs * 25}×${recQs * 25} dots
  {"t":"bar",     "x":$margin,"y":int,"btype":"128","bh":$recBh,"bw":$availW,"data":"{serial}"}
  {"t":"box",     "x":$margin,"y":$margin,"xe":${wDots - margin},"ye":${hDots - margin},"th":2}

LAYOUT:
  • If QR present: place at x=$recQrX, y=$margin. Text elements use x=$margin width=$recTextW dots.
  • Stack text top→bottom from y=$margin, gap = font height × 0.2 (min 2 dots)
  • All text lines must fit within $availH dots height total

Output ONLY a valid JSON array. No markdown, no explanation.
''';

    final resp = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': _kModel,
        'max_tokens': 2048,
        'system': system,
        'messages': [{'role': 'user', 'content': userPrompt}],
      }),
    ).timeout(const Duration(seconds: 30));

    if (resp.statusCode != 200) {
      throw HttpException('Claude ${resp.statusCode}: '
          '${resp.body.substring(0, resp.body.length.clamp(0, 200))}');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final text = ((decoded['content'] as List).first
        as Map<String, dynamic>)['text'] as String;

    final start = text.indexOf('[');
    final end   = text.lastIndexOf(']');
    if (start < 0 || end <= start) {
      throw const FormatException('Claude did not return a JSON array');
    }
    final list = jsonDecode(text.substring(start, end + 1)) as List;
    return list
        .whereType<Map>()
        .map((m) => _clampElement(m.cast(), wDots, hDots))
        .toList();
  }

  // ── Rule-based generator ──────────────────────────────────────────────────────
  List<Map<String, dynamic>> _ruleBased(String prompt, int wMm, int hMm) {
    final p     = prompt.toLowerCase();
    final wDots = wMm * 8;
    final hDots = hMm * 8;

    // All elements are strictly opt-in — only include what the user asks for
    final wantQr  = p.contains('qr');
    final wantBar = p.contains('barcode') || p.contains(' bar ') ||
                    p.contains('bar,') || p.contains('bar.');
    final wantDate   = p.contains('date') || p.contains('time');
    final wantGross  = p.contains('gross');
    final wantNet    = p.contains('net');
    final wantSerial = p.contains('serial') || p.contains(' sr') ||
                       p.contains('sr.') || p.contains('sr,') ||
                       p.contains(' sn') || p.contains('sn.');
    final wantBorder = p.contains('border') || p.contains('frame');

    // Heading only if user mentions product/name/purity or a specific item type
    final wantHeading = p.contains('product') || p.contains('name') ||
        p.contains('purity') || p.contains('heading') || p.contains('title') ||
        p.contains('coin') || p.contains('biscuit') || p.contains('chain') ||
        p.contains('bangle') || p.contains('kada') || p.contains('bullion') ||
        p.contains('silver') || p.contains('ring') || p.contains('gold');

    String heading;
    if (p.contains('coin') || p.contains('biscuit'))  heading = 'Pure Coin 999';
    else if (p.contains('chain'))                      heading = 'Chain {purity}';
    else if (p.contains('bangle') || p.contains('kada')) heading = 'Bangle {purity}';
    else if (p.contains('bullion'))                    heading = 'Fine Gold 999';
    else if (p.contains('silver'))                     heading = 'Silver {purity}';
    else if (p.contains('ring'))                       heading = 'Gold Ring {purity}';
    else                                               heading = '{product} {purity}';

    return _buildLayout(
      wDots: wDots, hDots: hDots,
      heading: heading,
      wantHeading: wantHeading,
      wantQr: wantQr && !wantBar,
      wantBar: wantBar,
      wantGross: wantGross,
      wantNet: wantNet,
      wantSerial: wantSerial,
      wantDate: wantDate,
      wantBorder: wantBorder,
    );
  }

  // ── Smart layout engine ───────────────────────────────────────────────────────
  List<Map<String, dynamic>> _buildLayout({
    required int wDots,
    required int hDots,
    required String heading,
    required bool wantHeading,
    required bool wantQr,
    required bool wantBar,
    required bool wantGross,
    required bool wantNet,
    required bool wantSerial,
    required bool wantDate,
    required bool wantBorder,
  }) {
    final mg     = _margin(hDots);
    final availH = hDots - 2 * mg;
    final availW = wDots - 2 * mg;
    final elems  = <Map<String, dynamic>>[];

    // Border box
    if (wantBorder) {
      elems.add({'t':'box','x':mg,'y':mg,
          'xe':wDots - mg,'ye':hDots - mg,'th':2,'rot':0});
    }

    // ── QR placement (right column) ───────────────────────────────────────────
    int textW = availW;
    int qrX = 0, qrY = 0, qrDim = 0;

    if (wantQr) {
      // QR capped at 38% of width AND 75% of available height (keeps room for text)
      final maxQrW = (availW * 0.38).round();
      final maxQrH = (availH * 0.75).round();
      final maxQrDim = (maxQrW < maxQrH ? maxQrW : maxQrH).clamp(0, availH);
      final qs = _bestQs(maxQrDim);
      qrDim = qs * 25;  // physical size ≈ qs × 25 dots (QR v2, ~25 modules)
      if (qrDim >= 25) {
        qrX   = wDots - mg - qrDim;
        qrY   = mg;
        textW = availW - qrDim - 6;   // 6-dot gap between text and QR
        elems.add({'t':'qr','x':qrX,'y':qrY,'qs':qs,
            'ecc':'M','data':'{serial}|{net}','rot':0});
      } else {
        qrDim = 0;  // too small to place
      }
    }

    // ── Build text line list (only elements the user asked for) ───────────────
    final lines = <_Line>[];
    if (wantHeading) lines.add(_Line('text',     heading,  '', ''));
    if (wantGross)   lines.add(_Line('weight',   '', 'Gross: ', ' g', 1));
    if (wantNet)     lines.add(_Line('weight',   '', 'Net: ',   ' g', 0));
    if (wantSerial)  lines.add(_Line('serial',   '', 'SN: ',   ''));
    if (wantDate)    lines.add(_Line('dateTime', '', '',       ''));

    // If barcode needed, reserve bottom space for it first
    int barReserve = 0;
    int barH = 0, barW = 0;
    if (wantBar) {
      barH = (availH * 0.28).round().clamp(20, 72);
      barW = textW.clamp(80, wDots - 2 * mg);
      barReserve = barH + 4;
    }

    // Available vertical space for text lines
    final textAvailH = availH - barReserve;
    final nLines = lines.length;

    // ── Pick the largest font where ALL lines fit — no overflow ever ──────────
    String font = '1'; int fh = 12; int gapH = 3;
    for (final entry in [('5', 48), ('4', 32), ('3', 24), ('2', 20), ('1', 12)]) {
      final testFh  = entry.$2;
      final testGap = (testFh * 0.20).round().clamp(2, 8);
      if (nLines == 0 || nLines * (testFh + testGap) <= textAvailH) {
        font = entry.$1; fh = testFh; gapH = testGap;
        break;
      }
    }

    // Place text lines top-to-bottom
    int y = mg;
    for (final line in lines) {
      if (y + fh > hDots - mg - barReserve) break;   // stop if overflow
      elems.add({
        't': line.type, 'x': mg, 'y': y,
        'font': font, 'xs': 1, 'ys': 1, 'rot': 0,
        'text': line.text, 'pre': line.pre, 'suf': line.suf,
        'wt': line.wt,
        'data': '',
        'btype': '128', 'bh': 60, 'ecc': 'M', 'qs': 4,
        'xe': mg + textW, 'ye': y + fh, 'th': 2,
        'logo_path': '', 'logo_bmp': '', 'logo_bmpw': 0,
        'logo_w': 80, 'logo_h': 48,
        'dec': 3, 'unit': 'g',
      });
      y += fh + gapH;
    }

    // ── Barcode at bottom ─────────────────────────────────────────────────────
    if (wantBar && barH > 0) {
      final barY = hDots - mg - barH;
      elems.add({
        't': 'bar', 'x': mg, 'y': barY,
        'btype': '128', 'bh': barH, 'bw': barW,
        'data': '{serial}', 'rot': 0,
        'font': '2', 'xs': 1, 'ys': 1, 'text': '', 'pre': '', 'suf': '',
        'ecc': 'M', 'qs': 4, 'xe': mg + barW, 'ye': barY + barH, 'th': 2,
        'logo_path': '', 'logo_bmp': '', 'logo_bmpw': 0,
        'logo_w': 80, 'logo_h': 48, 'dec': 3, 'unit': 'g',
      });
    }

    return elems;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  // Margin: 2mm for large labels, 1mm for tiny labels, min 8 dots
  int _margin(int hDots) => (hDots * 0.08).round().clamp(8, 16);

  // Pick the largest font whose dot height is ≤ maxH
  (String, int) _pickFont(int maxH) {
    if (maxH >= 48) return ('5', 48);
    if (maxH >= 32) return ('4', 32);
    if (maxH >= 24) return ('3', 24);
    if (maxH >= 20) return ('2', 20);
    return ('1', 12);
  }

  // Largest QR cell-width (qs) where qs*25 ≤ maxDim
  // (QR v2 ≈ 25 modules; physical size ≈ qs × 25 dots — matches canvas rendering)
  int _bestQs(int maxDim) {
    for (int s = 8; s >= 2; s--) {
      if (s * 25 <= maxDim) return s;
    }
    return 2;
  }

  // Clamp & fill all fields so the editor never sees missing keys
  Map<String, dynamic> _clampElement(Map<String, dynamic> m, int w, int h) {
    final mg   = _margin(h);
    final type = m['t']?.toString() ?? 'text';

    // Initial position clamp within safe area
    int x = (m['x'] as num?)?.toInt().clamp(mg, w - mg) ?? mg;
    int y = (m['y'] as num?)?.toInt().clamp(mg, h - mg) ?? mg;

    // Auto-correct oversized fonts: ensure font height fits remaining space
    final rawFont  = m['font']?.toString() ?? '3';
    final availH   = h - mg - y;
    final fh       = _fontH[rawFont] ?? 24;
    final safeFont = fh <= availH ? rawFont : _pickFont(availH).$1;

    // QR: pick safe cell-width so physical size (qs×25) fits from current position
    final rawQs    = (m['qs'] as num?)?.toInt() ?? 4;
    final qrAvailW = (w - mg - x).clamp(25, w);
    final qrAvailH = (h - mg - y).clamp(25, h);
    final qrMaxDim = (qrAvailW < qrAvailH ? qrAvailW : qrAvailH).clamp(25, rawQs * 25);
    final safeQs   = _bestQs(qrMaxDim);
    final qrDim    = safeQs * 25;  // realistic physical footprint
    // Re-clamp QR position so the entire physical square stays inside the safe area
    if (type == 'qr') {
      x = x.clamp(mg, (w - mg - qrDim).clamp(mg, w - mg));
      y = y.clamp(mg, (h - mg - qrDim).clamp(mg, h - mg));
    }

    // Barcode: clamp dimensions to available label space first, then fix position
    final rawBh  = (m['bh'] as num?)?.toInt() ?? 50;
    final safeBh = rawBh.clamp(16, (h - 2 * mg).clamp(16, 200));
    final rawBw  = (m['bw'] as num?)?.toInt() ?? (w - 2 * mg);
    final safeBw = rawBw.clamp(40, (w - 2 * mg).clamp(40, 600));
    if (type == 'bar') {
      x = x.clamp(mg, (w - mg - safeBw).clamp(mg, w - mg));
      y = y.clamp(mg, (h - mg - safeBh).clamp(mg, h - mg));
    }

    return {
      't': type, 'x': x, 'y': y,
      'font': safeFont,
      'xs':  (m['xs']  as num?)?.toInt().clamp(1, 4) ?? 1,
      'ys':  (m['ys']  as num?)?.toInt().clamp(1, 4) ?? 1,
      'rot': (m['rot'] as num?)?.toInt() ?? 0,
      'text':  m['text']?.toString()  ?? '',
      'pre':   m['pre']?.toString()   ?? '',
      'suf':   m['suf']?.toString()   ?? '',
      'data':  m['data']?.toString()  ?? '',
      'btype': m['btype']?.toString() ?? '128',
      'bh': safeBh, 'bw': safeBw,
      'ecc': m['ecc']?.toString() ?? 'M',
      'qs':  safeQs,
      'xe': (m['xe'] as num?)?.toInt().clamp(x, w - mg) ?? (w - mg),
      'ye': (m['ye'] as num?)?.toInt().clamp(y, h - mg) ?? (h - mg),
      'th': (m['th'] as num?)?.toInt().clamp(1, 10) ?? 2,
      'logo_path':  m['logo_path']?.toString()  ?? '',
      'logo_bmp':   m['logo_bmp']?.toString()   ?? '',
      'logo_bmpw':  (m['logo_bmpw'] as num?)?.toInt() ?? 0,
      'logo_w':     (m['logo_w'] as num?)?.toInt() ?? 80,
      'logo_h':     (m['logo_h'] as num?)?.toInt() ?? 48,
      'dec':  (m['dec']  as num?)?.toInt() ?? 3,
      'unit': m['unit']?.toString() ?? 'g',
    };
  }
}

// ── Data class ────────────────────────────────────────────────────────────────
class _Line {
  final String type, text, pre, suf;
  final int wt;
  const _Line(this.type, this.text, this.pre, this.suf, [this.wt = 0]);
}

enum AiSource { claude, ruleBased, ruleBasedFallback }

class AiResult {
  final List<Map<String, dynamic>> elements;
  final AiSource source;
  final String?  error;
  AiResult({required this.elements, required this.source, this.error});

  String get sourceLabel => switch (source) {
    AiSource.claude            => 'Claude AI',
    AiSource.ruleBased         => 'Built-in pattern (offline)',
    AiSource.ruleBasedFallback => 'Built-in pattern (AI failed)',
  };
}
