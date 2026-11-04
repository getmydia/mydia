/// Which of HEVC, VP9 and AV1 this iOS device decodes in hardware.
///
/// libmpv's `decoder-list` is libavcodec's build configuration, so it claims
/// `hevc` on every iOS device. An iPad capped at iOS 15 (A8/A8X) has no HEVC
/// hardware decoder: the server direct-played 1080p HEVC, mpv decoded it in
/// software, and the device found out only from dropped frames about 20 s in.
///
/// As on Android, software decoding is deliberately not a rescue. On that class
/// of hardware it is stutter, so asking the server to transcode from the first
/// second is the better answer. Newer iPhones without AV1 hardware (before
/// A17 Pro) will transcode AV1; that is accepted.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_profile.dart';

const MethodChannel _channel = MethodChannel('dev.mydia.player/codecs');

/// Every spelling of a codec the static profile and the server's casts use.
const Map<String, List<String>> _aliases = {
  'hevc': ['hevc', 'h265', 'h.265', 'hvc1'],
  'vp9': ['vp9', 'vp09'],
  'av1': ['av1', 'av01'],
};

/// Removes the codecs iOS reports without hardware decode from [profile].
///
/// Narrows only when the probe returned a usable map, and only on an explicit
/// `false`: a codec absent from the answer is unknown and stays claimed. A
/// failed, empty or missing-plugin probe returns [profile] untouched, the same
/// availability-over-safety trade the Android probe makes. macOS and every
/// other platform are left alone, since desktops software-decode these fine.
///
/// [isIos] and [channel] are injectable for tests.
Future<DeviceProfile> applyIosHardwareDecode(
  DeviceProfile profile, {
  bool? isIos,
  MethodChannel channel = _channel,
}) async {
  if (!(isIos ?? Platform.isIOS)) return profile;

  final Map<String, bool> support;
  try {
    final raw = await channel.invokeMapMethod<String, dynamic>(
      'hardwareVideoDecoders',
    );
    if (raw == null || raw.isEmpty) return profile;
    support = {
      for (final codec in _aliases.keys)
        if (raw[codec] is bool) codec: raw[codec] as bool,
    };
  } catch (error) {
    debugPrint('iOS decode probe failed, leaving codec claims '
        'unconstrained: $error');
    return profile;
  }

  if (support.isEmpty) return profile;

  // Logged for the same reason as the Android line: a device claiming a codec
  // it cannot decode looks identical in every other log to one that can.
  debugPrint(
    '[DeviceProfile] ios hardware decode: '
    'hevc=${support['hevc'] ?? true} '
    'vp9=${support['vp9'] ?? true} '
    'av1=${support['av1'] ?? true}',
  );

  final removed = {
    for (final entry in support.entries)
      if (!entry.value) ..._aliases[entry.key]!,
  };
  if (removed.isEmpty) return profile;

  return DeviceProfile(
    containers: profile.containers,
    videoCodecs:
        profile.videoCodecs.where((c) => !removed.contains(c)).toList(),
    audioCodecs: profile.audioCodecs,
    hdrFormats: profile.hdrFormats,
    codecProfiles: profile.codecProfiles,
  );
}
