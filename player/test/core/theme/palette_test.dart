import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/contrast.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_preset.dart';

void main() {
  group('Projection Booth', () {
    test('is exactly the pre-preset palette', () {
      const p = Palettes.projectionBooth;
      expect(p.background, const Color(0xFF0B0B0C));
      expect(p.surfaceDim, const Color(0xFF0E0E10));
      expect(p.surfaceLow, const Color(0xFF111113));
      expect(p.surface, const Color(0xFF141416));
      expect(p.surfaceHigh, const Color(0xFF191A1D));
      expect(p.surfaceVariant, const Color(0xFF1E1E21));
      expect(p.surfaceBright, const Color(0xFF26272B));
      expect(p.primary, const Color(0xFFE9A23B));
      expect(p.primaryFocus, const Color(0xFFD08C24));
      expect(p.onPrimary, const Color(0xFF1A1205));
      expect(p.textPrimary, const Color(0xFFF0EFED));
      expect(p.textSecondary, const Color(0xFF9A9894));
      expect(p.textDisabled, const Color(0xFF7A7975));
      expect(p.divider, const Color(0xFF1D1D21));
      expect(p.border, const Color(0xFF2E2E33));
      expect(p.cardHover, const Color(0xFF26272B));
      expect(p.shimmerBase, const Color(0xFF1A1A1D));
      expect(p.shimmerHighlight, const Color(0xFF26272B));
      expect(p.ambientTint, isTrue);
    });
  });

  test('OLED Black has a pure black ground and no ambient tint', () {
    expect(Palettes.oledBlack.background, const Color(0xFF000000));
    expect(Palettes.oledBlack.ambientTint, isFalse);
  });

  group('macOS', () {
    test('takes the accent it is given', () {
      final p = Palettes.macos(const Color(0xFFBF5AF2));
      expect(p.primary, const Color(0xFFBF5AF2));
      expect(p.ambientTint, isFalse);
    });

    test('on-primary is whichever of black or white contrasts more', () {
      expect(onColorFor(const Color(0xFFFFD60A)), const Color(0xFF000000));
      expect(onColorFor(const Color(0xFF1A1A6A)), const Color(0xFFFFFFFF));
      final p = Palettes.macos(Palettes.macosDefaultAccent);
      expect(p.onPrimary, onColorFor(Palettes.macosDefaultAccent));
    });
  });

  for (final preset in ThemePreset.values) {
    test('${preset.name} surface tones rise in luminance', () {
      final tones = preset.palette().surfaceTones;
      expect(tones, hasLength(7));
      for (var i = 1; i < tones.length; i++) {
        expect(
          relativeLuminance(tones[i]),
          greaterThan(relativeLuminance(tones[i - 1])),
          reason: '${preset.name} tone $i',
        );
      }
    });
  }

  group('ThemePreset availability', () {
    test('macOS is offered only on native macOS', () {
      expect(
          ThemePreset.macos.isAvailableOn(TargetPlatform.macOS, isWeb: false),
          isTrue);
      expect(ThemePreset.macos.isAvailableOn(TargetPlatform.macOS, isWeb: true),
          isFalse);
      expect(
          ThemePreset.macos.isAvailableOn(TargetPlatform.android, isWeb: false),
          isFalse);
      expect(ThemePreset.availableOn(TargetPlatform.linux, isWeb: false), [
        ThemePreset.projectionBooth,
        ThemePreset.oledBlack,
        ThemePreset.slate
      ]);
    });

    test('defaults to macOS on native macOS, Projection Booth elsewhere', () {
      expect(ThemePreset.defaultFor(TargetPlatform.macOS, isWeb: false),
          ThemePreset.macos);
      expect(ThemePreset.defaultFor(TargetPlatform.macOS, isWeb: true),
          ThemePreset.projectionBooth);
      expect(ThemePreset.defaultFor(TargetPlatform.android, isWeb: false),
          ThemePreset.projectionBooth);
    });

    test('resolve falls back for unset, unknown and unavailable values', () {
      expect(ThemePreset.resolve(null, TargetPlatform.macOS, isWeb: false),
          ThemePreset.macos);
      expect(ThemePreset.resolve('bogus', TargetPlatform.linux, isWeb: false),
          ThemePreset.projectionBooth);
      expect(ThemePreset.resolve('macos', TargetPlatform.android, isWeb: false),
          ThemePreset.projectionBooth);
      expect(ThemePreset.resolve('slate', TargetPlatform.android, isWeb: false),
          ThemePreset.slate);
    });
  });

  testWidgets('context.palette falls back to Projection Booth', (tester) async {
    late MydiaPalette seen;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        seen = context.palette;
        return const SizedBox();
      }),
    ));
    expect(seen, same(Palettes.projectionBooth));
  });

  test('lerp blends every colour', () {
    final mid = Palettes.projectionBooth.lerp(Palettes.oledBlack, 0.5);
    expect(
      mid.background,
      Color.lerp(const Color(0xFF0B0B0C), const Color(0xFF000000), 0.5),
    );
  });
}
