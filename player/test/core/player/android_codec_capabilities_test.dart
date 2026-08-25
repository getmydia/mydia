import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/android_codec_capabilities.dart';
import 'package:player/core/player/device_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.mydia.player/codecs.test');

  void stub(Object? Function() respond) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'videoDecoderCapabilities');
      return respond();
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('probeAndroidCodecProfiles', () {
    test('turns an 8-bit-only HEVC decoder into a bit-depth ceiling', () async {
      stub(() => [
            {
              'codec': 'hevc',
              'maxBitDepth': 8,
              'maxWidth': 1920,
              'maxHeight': 1088,
            },
          ]);

      final profiles = await probeAndroidCodecProfiles(channel: channel);

      expect(profiles, hasLength(1));
      expect(profiles.single.codec, 'hevc');
      expect(profiles.single.type, 'video');

      final depth = profiles.single.conditions.firstWhere(
        (c) => c.property == ProfileProperty.videoBitDepth,
      );
      expect(depth.condition, ProfileComparison.lessThanEqual);
      expect(depth.value, '8');
      // The whole point: a Main 10 stream must fail this, so it has to be
      // required rather than skipped when the depth is unknown.
      expect(depth.isRequired, isTrue);
    });

    test(
        'marks resolution ceilings optional so an unknown size does not transcode',
        () async {
      stub(() => [
            {
              'codec': 'hevc',
              'maxBitDepth': 10,
              'maxWidth': 3840,
              'maxHeight': 2160
            },
          ]);

      final profiles = await probeAndroidCodecProfiles(channel: channel);
      final width = profiles.single.conditions.firstWhere(
        (c) => c.property == ProfileProperty.width,
      );

      expect(width.isRequired, isFalse);
      expect(width.value, '3840');
    });

    test('returns empty when the platform reports nothing', () async {
      stub(() => <dynamic>[]);

      expect(await probeAndroidCodecProfiles(channel: channel), isEmpty);
    });

    test('returns empty rather than throwing when the channel fails', () async {
      stub(() => throw PlatformException(code: 'boom'));

      expect(await probeAndroidCodecProfiles(channel: channel), isEmpty);
    });

    test('skips malformed entries instead of emitting a codec with no name',
        () async {
      stub(() => [
            {'maxBitDepth': 8},
            {'codec': '', 'maxBitDepth': 8},
            {'codec': 'h264', 'maxBitDepth': 8},
          ]);

      final profiles = await probeAndroidCodecProfiles(channel: channel);

      expect(profiles.map((p) => p.codec), ['h264']);
    });
  });

  group('DeviceProfile wire format', () {
    test('omits codecProfiles entirely when there are none', () {
      const profile = DeviceProfile(
        containers: ['mkv'],
        videoCodecs: ['hevc'],
        audioCodecs: ['ac3'],
        hdrFormats: [],
      );

      expect(profile.toJson().containsKey('codecProfiles'), isFalse);
    });

    test('serializes conditions in the shape the server parses', () {
      const profile = DeviceProfile(
        containers: ['mkv'],
        videoCodecs: ['hevc'],
        audioCodecs: ['ac3'],
        hdrFormats: [],
        codecProfiles: [
          CodecProfile.video('hevc', [
            ProfileCondition.atMost(ProfileProperty.videoBitDepth, '8'),
          ]),
        ],
      );

      expect(profile.toJson()['codecProfiles'], [
        {
          'type': 'video',
          'codec': 'hevc',
          'conditions': [
            {
              'property': 'VideoBitDepth',
              'condition': 'LessThanEqual',
              'value': '8',
              'isRequired': true,
            },
          ],
        },
      ]);
    });

    test('the header stays unpadded base64url', () {
      const profile = DeviceProfile(
        containers: ['mkv'],
        videoCodecs: ['hevc'],
        audioCodecs: ['ac3'],
        hdrFormats: [],
        codecProfiles: [
          CodecProfile.video('hevc', [
            ProfileCondition.atMost(ProfileProperty.videoBitDepth, '8'),
          ]),
        ],
      );

      final header = profile.toHeaderValue();

      expect(header, isNot(contains('=')));
      expect(header, isNot(contains('+')));
      expect(header, isNot(contains('/')));
    });
  });
}
