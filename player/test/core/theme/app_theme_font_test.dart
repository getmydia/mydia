// `app_theme.dart` declares `fontFamily: 'Inter'`, but a declared family with
// no matching `fonts:` manifest entry fails silently — Flutter falls back to
// the platform default. This asserts the declaration and the manifest agree.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';

void main() {
  test('the theme declares Inter', () {
    expect(AppTheme.darkTheme.textTheme.bodyMedium?.fontFamily, 'Inter');
  });

  test('pubspec declares an Inter family', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('family: Inter'));
  });

  test('every declared weight has a font file on disk', () {
    const expected = <String>[
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ];
    final pubspec = File('pubspec.yaml').readAsStringSync();

    for (final path in expected) {
      expect(File(path).existsSync(), isTrue, reason: 'missing asset: $path');
      expect(pubspec, contains(path), reason: 'not in pubspec: $path');
    }
  });
}
