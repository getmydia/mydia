// Guards the four manifest declarations Google TV requires. Each one is
// invisible at runtime on a phone and silently fatal on a television: without
// them the launcher neither lists nor starts the app, and there is no test
// anywhere else in this suite that would notice their removal.
//
// Reads the file as text rather than parsing XML. The assertions are on exact
// attribute strings, and a parser would add a dependency to catch nothing
// extra.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String manifest;

  setUpAll(() {
    manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  });

  test('declares leanback as an optional feature, so one bundle serves both',
      () {
    expect(
      manifest,
      contains(
        '<uses-feature android:name="android.software.leanback" '
        'android:required="false"/>',
      ),
    );
  });

  test('declares touchscreen optional, without which Google TV filters the app',
      () {
    expect(
      manifest,
      contains(
        '<uses-feature android:name="android.hardware.touchscreen" '
        'android:required="false"/>',
      ),
    );
  });

  test('MainActivity carries the leanback launcher category', () {
    expect(
      manifest,
      contains(
        '<category android:name="android.intent.category.LEANBACK_LAUNCHER"/>',
      ),
    );
  });

  test('keeps the phone launcher category alongside it', () {
    expect(
      manifest,
      contains('<category android:name="android.intent.category.LAUNCHER"/>'),
    );
  });

  test('declares a banner, which the leanback launcher requires to draw a tile',
      () {
    expect(manifest, contains('android:banner="@drawable/tv_banner"'));
  });
}
