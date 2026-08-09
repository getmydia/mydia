import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_summary.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/connection_tone_color.dart';

void main() {
  test('each tone maps to its semantic colour', () {
    expect(connectionToneColor(ConnectionTone.good), AppColors.success);
    expect(connectionToneColor(ConnectionTone.caution), AppColors.warning);
    expect(connectionToneColor(ConnectionTone.pending), AppColors.info);
  });

  test('no tone maps to a raw Material colour', () {
    for (final tone in ConnectionTone.values) {
      expect(
        connectionToneColor(tone),
        anyOf(AppColors.success, AppColors.warning, AppColors.info),
      );
    }
  });
}
