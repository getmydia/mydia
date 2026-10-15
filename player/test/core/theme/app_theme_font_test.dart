// `app_theme.dart` declares `fontFamily: 'Inter'`, but a declared family with
// no matching `fonts:` manifest entry fails silently — Flutter falls back to
// the platform default. This asserts the declaration and the manifest agree.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/colors.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('the theme declares Inter', () {
    expect(AppTheme.darkTheme.textTheme.bodyMedium?.fontFamily, 'Inter');
  });

  test('display, headline and title styles use Outfit; body and label Inter',
      () {
    final t = AppTheme.darkTheme.textTheme;
    for (final s in [
      t.displayLarge,
      t.displayMedium,
      t.displaySmall,
      t.headlineLarge,
      t.headlineMedium,
      t.headlineSmall,
      t.titleLarge,
      t.titleMedium,
      t.titleSmall,
    ]) {
      expect(s?.fontFamily, 'Outfit');
    }
    for (final s in [
      t.bodyLarge,
      t.bodyMedium,
      t.bodySmall,
      t.labelLarge,
      t.labelMedium,
      t.labelSmall,
    ]) {
      expect(s?.fontFamily, 'Inter');
    }
  });

  test('pubspec declares Outfit at 500, 600 and 700', () {
    final fonts = ((loadYaml(File('pubspec.yaml').readAsStringSync())
        as YamlMap)['flutter'] as YamlMap)['fonts'] as YamlList;
    final outfit =
        fonts.cast<YamlMap>().firstWhere((f) => f['family'] == 'Outfit');
    final weights = [
      for (final f in outfit['fonts'] as YamlList) (f as YamlMap)['weight'],
    ];
    expect(weights, [500, 600, 700]);
    for (final f in outfit['fonts'] as YamlList) {
      expect(File((f as YamlMap)['asset'] as String).existsSync(), isTrue);
    }
  });

  test('primary buttons are white with a near-black Outfit label', () {
    final theme = AppTheme.darkTheme;
    for (final style in [
      theme.filledButtonTheme.style!,
      theme.elevatedButtonTheme.style!,
    ]) {
      expect(style.backgroundColor!.resolve({}), const Color(0xFFFFFFFF));
      expect(style.foregroundColor!.resolve({}), AppColors.background);
      expect(style.textStyle!.resolve({})!.fontFamily, 'Outfit');
    }
  });

  test('pubspec declares an Inter family with correct structure', () {
    final pubspecContent = File('pubspec.yaml').readAsStringSync();
    final pubspec = loadYaml(pubspecContent) as YamlMap;

    expect(pubspec['flutter'], isNotNull, reason: 'flutter section missing');
    final flutter = pubspec['flutter'] as YamlMap;

    expect(flutter['fonts'], isNotNull,
        reason: 'fonts section missing under flutter');
    final fonts = flutter['fonts'] as YamlList;

    // Find the Inter family
    YamlMap? interFamily;
    for (final font in fonts) {
      if (font is YamlMap && font['family'] == 'Inter') {
        interFamily = font;
        break;
      }
    }

    expect(interFamily, isNotNull,
        reason: 'Inter family not found in fonts list');

    // Verify the weights
    final fontList = interFamily!['fonts'] as YamlList;
    final weights = <String, String>{};
    for (final fontEntry in fontList) {
      if (fontEntry is YamlMap) {
        final asset = fontEntry['asset'] as String?;
        final weight = fontEntry['weight'] as int?;
        if (asset != null && weight != null) {
          weights[asset] = weight.toString();
        }
      }
    }

    expect(weights, contains('assets/fonts/Inter-Regular.ttf'));
    expect(weights['assets/fonts/Inter-Regular.ttf'], '400');

    expect(weights, contains('assets/fonts/Inter-Medium.ttf'));
    expect(weights['assets/fonts/Inter-Medium.ttf'], '500');

    expect(weights, contains('assets/fonts/Inter-SemiBold.ttf'));
    expect(weights['assets/fonts/Inter-SemiBold.ttf'], '600');

    expect(weights, contains('assets/fonts/Inter-Bold.ttf'));
    expect(weights['assets/fonts/Inter-Bold.ttf'], '700');
  });

  test('every declared weight has a font file on disk', () {
    const expected = <String>[
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ];

    for (final path in expected) {
      expect(File(path).existsSync(), isTrue, reason: 'missing asset: $path');
    }
  });

  test('Inter license is declared as an asset', () {
    final pubspecContent = File('pubspec.yaml').readAsStringSync();
    final pubspec = loadYaml(pubspecContent) as YamlMap;

    expect(pubspec['flutter'], isNotNull, reason: 'flutter section missing');
    final flutter = pubspec['flutter'] as YamlMap;

    expect(flutter['assets'], isNotNull,
        reason: 'assets section missing under flutter');
    final assets = flutter['assets'] as YamlList;

    final licenseAssets = assets
        .whereType<String>()
        .where((asset) => asset.contains('Inter-LICENSE'))
        .toList();

    expect(licenseAssets, isNotEmpty,
        reason: 'Inter-LICENSE.txt not declared in assets');
    expect(licenseAssets, contains('assets/fonts/Inter-LICENSE.txt'));
  });

  test('Inter license file exists', () {
    const path = 'assets/fonts/Inter-LICENSE.txt';
    expect(File(path).existsSync(), isTrue,
        reason: 'missing license file: $path');

    // Verify it contains SIL license text
    final content = File(path).readAsStringSync();
    expect(content, contains('Open Font License'));
  });

  test('Outfit license is declared as an asset', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final assets = (pubspec['flutter'] as YamlMap)['assets'] as YamlList;
    expect(assets, contains('assets/fonts/Outfit-LICENSE.txt'));
  });

  test('Outfit license file exists and is the SIL OFL', () {
    const path = 'assets/fonts/Outfit-LICENSE.txt';
    expect(File(path).existsSync(), isTrue);
    expect(File(path).readAsStringSync(), contains('Open Font License'));
  });
}
