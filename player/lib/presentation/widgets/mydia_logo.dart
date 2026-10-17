import 'package:flutter/material.dart';

import '../../core/theme/palette.dart';

/// Mydia squircle logo painted via CustomPainter.
class MydiaLogo extends StatelessWidget {
  final double size;

  const MydiaLogo({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return CustomPaint(
      size: Size(size, size),
      painter: MydiaLogoPainter(
        markColor: palette.textPrimary,
        cutoutColor: palette.background,
      ),
    );
  }
}

class MydiaLogoPainter extends CustomPainter {
  const MydiaLogoPainter({required this.markColor, required this.cutoutColor});

  /// The mark's fill. Deliberately neutral rather than the palette's primary:
  /// the app icon and the Phoenix logo this mirrors are a fixed blue that the
  /// player's palette does not own, so a mark that tracked the accent would
  /// drift away from them on every repalette. Callers pass the palette's
  /// `textPrimary`.
  final Color markColor;

  /// The inner cut-out, which reads as a hole through to the shell behind it.
  /// Callers pass the palette's `background`.
  final Color cutoutColor;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width; // square
    final scale = s / 48.0; // SVG viewBox is 48x48

    // Outer squircle – mark fill
    final outerRect = RRect.fromLTRBR(
      1 * scale,
      1 * scale,
      47 * scale,
      47 * scale,
      Radius.circular(10 * scale),
    );
    canvas.drawRRect(outerRect, Paint()..color = markColor);

    // Inner squircle – background fill
    final innerRect = RRect.fromLTRBR(
      5 * scale,
      5 * scale,
      43 * scale,
      43 * scale,
      Radius.circular(7 * scale),
    );
    canvas.drawRRect(innerRect, Paint()..color = cutoutColor);

    // M letterform
    final mPath = Path()
      ..moveTo(12 * scale, 34 * scale)
      ..lineTo(12 * scale, 14 * scale)
      ..lineTo(18 * scale, 14 * scale)
      ..lineTo(24 * scale, 24 * scale)
      ..lineTo(30 * scale, 14 * scale)
      ..lineTo(36 * scale, 14 * scale)
      ..lineTo(36 * scale, 34 * scale)
      ..lineTo(31 * scale, 34 * scale)
      ..lineTo(31 * scale, 22 * scale)
      ..lineTo(25.5 * scale, 31 * scale)
      ..lineTo(22.5 * scale, 31 * scale)
      ..lineTo(17 * scale, 22 * scale)
      ..lineTo(17 * scale, 34 * scale)
      ..close();
    canvas.drawPath(mPath, Paint()..color = markColor);
  }

  @override
  bool shouldRepaint(covariant MydiaLogoPainter oldDelegate) =>
      oldDelegate.markColor != markColor ||
      oldDelegate.cutoutColor != cutoutColor;
}
