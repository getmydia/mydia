/// What Android's MediaCodec can actually open, as profile conditions.
///
/// This exists because libmpv's `decoder-list` cannot answer the question the
/// server asks. That list is libavcodec's *build* configuration: it reports
/// `hevc` on any build compiled with the HEVC decoder, which is every build
/// Mydia ships. On a Fire HD 10 whose MediaTek decoder opens HEVC Main and
/// refuses Main 10, the client still claimed `hevc`, the server direct-played a
/// 10-bit stream, and mpv failed at `avcodec_open2` with "Could not open
/// codec." — audio decoded fine, so sound played under an error screen.
///
/// Software decoding is deliberately not treated as a rescue. mpv can decode
/// 10-bit HEVC in software, but not at 1080p on the class of SoC that lacks a
/// Main 10 hardware decoder, so advertising it would trade an error screen for
/// unwatchable stutter. Asking the server to transcode is the better answer,
/// and it is the answer this client gave before device profiles existed.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'codec_profile.dart';

const MethodChannel _channel = MethodChannel('dev.mydia.player/codecs');

/// Builds codec profiles from the platform's decoder capability tables.
///
/// Returns an empty list on any failure, which leaves the codec claims
/// unconstrained — the behavior that shipped before this probe existed. That is
/// the wrong direction for safety, but the right one for availability: a device
/// whose capability table cannot be read should still be able to watch
/// something, and a wrong `hevc` claim is recoverable in a way that refusing
/// every codec is not.
Future<List<CodecProfile>> probeAndroidCodecProfiles({
  MethodChannel channel = _channel,
}) async {
  try {
    final raw =
        await channel.invokeListMethod<dynamic>('videoDecoderCapabilities');
    if (raw == null || raw.isEmpty) return const [];

    final profiles = <CodecProfile>[];

    for (final entry in raw) {
      if (entry is! Map) continue;

      final codec = entry['codec'];
      if (codec is! String || codec.isEmpty) continue;

      final conditions = _conditionsFor(entry);
      if (conditions.isEmpty) continue;

      profiles.add(CodecProfile.video(codec, conditions));
    }

    return profiles;
  } catch (error, stackTrace) {
    debugPrint(
        'MediaCodec probe failed, leaving codec claims unconstrained: $error');
    debugPrintStack(stackTrace: stackTrace);
    return const [];
  }
}

List<ProfileCondition> _conditionsFor(Map<dynamic, dynamic> entry) {
  final conditions = <ProfileCondition>[];

  final depth = _positiveInt(entry['maxBitDepth']);
  if (depth != null) {
    conditions.add(
      ProfileCondition.atMost(ProfileProperty.videoBitDepth, '$depth'),
    );
  }

  // Resolution ceilings are advisory rather than required: a decoder's reported
  // maximum is per-codec and vendors under-report it, and a file that merely
  // exceeds a soft cap usually still plays. Marking them optional means a file
  // with no width/height recorded is not pushed to a transcode over a limit
  // nobody could check.
  final width = _positiveInt(entry['maxWidth']);
  if (width != null) {
    conditions.add(
      ProfileCondition.atMost(ProfileProperty.width, '$width',
          isRequired: false),
    );
  }

  final height = _positiveInt(entry['maxHeight']);
  if (height != null) {
    conditions.add(
      ProfileCondition.atMost(ProfileProperty.height, '$height',
          isRequired: false),
    );
  }

  return conditions;
}

int? _positiveInt(Object? value) {
  if (value is int && value > 0) return value;
  return null;
}
