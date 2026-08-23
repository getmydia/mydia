/// Native device profile: probes libmpv's decoder list and falls back to a
/// static table on any failure or surprising answer.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'device_profile.dart';

/// What libmpv is built with on every desktop and mobile target Mydia ships.
///
/// This is the floor, used whenever the probe cannot answer. It describes the
/// libmpv build rather than this device's hardware, so it can over-report: a
/// phone with no hardware HEVC decoder still claims hevc and will fall back to
/// software decoding rather than asking the server to transcode. That is the
/// same thing the player did before profiles existed, so the floor is never
/// worse than the status quo.
const DeviceProfile _staticNativeProfile = DeviceProfile(
  containers: [
    'mp4',
    'mkv',
    'matroska',
    'webm',
    'm4v',
    'avi',
    'mov',
    'ts',
    'mpegts',
    'm2ts',
    'mts',
    'wmv',
    'flv',
  ],
  videoCodecs: [
    'h264',
    'h.264',
    'avc',
    'avc1',
    'hevc',
    'h265',
    'h.265',
    'hvc1',
    'vp8',
    'vp9',
    'vp09',
    'av1',
    'av01',
    'mpeg2',
    'mpeg4',
    'vc1',
  ],
  audioCodecs: [
    'aac',
    'mp3',
    'opus',
    'vorbis',
    'flac',
    'ac3',
    'eac3',
    'dts',
    'truehd',
    'pcm',
    'alac',
  ],
  hdrFormats: ['hdr10', 'hdr10plus', 'hlg', 'dolby_vision'],
);

/// Asks mpv what it can decode, falling back to [_staticNativeProfile].
///
/// `getProperty` returns "" for a property mpv does not know, and the exact
/// shape of `decoder-list` has not been verified against a real mpv on every
/// platform, so every failure mode lands on the static table rather than on an
/// empty profile. The probe only ever narrows the static table: an unfamiliar
/// codec name from mpv is ignored rather than advertised, so a parsing
/// surprise cannot make this client claim something the server would then
/// hand it untranscoded.
///
/// Constructs a throwaway [Player] purely to reach mpv's property API; media_kit
/// exposes no lighter handle for it. The instance is always disposed before
/// returning, success or failure.
Future<DeviceProfile> detectDeviceProfile() async {
  Player? player;
  try {
    player = Player();
    final platform = player.platform;

    // Not redundant with the conditional import: this file only loads on
    // `dart.library.io` targets, but `Player.platform` is still a field this
    // codebase treats defensively elsewhere (see `audio_language_native.dart`).
    if (platform is! NativePlayer) {
      return _staticNativeProfile;
    }

    final raw = await platform.getProperty('decoder-list');
    final codecs = _parseDecoderList(raw);
    if (codecs.isEmpty) return _staticNativeProfile;

    final videoCodecs =
        codecs.where(_staticNativeProfile.videoCodecs.contains).toList();
    final audioCodecs =
        codecs.where(_staticNativeProfile.audioCodecs.contains).toList();

    // A profile that lists containers but no codecs of one kind would tell
    // the server everything of that kind needs transcoding. Whole-profile
    // fallback is safer than a half-narrowed one.
    if (videoCodecs.isEmpty || audioCodecs.isEmpty) {
      return _staticNativeProfile;
    }

    // Containers and HDR formats are not in `decoder-list`; mpv demuxes far
    // more than it decodes, so the static lists remain correct for those.
    return DeviceProfile(
      containers: _staticNativeProfile.containers,
      videoCodecs: videoCodecs,
      audioCodecs: audioCodecs,
      hdrFormats: _staticNativeProfile.hdrFormats,
    );
  } catch (error, stackTrace) {
    debugPrint('Decoder probe failed, using the static profile: $error');
    debugPrintStack(stackTrace: stackTrace);
    return _staticNativeProfile;
  } finally {
    // Always reached: on the early `NativePlayer` return, on either fallback,
    // on success, and on a throw caught above. A leaked probe player is the
    // kind of thing that only shows up much later as a resource leak.
    await player?.dispose();
  }
}

/// Pulls codec names out of mpv's `decoder-list` JSON.
///
/// Shape is unverified, so this accepts a list of objects with a `codec` key
/// and ignores anything else rather than throwing.
List<String> _parseDecoderList(String raw) {
  if (raw.isEmpty) return const [];

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];

    return decoded
        .whereType<Map<String, dynamic>>()
        .map((entry) => entry['codec'])
        .whereType<String>()
        .map((codec) => codec.toLowerCase())
        .toSet()
        .toList();
  } catch (_) {
    return const [];
  }
}
