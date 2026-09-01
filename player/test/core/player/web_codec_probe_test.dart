import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/device_profile.dart';
import 'package:player/core/player/web_codec_probe.dart';

/// `MediaSource.isTypeSupported` answers measured on one Linux machine on
/// 2026-08-31, headless, by feeding each string to the real browser.
///
/// Recorded rather than imagined because the whole point of the probe is that
/// browsers disagree, and a hand-written expectation would just re-encode the
/// guess the fixed list already got wrong. These two disagree about HEVC and
/// about H.264 High 10 in opposite directions, which is the case the profile
/// has to get right.
const _firefox154 = {
  'video/mp4; codecs="avc1.640028"',
  'video/mp4; codecs="avc1.42E01E"',
  // NB: no avc1.6E0028 — Firefox refuses H.264 High 10.
  'video/mp4; codecs="hvc1.1.6.L93.B0"',
  'video/mp4; codecs="hev1.1.6.L93.B0"',
  'video/mp4; codecs="hvc1.2.4.L120.B0"',
  'video/mp4; codecs="hev1.2.4.L120.B0"',
  'video/mp4; codecs="av01.0.04M.08"',
  'video/mp4; codecs="av01.0.04M.10"',
  'video/mp4; codecs="vp09.00.10.08"',
  'video/mp4; codecs="vp09.02.10.10"',
  'video/webm; codecs="vp9"',
  'video/webm; codecs="vp8"',
  'audio/mp4; codecs="mp4a.40.2"',
  'audio/mp4; codecs="mp4a.40.5"',
  'audio/mp4; codecs="opus"',
  'audio/webm; codecs="opus"',
  'audio/webm; codecs="vorbis"',
  'audio/mp4; codecs="flac"',
};

const _chromium149Headless = {
  'video/mp4; codecs="avc1.640028"',
  'video/mp4; codecs="avc1.42E01E"',
  'video/mp4; codecs="avc1.6E0028"',
  // NB: no hvc1/hev1 at all — headless Chromium has no HEVC.
  'video/mp4; codecs="av01.0.04M.08"',
  'video/mp4; codecs="av01.0.04M.10"',
  'video/mp4; codecs="vp09.00.10.08"',
  'video/mp4; codecs="vp09.02.10.10"',
  'video/webm; codecs="vp9"',
  'video/webm; codecs="vp8"',
  'audio/mp4; codecs="mp4a.40.2"',
  'audio/mp4; codecs="mp4a.40.5"',
  'audio/mpeg',
  'audio/mp4; codecs="opus"',
  'audio/webm; codecs="opus"',
  'audio/webm; codecs="vorbis"',
  'audio/mp4; codecs="flac"',
};

CodecProbe _replaying(Set<String> supported) => supported.contains;

/// The bit-depth ceilings the profile attached, as `codec -> value`.
Map<String, String> _depthCeilings(DeviceProfile profile) => {
      for (final codecProfile in profile.codecProfiles)
        for (final condition in codecProfile.conditions)
          if (condition.property == 'VideoBitDepth')
            codecProfile.codec: condition.value,
    };

