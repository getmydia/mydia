// The sidebar mark is painted in code, so it silently follows whatever
// AppColors.primary happens to be. That is wrong: the app icon and the
// Phoenix logo it mirrors are a fixed blue that the player's palette does not
// control, so a mark that tracks the accent drifts away from them on every
// repalette. It renders neutral instead, clashing with neither.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/app_shell.dart';

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
  });
}
