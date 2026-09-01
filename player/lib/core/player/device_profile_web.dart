/// Web device profile: asks this browser what it decodes.
///
/// The probe itself, and the reasoning behind every codec string in it, lives
/// in `web_codec_probe.dart` — kept separate so it can be tested on the Dart
/// VM, which cannot load the `dart:js_interop` call below.
library;

import 'package:flutter/foundation.dart';

import 'codec_support_web.dart' show isTypeSupported;
import 'device_profile.dart';
import 'web_codec_probe.dart';

Future<DeviceProfile> detectDeviceProfile() async {
  final profile = buildWebDeviceProfile(_probe);

  // Logged for the same reason the Android probe logs its constraints: a
  // browser that claims a codec it cannot open is indistinguishable, from
  // every other log, from one that can.
  debugPrint(
    '[DeviceProfile] browser codecs: '
    'video=${profile.videoCodecs.join(",")} '
    'audio=${profile.audioCodecs.join(",")} '
    'constraints=${profile.codecProfiles.isEmpty ? "none" : profile.codecProfiles.join(", ")}',
  );

  return profile;
}

/// A probe that treats a throwing browser as "no".
///
/// `isTypeSupported` already falls back from `MediaSource` to `canPlayType`,
/// but a browser with neither must not take the whole profile down: one codec
/// answering false costs a transcode, while an exception escaping here would
/// leave the client with no profile at all.
bool _probe(String mimeType) {
  try {
    return isTypeSupported(mimeType);
  } catch (_) {
    return false;
  }
}
