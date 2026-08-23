import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/device_profile.dart';

void main() {
  group('DeviceProfile', () {
    test('serializes to the camelCase keys the server casts', () {
      const profile = DeviceProfile(
        containers: ['mkv', 'mp4'],
        videoCodecs: ['h264', 'hevc'],
        audioCodecs: ['aac', 'ac3'],
        hdrFormats: ['hdr10'],
      );

      expect(profile.toJson(), {
        'containers': ['mkv', 'mp4'],
        'videoCodecs': ['h264', 'hevc'],
        'audioCodecs': ['aac', 'ac3'],
        'hdrFormats': ['hdr10'],
      });
    });

    test('encodes to unpadded base64url so it survives a header', () {
      const profile = DeviceProfile(
        containers: ['mkv'],
        videoCodecs: ['hevc'],
        audioCodecs: ['ac3'],
        hdrFormats: [],
      );

      final header = profile.toHeaderValue();

      expect(header, isNot(contains('=')));

      final decoded = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(header))));
      expect(decoded['containers'], ['mkv']);
    });

    test('stays under the 4 KB server cap', () {
      final profile = DeviceProfile(
        containers: List.generate(64, (i) => 'container$i'),
        videoCodecs: List.generate(64, (i) => 'video$i'),
        audioCodecs: List.generate(64, (i) => 'audio$i'),
        hdrFormats: List.generate(64, (i) => 'hdr$i'),
      );

      expect(profile.toHeaderValue().length, lessThan(4096));
    });

    test('web profile advertises only what browsers decode', () {
      const profile = DeviceProfile.webDefault();

      expect(profile.containers, contains('mp4'));
      expect(profile.videoCodecs, contains('h264'));
      expect(profile.videoCodecs, isNot(contains('hevc')));
      expect(profile.hdrFormats, isEmpty);
    });
  });
}
