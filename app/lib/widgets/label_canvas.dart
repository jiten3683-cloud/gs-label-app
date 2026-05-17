import 'dart:io';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

// TSPL font heights in dots at 203 DPI (8 dots = 1 mm)
const kFontDotH = {
  '1': 12, '2': 20, '3': 24, '4': 32, '5': 48,
  '6': 19, '7': 27, '8': 21,
};

Barcode barcodeForType(String t) => switch (t) {
  '39'    => Barcode.code39(),
  'EAN13' => Barcode.ean13(),
  'EAN8'  => Barcode.ean8(),
  'UPC'   => Barcode.upcA(),
  _       => Barcode.code128(),
};

int qrEccLevel(String e) => switch (e) {
  'L' => QrErrorCorrectLevel.L,
  'Q' => QrErrorCorrectLevel.Q,
  'H' => QrErrorCorrectLevel.H,
  _   => QrErrorCorrectLevel.M,
};

/// Renders a list of resolved TSPL element maps as a visual label on white background.
/// Use [LabelCanvas.renderEl] to render a single element at a given scale.
class LabelCanvas extends StatelessWidget {
  final List<Map<String, dynamic>> elements;
  final int wMm, hMm;
  const LabelCanvas({
    super.key, required this.elements, required this.wMm, required this.hMm,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final maxW  = (constraints.maxWidth - 4).clamp(80.0, 800.0);
      final scale = maxW / (wMm * 8.0);
      final cH    = (hMm * 8.0 * scale).clamp(24.0, 600.0);

      return Container(
        width: maxW, height: cH,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black87, width: 1.5),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: elements.map((el) {
            final x = ((el['x'] as num? ?? 0) * scale).toDouble();
            final y = ((el['y'] as num? ?? 0) * scale).toDouble();
            return Positioned(left: x, top: y, child: renderEl(el, scale));
          }).toList(),
        ),
      );
    });
  }

  /// Renders a single element map at the given canvas scale.
  /// Public so that other widgets (e.g. WYSIWYG element previews) can reuse it.
  static Widget renderEl(Map<String, dynamic> el, double scale) {
    final type = el['type'] as String? ?? '';
    switch (type) {
      case 'text':
        final font = el['font'] as String? ?? '3';
        final ys   = (el['ys'] as num? ?? 1).toInt();
        final text = el['text'] as String? ?? '';
        final dotH = (kFontDotH[font] ?? 24).toDouble();
        final fs   = (dotH * ys * scale).clamp(4.0, 100.0);
        return Text(
          text.isEmpty ? ' ' : text,
          style: TextStyle(fontSize: fs, color: Colors.black,
              fontFamily: 'monospace', height: 1.1),
        );

      case 'qr':
        final data = (el['data'] as String? ?? '').isEmpty
            ? 'SAMPLE' : el['data'] as String;
        // qrSize is cell-width in dots; typical QR ≈25 modules → physical size = qrSize*25 dots
        final sz = ((el['size'] as num? ?? 4) * 25.0 * scale).clamp(16.0, 300.0);
        try {
          return SizedBox(width: sz, height: sz, child: QrImageView(
            data: data, version: QrVersions.auto, size: sz,
            errorCorrectionLevel: qrEccLevel(el['ecc'] as String? ?? 'M'),
            errorStateBuilder: (_, __) => Container(
              color: Colors.black12,
              child: const Icon(Icons.qr_code, size: 20),
            ),
          ));
        } catch (_) {
          return SizedBox(width: sz, height: sz,
              child: const Icon(Icons.qr_code_2, color: Colors.black54));
        }

      case 'bar':
        final data = (el['data'] as String? ?? '').isEmpty
            ? '1234567890' : el['data'] as String;
        final bw = ((el['bw'] as num? ?? 120) * scale).clamp(20.0, 500.0);
        final bh = ((el['height'] as num? ?? 60) * scale).clamp(8.0, 200.0);
        try {
          return BarcodeWidget(
            barcode: barcodeForType(el['btype'] as String? ?? '128'),
            data: data, width: bw, height: bh,
            drawText: false, color: Colors.black,
          );
        } catch (_) {
          return Container(width: bw, height: bh, color: Colors.black12,
              child: const Center(child: Text('BARCODE',
                  style: TextStyle(fontSize: 9))));
        }

      case 'box':
        final x0 = (el['x']  as num? ?? 0).toDouble();
        final y0 = (el['y']  as num? ?? 0).toDouble();
        final xe = (el['xe'] as num? ?? 100).toDouble();
        final ye = (el['ye'] as num? ?? 50).toDouble();
        final t  = (el['t']  as num? ?? 2).toDouble();
        final w  = ((xe - x0) * scale).abs().clamp(4.0, 800.0);
        final h  = ((ye - y0) * scale).abs().clamp(4.0, 800.0);
        return Container(width: w, height: h,
            decoration: BoxDecoration(
                border: Border.all(
                    width: (t * scale).clamp(0.5, 6.0), color: Colors.black)));

      case 'logo':
        final lw = ((el['lw'] as num? ?? 80) * scale).clamp(8.0, 600.0);
        final lh = ((el['lh'] as num? ?? 48) * scale).clamp(8.0, 400.0);
        final path = el['path'] as String? ?? '';
        if (path.isNotEmpty) {
          final f = File(path);
          if (f.existsSync()) {
            return SizedBox(width: lw, height: lh,
                child: Image.file(f, width: lw, height: lh, fit: BoxFit.fill));
          }
        }
        return Container(
          width: lw, height: lh,
          decoration: BoxDecoration(
              color: Colors.amber.shade50, border: Border.all(color: Colors.amber)),
          child: const Center(child: Icon(Icons.image, size: 16, color: Colors.amber)),
        );

      default:
        return const SizedBox.shrink();
    }
  }
}