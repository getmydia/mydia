import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    LiquidGlassSupport.debugOverride = null;
    LiquidGlassSupport.debugReset();
  });

  test('not available before initialize', () {
    expect(LiquidGlassSupport.available, isFalse);
    expect(LiquidGlassSupport.program, isNull);
  });

  test('initialize without shader filter support falls back, never throws',
      () async {
    // flutter test runs without Impeller, so shader filters are unsupported.
    await LiquidGlassSupport.initialize();
    expect(LiquidGlassSupport.available, isFalse);
  });

  test('debugOverride forces availability', () {
    LiquidGlassSupport.debugOverride = true;
    expect(LiquidGlassSupport.available, isTrue);
  });
}
