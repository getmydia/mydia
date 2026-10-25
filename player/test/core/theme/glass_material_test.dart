import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/glass_material.dart';

void main() {
  group('defaultFor', () {
    test('Liquid Glass on native iOS and macOS', () {
      for (final p in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        expect(GlassMaterial.defaultFor(p, isWeb: false, isTv: false),
            GlassMaterial.liquid,
            reason: '$p');
      }
    });

    test('Frosted on Android, desktop and web', () {
      for (final p in [
        TargetPlatform.android,
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(GlassMaterial.defaultFor(p, isWeb: false, isTv: false),
            GlassMaterial.frosted,
            reason: '$p');
      }
      expect(
          GlassMaterial.defaultFor(TargetPlatform.macOS,
              isWeb: true, isTv: false),
          GlassMaterial.frosted);
    });
  });

  group('availableOn', () {
    test('both everywhere but TV', () {
      for (final p in TargetPlatform.values) {
        expect(GlassMaterial.availableOn(p, isWeb: false, isTv: false),
            GlassMaterial.values,
            reason: '$p');
      }
      expect(
          GlassMaterial.availableOn(TargetPlatform.android,
              isWeb: true, isTv: false),
          GlassMaterial.values);
    });

    test('only Frosted on TV', () {
      expect(
          GlassMaterial.availableOn(TargetPlatform.android,
              isWeb: false, isTv: true),
          [GlassMaterial.frosted]);
    });
  });

  group('resolve', () {
    test('a stored choice wins over the default', () {
      expect(
          GlassMaterial.resolve('liquid', TargetPlatform.android,
              isWeb: false, isTv: false),
          GlassMaterial.liquid);
      expect(
          GlassMaterial.resolve('frosted', TargetPlatform.iOS,
              isWeb: false, isTv: false),
          GlassMaterial.frosted);
    });

    test('unset or unknown falls back to the default', () {
      expect(
          GlassMaterial.resolve(null, TargetPlatform.iOS,
              isWeb: false, isTv: false),
          GlassMaterial.liquid);
      expect(
          GlassMaterial.resolve('chrome', TargetPlatform.android,
              isWeb: false, isTv: false),
          GlassMaterial.frosted);
    });

    test('a stored Liquid Glass on TV falls back to Frosted', () {
      expect(
          GlassMaterial.resolve('liquid', TargetPlatform.android,
              isWeb: false, isTv: true),
          GlassMaterial.frosted);
    });
  });
}
