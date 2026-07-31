// The sidebar mark is painted in code, so it silently follows whatever
// AppColors.primary happens to be. That is wrong: the app icon and the
// Phoenix logo it mirrors are a fixed blue that the player's palette does not
// control, so a mark that tracks the accent drifts away from them on every
// repalette. It renders neutral instead, clashing with neither.

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/app_shell.dart';

/// Records the colour of each paint operation so tests can assert on what
/// `paint()` actually draws, not merely on the constants it declares.
class _RecordingCanvas implements Canvas {
  final List<Color> colors = <Color>[];

  @override
  void drawRRect(RRect rrect, Paint paint) => colors.add(paint.color);

  @override
  void drawPath(Path path, Paint paint) => colors.add(paint.color);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('MydiaLogoPainter', () {
    test('does not follow the accent', () {
      expect(MydiaLogoPainter.markColor, isNot(AppColors.primary));
      expect(MydiaLogoPainter.markColor, isNot(AppColors.primaryFocus));
    });

    test('is neutral — no colour cast in any direction', () {
      final c = MydiaLogoPainter.markColor;
      const tolerance = 6 / 255;
      expect((c.r - c.g).abs(), lessThanOrEqualTo(tolerance));
      expect((c.g - c.b).abs(), lessThanOrEqualTo(tolerance));
      expect((c.r - c.b).abs(), lessThanOrEqualTo(tolerance));
    });

    test('cuts out against the app background', () {
      expect(MydiaLogoPainter.cutoutColor, AppColors.background);
    });

    test('paints only neutral colours, never the accent', () {
      // Paint.color round-trips through a Float32 native buffer (see
      // paint.cc / dart:ui's Paint._data), so a Color read back from
      // paint.color is not bit-identical to the Color literal that was
      // assigned — comparing the Color objects directly is flaky even when
      // the painter is correct. toARGB32() quantizes back to the 8-bit
      // channel values our palette is actually defined in, which survives
      // that round trip losslessly and is what the eye perceives as equal.
      final canvas = _RecordingCanvas();
      const MydiaLogoPainter().paint(canvas, const Size(48, 48));

      expect(canvas.colors, isNotEmpty,
          reason: 'paint() drew nothing, so this test proves nothing');
      final drawnArgb = canvas.colors.map((c) => c.toARGB32()).toSet();
      expect(drawnArgb, isNot(contains(AppColors.primary.toARGB32())));
      expect(drawnArgb, isNot(contains(AppColors.primaryFocus.toARGB32())));
      expect(
        drawnArgb,
        <int>{
          MydiaLogoPainter.markColor.toARGB32(),
          MydiaLogoPainter.cutoutColor.toARGB32(),
        },
        reason: 'paint() must draw only the declared mark and cutout colours',
      );
    });
  });
}