void main() {
  group('buildWebDeviceProfile on Firefox 154', () {
    final profile = buildWebDeviceProfile(_replaying(_firefox154));

    test('claims HEVC, which the fixed list withheld', () {
      expect(profile.videoCodecs, contains('hevc'));
      expect(profile.videoCodecs, contains('h265'));
      expect(const DeviceProfile.webDefault().videoCodecs,
          isNot(contains('hevc')));
    });

    test('claims HEVC unconstrained, because Main 10 probes true', () {
      expect(_depthCeilings(profile).containsKey('hevc'), isFalse);
    });

    test('caps H.264 at 8-bit, because High 10 probes false', () {
      // The case a flat `h264` claim gets wrong: the server would otherwise
      // hand over a 10-bit stream this browser cannot open.
      expect(_depthCeilings(profile)['h264'], '8');
    });

    test('caps every H.264 alias, not just the canonical one', () {
      // The server matches a codec profile by substring, exactly as it matches
      // the allowlist. An alias claimed without a matching profile would slip
      // past the ceiling — and "h.264" is the alias that actually matches the
      // "H.264 (High 10)" display string ffprobe produces.
      final ceilings = _depthCeilings(profile);
      for (final alias in ['h264', 'h.264', 'avc', 'avc1']) {
        expect(ceilings[alias], '8', reason: 'alias $alias is uncapped');
      }
    });

    test('claims FLAC, which the fixed list withheld', () {
      expect(profile.audioCodecs, contains('flac'));
      expect(const DeviceProfile.webDefault().audioCodecs,
          isNot(contains('flac')));
    });

    test('drops MP3, which MediaSource refuses here', () {
      // The fixed list claimed it unconditionally. Firefox accepts neither
      // audio/mpeg nor mp4a.69 through MediaSource, and hls.js has no other
      // way in, so claiming it buys a failed playback rather than a transcode.
      expect(profile.audioCodecs, isNot(contains('mp3')));
      expect(const DeviceProfile.webDefault().audioCodecs, contains('mp3'));
    });

    test('drops AC3 and E-AC-3', () {
      expect(profile.audioCodecs, isNot(contains('ac3')));
      expect(profile.audioCodecs, isNot(contains('dd+')));
    });
  });

  group('buildWebDeviceProfile on headless Chromium 149', () {
    final profile = buildWebDeviceProfile(_replaying(_chromium149Headless));

    test('withholds HEVC entirely', () {
      for (final alias in ['hevc', 'h265', 'h.265', 'hvc1', 'hev1']) {
        expect(profile.videoCodecs, isNot(contains(alias)));
      }
    });

    test('claims H.264 unconstrained, because High 10 probes true', () {
      expect(profile.videoCodecs, contains('h.264'));
      expect(_depthCeilings(profile), isEmpty);
    });

    test('claims MP3, which it accepts as audio/mpeg', () {
      expect(profile.audioCodecs, contains('mp3'));
    });

    test('disagrees with Firefox about HEVC on the same machine', () {
      // The reason a fixed list cannot be right.
      final firefox = buildWebDeviceProfile(_replaying(_firefox154));
      expect(firefox.videoCodecs.contains('hevc'), isTrue);
      expect(profile.videoCodecs.contains('hevc'), isFalse);
    });
  });

  group('fallback', () {
    test('a browser that answers nothing gets the fixed list', () {
      // An empty allowlist is not a modest claim — the server reads it as
      // "transcode everything" — so this must not be the shape of a failure.
      final profile = buildWebDeviceProfile((_) => false);
      expect(profile.videoCodecs, const DeviceProfile.webDefault().videoCodecs);
      expect(profile.audioCodecs, const DeviceProfile.webDefault().audioCodecs);
    });

    test('video with no audio falls back whole, not half', () {
      final profile = buildWebDeviceProfile(
        _replaying({'video/mp4; codecs="avc1.640028"'}),
      );
      expect(profile.audioCodecs, isNotEmpty);
      expect(profile.videoCodecs, const DeviceProfile.webDefault().videoCodecs);
    });

    test('audio with no video falls back whole, not half', () {
      final profile = buildWebDeviceProfile(
        _replaying({'audio/mp4; codecs="mp4a.40.2"'}),
      );
      expect(profile.videoCodecs, isNotEmpty);
      expect(profile.audioCodecs, const DeviceProfile.webDefault().audioCodecs);
    });

    test('a throwing probe is the caller\'s problem, not a half profile', () {
      // device_profile_web.dart swallows per-codec throws; this pins that a
      // probe which simply says no everywhere still yields a usable profile.
      expect(
        buildWebDeviceProfile((_) => false).videoCodecs,
        isNotEmpty,
      );
    });
  });

  group('wire format', () {
    test('the worst realistic profile still fits the 4 KB header cap', () {
      // Mydia.Streaming.DeviceProfile.decode_header/1 drops anything over
      // 4096 bytes *before* parsing it, and a dropped profile is treated as
      // absent — which silently reverts every gain here. Worst case is every
      // codec claimed and every one of them bit-depth capped.
      final everything = <String>{
        for (final codec in kProbedVideoCodecs) ...codec.probes,
        for (final codec in kProbedAudioCodecs) ...codec.probes,
      };

      final profile = buildWebDeviceProfile(_replaying(everything));
      expect(profile.codecProfiles, isNotEmpty,
          reason: 'no high-bit-depth probe passed, so every codec is capped');
      expect(profile.toHeaderValue().length, lessThan(4096));
    });

    test('carries no padding, which the server would fail to decode', () {
      final profile = buildWebDeviceProfile(_replaying(_firefox154));
      expect(profile.toHeaderValue(), isNot(contains('=')));
    });
  });
}
