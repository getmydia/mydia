import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/device_profile.dart';
import 'package:player/core/player/ios_codec_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.mydia.player/codecs.ios.test');

  const full = DeviceProfile(
    containers: ['mp4', 'mkv'],
    videoCodecs: [
      'h264',
      'hevc',
      'h265',
      'h.265',
      'hvc1',
      'vp9',
      'vp09',
      'av1',
      'av01',
      'mpeg2',
    ],
    audioCodecs: ['aac'],
    hdrFormats: ['hdr10'],
  );

  var calls = 0;

  void stub(Object? Function() respond) {
    calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'hardwareVideoDecoders');
      return respond();
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<DeviceProfile> apply({bool isIos = true}) =>
      applyIosHardwareDecode(full, isIos: isIos, channel: channel);

  group('applyIosHardwareDecode', () {
    test('unsupported HEVC removes all four aliases and nothing else',
        () async {
      stub(() => {'hevc': false, 'av1': true});

      final profile = await apply();

      expect(
          profile.videoCodecs, ['h264', 'vp9', 'vp09', 'av1', 'av01', 'mpeg2']);
      expect(profile.audioCodecs, full.audioCodecs);
      expect(profile.containers, full.containers);
    });

    test('unsupported AV1 removes its aliases', () async {
      stub(() => {'hevc': true, 'av1': false});

      final profile = await apply();

      expect(profile.videoCodecs, [
        'h264',
        'hevc',
        'h265',
        'h.265',
        'hvc1',
        'vp9',
        'vp09',
        'mpeg2',
      ]);
    });

    test('a vp9 false in the answer never removes vp9 aliases', () async {
      stub(() => {'hevc': true, 'vp9': false, 'av1': true});

      final profile = await apply();

      expect(profile.videoCodecs, full.videoCodecs);
    });

    test('everything supported leaves the profile unchanged', () async {
      stub(() => {'hevc': true, 'av1': true});

      expect((await apply()).videoCodecs, full.videoCodecs);
    });

    test('a codec missing from the answer stays claimed', () async {
      stub(() => {'hevc': false});

      final profile = await apply();

      expect(profile.videoCodecs, contains('av1'));
      expect(profile.videoCodecs, contains('vp9'));
      expect(profile.videoCodecs, isNot(contains('hevc')));
    });

    test('a channel error leaves the profile unchanged', () async {
      stub(() => throw PlatformException(code: 'boom'));

      expect((await apply()).videoCodecs, full.videoCodecs);
    });

    test('an empty or null answer leaves the profile unchanged', () async {
      stub(() => <String, Object?>{});
      expect((await apply()).videoCodecs, full.videoCodecs);

      stub(() => null);
      expect((await apply()).videoCodecs, full.videoCodecs);
    });

    test('a missing plugin leaves the profile unchanged', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      expect((await apply()).videoCodecs, full.videoCodecs);
    });

    test('probes the dev.mydia.player/codecs channel by default', () async {
      const defaultChannel = MethodChannel('dev.mydia.player/codecs');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var defaultCalls = 0;
      messenger.setMockMethodCallHandler(defaultChannel, (call) async {
        defaultCalls++;
        expect(call.method, 'hardwareVideoDecoders');
        return {'hevc': false, 'av1': true};
      });
      addTearDown(
          () => messenger.setMockMethodCallHandler(defaultChannel, null));

      final profile = await applyIosHardwareDecode(full, isIos: true);

      expect(defaultCalls, 1);
      expect(profile.videoCodecs, isNot(contains('hevc')));
      expect(profile.videoCodecs, contains('av1'));
    });

    test('does not probe or narrow off iOS', () async {
      stub(() => {'hevc': false, 'vp9': false, 'av1': false});

      final profile = await apply(isIos: false);

      expect(profile.videoCodecs, full.videoCodecs);
      expect(calls, 0);
    });
  });
}
