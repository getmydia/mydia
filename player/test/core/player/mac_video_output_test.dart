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

  group('resolveVideoOutputChoice', () {
    Future<MacVideoOutputChoice> resolve({
      required Future<bool> Function() hatch,
      required Future<String?> Function() failed,
    }) =>
        resolveVideoOutputChoice(
          readLegacyHatch: hatch,
          readFailedVersion: failed,
          appVersion: '1.5.0',
          platform: TargetPlatform.macOS,
          isWeb: false,
        );

    test('a hatch read that throws still reads the failure marker', () async {
      final choice = await resolve(
        hatch: () async => throw StateError('keychain'),
        failed: () async => '1.5.0',
      );
      expect(choice.path, VideoOutputPath.texture);
      expect(choice.failedEarlier, isTrue);
    });

    test('a hatch read that throws with no marker keeps the surface', () async {
      final choice = await resolve(
        hatch: () async => throw StateError('keychain'),
        failed: () async => null,
      );
      expect(choice.path, VideoOutputPath.surface);
    });

    test('a marker read that throws still honours the hatch', () async {
      final choice = await resolve(
        hatch: () async => true,
        failed: () async => throw StateError('keychain'),
      );
      expect(choice.path, VideoOutputPath.texture);
      expect(choice.failedEarlier, isFalse);
    });
  });

  test('readInstalledVersion answers empty when the read throws', () async {
    expect(await readInstalledVersion(() async => throw StateError('x')), '');
    expect(await readInstalledVersion(() async => '1.5.0'), '1.5.0');
  });
}
