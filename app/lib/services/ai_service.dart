import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// AI-driven label-template generator.
///
/// Given a natural-language description ("gold ring 22K with weight, serial and
/// QR") and the label dimensions, returns a list of compact element maps that
/// match the shape stored in the templates table (see DbService).
///
/// Two backends:
///   * Claude — calls api.anthropic.com if an API key is configured.
///   * Rule-based — a tiny library of jewellery-label patterns that works
///     offline. Used as a fallback or when no key is set.
class AiService {
  static const _kKeyPref = 'ANTHROPIC_API_KEY';
  static const _kModel   = 'claude-haiku-4-5-20251001';  // cheap + fast for JSON
  static const _endpoint = 'https://api.anthropic.com/v1/messages';

  // ---- key management ----
  Future<String?> getKey() async =>
      (await SharedPreferences.getInstance()).getString(_kKeyPref);

  Future<void> setKey(String key) async =>
      (await SharedPreferences.getInstance()).setString(_kKeyPref, key.trim());

  Future<void> clearKey() async =>
      (await SharedPreferences.getInstance()).remove(_kKeyPref);

  Future<bool> get hasKey async => (await getKey())?.isNotEmpty == true;

  // ============================================================
  // Public entry point
  // ============================================================
  /// Returns a list of element-maps ready to drop into DbService.saveTemplate's
  /// `json` field. Tries Claude first if a key is configured and we're online;
  /// falls back to a rule-based generator otherwise.
  Future<AiResult> generate({
    required String prompt,
    required int widthMm,
    required int heightMm,
  }) async {
    final key = await getKey();
    if (key != null && key.isNotEmpty) {
      try {
        final elements = await _callClaude(prompt, widthMm, heightMm, key);
        return AiResult(elements: elements, source: AiSource.claude);
      } catch (e) {
        debugPrint('Claude generate failed, falling back: $e');
        final elements = _ruleBased(prompt, widthMm, heightMm);
        return AiResult(
          elements: elements,
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

  // ============================================================
  // Claude integration
  // ============================================================
  Future<List<Map<String, dynamic>>> _callClaude(
      String userPrompt, int wMm, int hMm, String apiKey) async {
    final wDots = wMm * 8;
    final hDots = hMm * 8;

    final system = _systemPrompt(wMm, hMm, wDots, hDots);

    final body = jsonEncode({
      'model': _kModel,
      'max_tokens': 2048,
      'system': system,
      'messages': [
        {'role': 'user', 'content': userPrompt},
      ],
    });

    final resp = await http
        .post(
          Uri.parse(_endpoint),
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 30));

    if (resp.statusCode != 200) {
      throw HttpException(
          'Claude API ${resp.statusCode}: ${resp.body.substring(0, resp.body.length.clamp(0, 200))}');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final content = (decoded['content'] as List).first as Map<String, dynamic>;
    final text    = content['text'] as String;

    // Extract the JSON array — Claude sometimes wraps it in ```json ... ```
    final jsonStr = _extractJsonArray(text);
    final list = jsonDecode(jsonStr) as List;

    // Validate + clamp coordinates inside label bounds, then return.
    return list
        .whereType<Map>()
        .map<Map<String, dynamic>>((m) =>
            _validateElement(m.cast<String, dynamic>(), wDots, hDots))
        .toList();
  }

  String _systemPrompt(int wMm, int hMm, int wDots, int hDots) => '''
You are a label-template designer for jewellery shop tags printed on a TSC TTP-244 Pro thermal printer (203 dpi, 8 dots per mm).

The label is $wMm mm × $hMm mm  =  $wDots × $hDots dots.

Output a single JSON array of element objects. NO prose, NO markdown — just the array.

Each element is one of these shapes:

  Text:       {"t":"text","x":int,"y":int,"font":"3","xs":1,"ys":1,"rot":0,"text":"...","pre":"","suf":""}
  Weight:     {"t":"weight","x":int,"y":int,"font":"3","xs":1,"ys":1,"pre":"Net: ","suf":" g"}
  Serial:     {"t":"serial","x":int,"y":int,"font":"3","xs":1,"ys":1,"pre":"SN: "}
  Date/Time:  {"t":"dateTime","x":int,"y":int,"font":"2","xs":1,"ys":1}
  QR code:    {"t":"qr","x":int,"y":int,"qs":4,"ecc":"M","data":"{serial}|{net}"}
  Barcode:    {"t":"bar","x":int,"y":int,"btype":"128","bh":60,"data":"{serial}"}
  Box/line:   {"t":"box","x":int,"y":int,"xe":int,"ye":int,"th":2}
  Logo:       {"t":"logo","x":int,"y":int,"logo":"LOGO.BMP"}

Coordinates: x is left, y is top, in dots (8 dots = 1 mm). Origin is top-left.
Keep every element fully inside 0 ≤ x ≤ $wDots and 0 ≤ y ≤ $hDots.

Font sizes (TSPL built-in):
  "1" ≈ 8 dots tall   (use for tiny captions only)
  "2" ≈ 12 dots tall  (small labels)
  "3" ≈ 20 dots tall  (default body)
  "4" ≈ 24 dots tall  (headings)
  "5" ≈ 32 dots tall  (large weight display)
  Use xs/ys (1-4) to scale further.

Placeholders you can use inside any "text" or "data" string:
  {net} {gross} {tare} {serial} {date} {time} {product} {purity} {rate} {amount}

Good design rules:
  * Leave a 16-dot (2 mm) margin around the edges.
  * Heading text near the top, weight/serial in the middle, barcode/QR near edges.
  * For 50×25 mm labels, prefer 3-5 elements. For larger labels you can use more.
  * Use {net} weight as a featured large element for jewellery.
  * Include {serial} either as text or inside a QR/barcode for inventory tracking.

Respond with ONLY the JSON array. Start with [ and end with ]. No code fences.
''';

  String _extractJsonArray(String s) {
    final start = s.indexOf('[');
    final end   = s.lastIndexOf(']');
    if (start < 0 || end < 0 || end <= start) {
      throw const FormatException('Claude did not return a JSON array');
    }
    return s.substring(start, end + 1);
  }

  Map<String, dynamic> _validateElement(
      Map<String, dynamic> m, int wDots, int hDots) {
    final out = <String, dynamic>{
      't': m['t'] ?? 'text',
      'x': (m['x'] as num?)?.clamp(0, wDots - 8).toInt() ?? 16,
      'y': (m['y'] as num?)?.clamp(0, hDots - 8).toInt() ?? 16,
      'font': m['font']?.toString() ?? '3',
      'xs':  (m['xs']  as num?)?.toInt() ?? 1,
      'ys':  (m['ys']  as num?)?.toInt() ?? 1,
      'rot': (m['rot'] as num?)?.toInt() ?? 0,
      'text': m['text']?.toString() ?? '',
      'data': m['data']?.toString() ?? '',
      'btype': m['btype']?.toString() ?? '128',
      'bh':    (m['bh'] as num?)?.toInt() ?? 60,
      'ecc':   m['ecc']?.toString() ?? 'M',
      'qs':    (m['qs'] as num?)?.toInt() ?? 4,
      'xe':    (m['xe'] as num?)?.clamp(0, wDots).toInt() ?? wDots - 16,
      'ye':    (m['ye'] as num?)?.clamp(0, hDots).toInt() ?? hDots - 16,
      'th':    (m['th'] as num?)?.toInt() ?? 2,
      'logo':  m['logo']?.toString() ?? 'LOGO.BMP',
      'pre':   m['pre']?.toString() ?? '',
      'suf':   m['suf']?.toString() ?? '',
      'dec':   (m['dec'] as num?)?.toInt() ?? 3,
      'unit':  m['unit']?.toString() ?? 'g',
    };
    return out;
  }

  // ============================================================
  // Rule-based fallback — works offline, free.
  //
  // Picks a pattern by sniffing keywords in the user prompt and adapts it
  // to the requested label size. Pattern coordinates are computed from the
  // label dimensions so it always fits.
  // ============================================================
  List<Map<String, dynamic>> _ruleBased(String prompt, int wMm, int hMm) {
    final p = prompt.toLowerCase();
    final wDots = wMm * 8;
    final hDots = hMm * 8;

    // Pick a pattern.
    if (p.contains('coin')   || p.contains('biscuit')) return _patternCoin(wDots, hDots);
    if (p.contains('chain'))                           return _patternChain(wDots, hDots);
    if (p.contains('bangle') || p.contains('kada'))    return _patternBangle(wDots, hDots);
    if (p.contains('bar')    || p.contains('bullion')) return _patternBar(wDots, hDots);
    // Default: a balanced "ring" / generic jewellery label.
    return _patternRing(wDots, hDots);
  }

  // Helper: build a text element.
  Map<String, dynamic> _t({
    required int x, required int y, required String text,
    String font = '3', int xs = 1, int ys = 1, String type = 'text',
    String pre = '', String suf = '',
  }) => {
        't': type, 'x': x, 'y': y, 'font': font,
        'xs': xs, 'ys': ys, 'rot': 0, 'text': text,
        'pre': pre, 'suf': suf,
      };

  Map<String, dynamic> _qr({required int x, required int y, int qs = 3,
      String data = '{serial}|{net}'}) =>
      {'t': 'qr', 'x': x, 'y': y, 'qs': qs, 'ecc': 'M', 'data': data, 'rot': 0};

  Map<String, dynamic> _bar({required int x, required int y, int bh = 50,
      String data = '{serial}', String btype = '128'}) =>
      {'t': 'bar', 'x': x, 'y': y, 'btype': btype, 'bh': bh, 'data': data, 'rot': 0};

  List<Map<String, dynamic>> _patternRing(int w, int h) {
    final pad = 16;
    return [
      _t(x: pad, y: pad,                  text: '{product} {purity}', font: '4'),
      _t(x: pad, y: pad + 32,             text: '', type: 'weight',
         pre: 'Net: ', suf: ' g',                                font: '5'),
      _t(x: pad, y: h ~/ 2 + 30,          text: '', type: 'serial',
         pre: 'SN: ',                                            font: '3'),
      _t(x: pad, y: h - 30,               text: '', type: 'dateTime',  font: '2'),
      _qr(x: w - 80, y: pad, qs: 3),
    ];
  }

  List<Map<String, dynamic>> _patternCoin(int w, int h) {
    final pad = 16;
    return [
      _t(x: w ~/ 2 - 60, y: pad,         text: 'PURE COIN',           font: '4', xs: 1, ys: 1),
      _t(x: pad, y: pad + 36,            text: '', type: 'weight',
         pre: 'Wt: ', suf: ' g',                                 font: '5', xs: 1, ys: 1),
      _t(x: pad, y: h - 60,              text: '', type: 'serial',
         pre: 'SN: ',                                            font: '3'),
      _bar(x: pad, y: h - 36, bh: 30),
    ];
  }

  List<Map<String, dynamic>> _patternChain(int w, int h) {
    final pad = 16;
    return [
      _t(x: pad, y: pad,                 text: 'Chain {purity}',      font: '4'),
      _t(x: pad, y: pad + 30,            text: '', type: 'weight',
         pre: 'Gross: ', suf: ' g',                               font: '3'),
      _t(x: pad, y: pad + 60,            text: '', type: 'weight',
         pre: 'Net: ',   suf: ' g',                               font: '5'),
      _t(x: pad, y: h - 40,              text: '', type: 'serial',    font: '3', pre: 'SN '),
      _qr(x: w - 80, y: h ~/ 2 - 30, qs: 3),
    ];
  }

  List<Map<String, dynamic>> _patternBangle(int w, int h) {
    final pad = 16;
    return [
      _t(x: pad, y: pad,                 text: 'Bangle {purity}',     font: '4'),
      _t(x: pad, y: pad + 30,            text: '', type: 'weight',
         pre: 'Net: ', suf: ' g',                                 font: '5'),
      _t(x: pad, y: h - 56,              text: '', type: 'serial',    font: '3'),
      _t(x: pad, y: h - 28,              text: '', type: 'dateTime',  font: '2'),
      _qr(x: w - 80, y: pad, qs: 3),
    ];
  }

  List<Map<String, dynamic>> _patternBar(int w, int h) {
    final pad = 16;
    return [
      _t(x: w ~/ 2 - 80, y: pad,         text: 'FINE GOLD 999', font: '5'),
      _t(x: pad, y: pad + 50,            text: '', type: 'weight',
         pre: 'Weight: ', suf: ' g',                              font: '5', xs: 1, ys: 1),
      _t(x: pad, y: pad + 100,           text: '', type: 'serial',
         pre: 'Serial: ',                                         font: '3'),
      _bar(x: pad, y: h - 60, bh: 40),
      _t(x: pad, y: h - 20,              text: '', type: 'dateTime',  font: '2'),
    ];
  }
}

enum AiSource { claude, ruleBased, ruleBasedFallback }

class AiResult {
  final List<Map<String, dynamic>> elements;
  final AiSource source;
  final String?  error;
  AiResult({required this.elements, required this.source, this.error});

  String get sourceLabel => switch (source) {
        AiSource.claude              => 'Claude AI',
        AiSource.ruleBased           => 'Built-in pattern (offline)',
        AiSource.ruleBasedFallback   => 'Built-in pattern (AI failed)',
      };
}
