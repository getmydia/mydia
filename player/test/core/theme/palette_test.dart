import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:player/core/theme/contrast.dart';
import 'package:player/core/theme/linux_desktop.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_preset.dart';

import '../../test_utils/linux_accents.dart';
import '../../test_utils/mac_accents.dart';

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
    test('has no ambient tint', () {
      expect(Palettes.macos(const Color(0xFFBF5AF2)).ambientTint, isFalse);
    });

    test('accents that are already legible come through unchanged', () {
      for (final name in ['yellow', 'green']) {
        final accent = macAccents[name]!;
        expect(Palettes.macos(accent).primary, accent, reason: name);
      }
    });

    test('a failing accent is lifted and keeps its hue', () {
      final blue = macAccents['blue']!;
      final lifted = Palettes.macos(blue).primary;
      expect(lifted, isNot(blue));
      expect(
        contrastRatio(lifted, Palettes.macos(blue).background),
        greaterThanOrEqualTo(4.5),
      );
      final before = Hct.fromInt(blue.toARGB32());
      final after = Hct.fromInt(lifted.toARGB32());
      expect(after.tone, greaterThan(before.tone));
      final drift = (after.hue - before.hue).abs();
      expect(math.min(drift, 360 - drift), lessThan(1.0));
    });

    test('on-primary and focus derive from the lifted accent', () {
      final p = Palettes.macos(Palettes.macosDefaultAccent);
      expect(p.onPrimary, onColorFor(p.primary));
      expect(
        p.primaryFocus,
        Color.lerp(p.primary, const Color(0xFF000000), 0.15),
      );
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

  group('Linux', () {
    void expectRamp(MydiaPalette p, List<int> expected) {
      final actual = [
        p.background,
        p.surfaceDim,
        p.surfaceLow,
        p.surface,
        p.surfaceHigh,
        p.surfaceVariant,
        p.surfaceBright,
        p.textPrimary,
        p.textSecondary,
        p.textDisabled,
        p.divider,
        p.border,
      ];
      expect(actual, [for (final c in expected) Color(c)]);
      expect(p.cardHover, p.surfaceVariant);
      expect(p.shimmerBase, p.surface);
      expect(p.shimmerHighlight, p.surfaceVariant);
      expect(p.ambientTint, isFalse);
    }

    test('Adwaita ramp is pinned', () {
      expectRamp(Palettes.linux(LinuxDesktop.gnome, null), [
        0xFF1D1D20, 0xFF202023, 0xFF222226, 0xFF28282C, 0xFF2E2E32, //
        0xFF36363A, 0xFF3E3E43, 0xFFFFFFFF, 0xFFB4B4B6, 0xFF8E8E91,
        0xFF2A2A2E, 0xFF3A3A3E,
      ]);
    });

    test('Breeze ramp is pinned', () {
      expectRamp(Palettes.linux(LinuxDesktop.kde, null), [
        0xFF141618, 0xFF1A1C1E, 0xFF202326, 0xFF25282B, 0xFF292C30, //
        0xFF31363B, 0xFF3B4045, 0xFFFCFCFC, 0xFFA1A9B1, 0xFF7F8C8D,
        0xFF25282B, 0xFF3F444A,
      ]);
    });

    test('elementary ramp is pinned', () {
      expectRamp(Palettes.linux(LinuxDesktop.elementary, null), [
        0xFF1A1A1A, 0xFF202020, 0xFF262626, 0xFF2C2C2C, 0xFF333333, //
        0xFF3A3A3A, 0xFF404040, 0xFFFFFFFF, 0xFFABACAE, 0xFF8A8A8A,
        0xFF2B2B2B, 0xFF474747,
      ]);
    });

    test('other desktops are drawn like GNOME', () {
      expect(
        Palettes.linux(LinuxDesktop.other, null).surfaceTones,
        Palettes.linux(LinuxDesktop.gnome, null).surfaceTones,
      );
    });

    for (final d in LinuxDesktop.values) {
      test('${d.name} surface tones rise in luminance', () {
        final tones = Palettes.linux(d, null).surfaceTones;
        for (var i = 1; i < tones.length; i++) {
          expect(
            relativeLuminance(tones[i]),
            greaterThan(relativeLuminance(tones[i - 1])),
            reason: '${d.name} tone $i',
          );
        }
      });

      test("${d.name}: a null accent uses the desktop's stock accent, lifted",
          () {
        final p = Palettes.linux(d, null);
        expect(
          p.primary,
          Palettes.legibleAccent(d.stockAccent, background: p.background),
        );
      });

      test('${d.name}: extreme accents stay legible', () {
        for (final entry in linuxAccents.entries) {
          final p = Palettes.linux(d, entry.value);
          expect(contrastRatio(p.primary, p.background),
              greaterThanOrEqualTo(4.55),
              reason: '${d.name}/${entry.key} primary');
          expect(
              contrastRatio(p.onPrimary, p.primary), greaterThanOrEqualTo(4.5),
              reason: '${d.name}/${entry.key} onPrimary');
        }
      });
    }

    test('legibleAccent leaves a legible accent alone', () {
      const accent = Color(0xFFFFD60A);
      expect(
        Palettes.legibleAccent(accent, background: const Color(0xFF141618)),
        accent,
      );
    });

    test('a passed accent replaces the stock one', () {
      const accent = Color(0xFFF6D32D);
      expect(Palettes.linux(LinuxDesktop.kde, accent).primary, accent);
    });
  });

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
      expect(ThemePreset.availableOn(TargetPlatform.android, isWeb: false), [
        ThemePreset.projectionBooth,
        ThemePreset.oledBlack,
        ThemePreset.slate
      ]);
    });

    test('linux is offered only on native Linux', () {
      expect(
          ThemePreset.linux.isAvailableOn(TargetPlatform.linux, isWeb: false),
          isTrue);
      expect(ThemePreset.linux.isAvailableOn(TargetPlatform.linux, isWeb: true),
          isFalse);
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.windows,
      ]) {
        expect(ThemePreset.linux.isAvailableOn(platform, isWeb: false), isFalse,
            reason: platform.name);
      }
      expect(ThemePreset.availableOn(TargetPlatform.linux, isWeb: false), [
        ThemePreset.projectionBooth,
        ThemePreset.oledBlack,
        ThemePreset.slate,
        ThemePreset.linux,
      ]);
      expect(ThemePreset.availableOn(TargetPlatform.macOS, isWeb: false),
          isNot(contains(ThemePreset.linux)));
    });

    test('defaults to linux on native Linux', () {
      expect(ThemePreset.defaultFor(TargetPlatform.linux, isWeb: false),
          ThemePreset.linux);
      expect(ThemePreset.defaultFor(TargetPlatform.linux, isWeb: true),
          ThemePreset.projectionBooth);
    });

    test('a stored linux elsewhere falls back', () {
      expect(ThemePreset.resolve('linux', TargetPlatform.macOS, isWeb: false),
          ThemePreset.macos);
      expect(ThemePreset.resolve('linux', TargetPlatform.android, isWeb: false),
          ThemePreset.projectionBooth);
      expect(ThemePreset.resolve('linux', TargetPlatform.linux, isWeb: true),
          ThemePreset.projectionBooth);
      expect(ThemePreset.resolve('slate', TargetPlatform.linux, isWeb: false),
          ThemePreset.slate);
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
          ThemePreset.linux);
      expect(ThemePreset.resolve('bogus', TargetPlatform.windows, isWeb: false),
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
