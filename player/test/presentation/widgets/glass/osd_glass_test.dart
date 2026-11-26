import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/osd_glass.dart';

OsdGlassMode _resolve({
  bool liquidStyle = true,
  bool isWeb = false,
  TargetPlatform platform = TargetPlatform.iOS,
  bool reduceTransparency = false,
  bool shaderAvailable = true,
  bool surfaceOutput = false,
}) => resolveOsdGlassMode(
  liquidStyle: liquidStyle,
  isWeb: isWeb,
  platform: platform,
  reduceTransparency: reduceTransparency,
  shaderAvailable: shaderAvailable,
  surfaceOutput: surfaceOutput,
);

void main() {
  group('resolveOsdGlassMode', () {
    test('iOS with the shader is sampled', () {
      expect(_resolve(), OsdGlassMode.sampled);
    });

    test('macOS without surface output is sampled', () {
      expect(_resolve(platform: TargetPlatform.macOS), OsdGlassMode.sampled);
    });

    test('macOS with surface output is dry', () {
      expect(
        _resolve(platform: TargetPlatform.macOS, surfaceOutput: true),
        OsdGlassMode.dry,
      );
    });

    test('iOS ignores surface output', () {
      expect(_resolve(surfaceOutput: true), OsdGlassMode.sampled);
    });

    test('no shader is dry on iOS and macOS', () {
      for (final p in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        expect(_resolve(platform: p, shaderAvailable: false), OsdGlassMode.dry);
      }
    });

    test('non-liquid style is off', () {
      expect(_resolve(liquidStyle: false), OsdGlassMode.off);
    });

    test('reduce transparency is off', () {
      expect(_resolve(reduceTransparency: true), OsdGlassMode.off);
    });

    test('web is off on any platform', () {
      for (final p in TargetPlatform.values) {
        expect(_resolve(isWeb: true, platform: p), OsdGlassMode.off);
      }
    });

    test('other platforms are off', () {
      for (final p in [
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(_resolve(platform: p), OsdGlassMode.off);
      }
    });
  });

  group('OsdGlass.of', () {
    Future<OsdGlassMode> read(WidgetTester tester, Widget? scopeWrap) async {
      late OsdGlassMode mode;
      Widget probe = Builder(
        builder: (context) {
          mode = OsdGlass.of(context);
          return const SizedBox();
        },
      );
      if (scopeWrap != null) {
        probe = OsdGlassScope(surfaceOutput: true, child: probe);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
          home: probe,
        ),
      );
      return mode;
    }

    testWidgets('reads the scope, defaulting to no surface output', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      LiquidGlassSupport.debugOverride = true;
      addTearDown(() => LiquidGlassSupport.debugOverride = null);
      expect(await read(tester, const SizedBox()), OsdGlassMode.dry);
      expect(await read(tester, null), OsdGlassMode.sampled);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  test('VideoSurfaceOutputNotifier claim after disposal does not throw', () {
    final container = ProviderContainer();
    final notifier = container.read(videoSurfaceOutputProvider.notifier);
    container.dispose();
    expect(() => notifier.claim(Object()), returnsNormally);
    expect(() => notifier.release(Object()), returnsNormally);
  });

  test('videoSurfaceOutputProvider starts false and follows a claim', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final owner = Object();
    expect(container.read(videoSurfaceOutputProvider), isFalse);
    container.read(videoSurfaceOutputProvider.notifier).claim(owner);
    expect(container.read(videoSurfaceOutputProvider), isTrue);
    container.read(videoSurfaceOutputProvider.notifier).release(owner);
    expect(container.read(videoSurfaceOutputProvider), isFalse);
  });

  test('overlapping owners keep the flag until the last one releases', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(videoSurfaceOutputProvider.notifier);
    final a = Object();
    final b = Object();
    notifier.claim(a);
    notifier.claim(b);
    notifier.release(a);
    expect(container.read(videoSurfaceOutputProvider), isTrue);
    notifier.release(b);
    expect(container.read(videoSurfaceOutputProvider), isFalse);
  });

  test('an outgoing owner installing late then disposing keeps the incoming '
      "owner's claim", () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(videoSurfaceOutputProvider.notifier);
    final incoming = Object();
    final outgoing = Object();
    notifier.claim(incoming);
    notifier.claim(outgoing);
    notifier.release(outgoing);
    expect(container.read(videoSurfaceOutputProvider), isTrue);
    // A repeated release of an already-retracted claim changes nothing.
    notifier.release(outgoing);
    expect(container.read(videoSurfaceOutputProvider), isTrue);
  });
}
