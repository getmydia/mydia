import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    LiquidGlassSupport.debugPlatformOverride = null;
    LiquidGlassSupport.debugOverride = null;
    LiquidGlassSupport.debugReset();
    debugDefaultTargetPlatformOverride = null;
  });

  test('iOS and macOS are eligible, other platforms are not', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final expected =
          platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
      expect(LiquidGlassSupport.platformEligible, expected,
          reason: '$platform');
    }
  });

  test('not available before initialize, even on an eligible platform', () {
    LiquidGlassSupport.debugPlatformOverride = true;
    expect(LiquidGlassSupport.available, isFalse);
    expect(LiquidGlassSupport.program, isNull);
  });

  test('initialize on an ineligible platform loads nothing', () async {
    LiquidGlassSupport.debugPlatformOverride = false;
    await LiquidGlassSupport.initialize();
    expect(LiquidGlassSupport.available, isFalse);
  });

  test('initialize without shader filter support falls back, never throws',
      () async {
    // flutter test runs without Impeller, so shader filters are unsupported.
    LiquidGlassSupport.debugPlatformOverride = true;
    await LiquidGlassSupport.initialize();
    expect(LiquidGlassSupport.available, isFalse);
  });

  test('debugOverride forces availability', () {
    LiquidGlassSupport.debugOverride = true;
    expect(LiquidGlassSupport.available, isTrue);
  });
}
