import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/hdr_claims.dart';
import 'package:player/core/player/mac_hdr_claims.dart';
import 'package:player/core/player/mac_video_output.dart';

void main() {
  group('macHdrFormats', () {
    test('Dolby Vision ships unverified', () {
      expect(macDolbyVisionVerified, isFalse);
    });

    test('the surface claims the native list while unverified', () {
      expect(macHdrFormats(VideoOutputPath.surface), [
        'hdr10+',
        'hdr10',
        'hlg',
      ]);
    });

    test('the surface adds dolby_vision first once verified', () {
      expect(
        macHdrFormats(VideoOutputPath.surface, dolbyVisionVerified: true),
        ['dolby_vision', 'hdr10+', 'hdr10', 'hlg'],
      );
    });

    test('the texture claims spec 1\'s native list exactly', () {
      expect(macHdrFormats(VideoOutputPath.texture), nativeHdrFormats);
      expect(
        macHdrFormats(VideoOutputPath.texture, dolbyVisionVerified: true),
        nativeHdrFormats,
      );
    });
  });

  group('nativeProfileHdrFormats', () {
    test('macOS follows the resolved path', () async {
      for (final path in VideoOutputPath.values) {
        expect(
          await nativeProfileHdrFormats(
            isMacOS: true,
            resolvePath: () async => path,
          ),
          macHdrFormats(path),
        );
      }
    });

    test('macOS without a resolver claims the texture list', () async {
      expect(await nativeProfileHdrFormats(isMacOS: true), nativeHdrFormats);
    });

    test('a throwing resolver falls back to the native list', () async {
      expect(
        await nativeProfileHdrFormats(
          isMacOS: true,
          resolvePath: () async => throw StateError('boom'),
        ),
        nativeHdrFormats,
      );
    });

    test('other platforms never consult the resolver', () async {
      var called = false;
      final formats = await nativeProfileHdrFormats(
        isMacOS: false,
        resolvePath: () async {
          called = true;
          return VideoOutputPath.surface;
        },
      );
      expect(formats, nativeHdrFormats);
      expect(called, isFalse);
    });
  });

  group('resolveVideoOutputChoice', () {
    Future<MacVideoOutputChoice> resolve({
      bool legacy = false,
      String? failed,
      String version = '1.5.0',
    }) => resolveVideoOutputChoice(
      readLegacyHatch: () async => legacy,
      readFailedVersion: () async => failed,
      appVersion: version,
      platform: TargetPlatform.macOS,
      isWeb: false,
    );

    test('uses the surface with nothing against it', () async {
      expect((await resolve()).path, VideoOutputPath.surface);
    });

    test('the hatch and a same-version failure give the texture', () async {
      expect((await resolve(legacy: true)).path, VideoOutputPath.texture);
      final failed = await resolve(failed: '1.5.0');
      expect(failed.path, VideoOutputPath.texture);
      expect(failed.failedEarlier, isTrue);
    });

    test('an older failure is ignored', () async {
      expect((await resolve(failed: '1.4.0')).path, VideoOutputPath.surface);
    });

    test('a throwing read counts as no hatch and no failure', () async {
      final choice = await resolveVideoOutputChoice(
        readLegacyHatch: () async => throw StateError('boom'),
        readFailedVersion: () async => null,
        appVersion: '1.5.0',
        platform: TargetPlatform.macOS,
        isWeb: false,
      );
      expect(choice.path, VideoOutputPath.surface);
    });
  });
}
