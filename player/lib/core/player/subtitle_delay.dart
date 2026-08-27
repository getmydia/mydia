import 'package:media_kit/media_kit.dart';

import 'subtitle_delay_stub.dart'
    if (dart.library.io) 'subtitle_delay_native.dart' as platform;

/// Sets mpv's `sub-delay` for the currently loaded subtitle track to
/// [delayMs].
///
/// A no-op on web, where there is no mpv to talk to. Mirrors
/// `audio_language.dart`, which reaches `setProperty` the same way and for
/// the same reason: media_kit's web `NativePlayer` is a stub class with no
/// `setProperty` at all, so a direct call would not compile for web.
Future<void> applySubtitleDelay(Player player, int delayMs) =>
    platform.applySubtitleDelay(player, delayMs);
