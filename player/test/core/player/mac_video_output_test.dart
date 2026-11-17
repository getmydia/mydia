import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/mac_video_output.dart';

VideoOutputPath _choose({
  TargetPlatform platform = TargetPlatform.macOS,
  bool isWeb = false,
  bool legacyHatch = false,
  String? failedVersion,
  String appVersion = '1.5.0',
}) =>
    chooseVideoOutputPath(
      platform: platform,
      isWeb: isWeb,
      legacyHatch: legacyHatch,
      failedVersion: failedVersion,
      appVersion: appVersion,
    );

void main() {
  test('macOS with nothing against it uses the surface', () {
    expect(_choose(), VideoOutputPath.surface);
  });

  test('other platforms keep the texture', () {
    for (final p
        in TargetPlatform.values.where((p) => p != TargetPlatform.macOS)) {
      expect(_choose(platform: p), VideoOutputPath.texture, reason: '$p');
    }
  });

  test('web keeps the texture', () {
    expect(_choose(isWeb: true), VideoOutputPath.texture);
  });

  test('the legacy hatch forces the texture', () {
    expect(_choose(legacyHatch: true), VideoOutputPath.texture);
  });

  test('a failure recorded for this version forces the texture', () {
    expect(_choose(failedVersion: '1.5.0'), VideoOutputPath.texture);
  });

  test('recordedFailureForOtherVersionIsIgnored', () {
    expect(_choose(failedVersion: '1.4.0'), VideoOutputPath.surface);
  });
}
