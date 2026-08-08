import 'package:flutter/foundation.dart' show kIsWeb;

import 'codec_support_stub.dart'
    if (dart.library.js_interop) 'codec_support_web.dart' as platform;

/// Service to detect codec and format support on the current platform.
///
/// On web, this uses browser APIs (MediaSource.isTypeSupported, canPlayType).
/// On native platforms, this is more permissive since media_kit/FFmpeg
/// supports most codecs.
class CodecSupport {
  /// Check if a MIME type with codecs is supported for playback.
  ///
  /// Example: 'video/mp4; codecs="avc1.640028, mp4a.40.2"'
  static bool isTypeSupported(String mimeType) {
    return platform.isTypeSupported(mimeType);
  }

  /// Check if a specific video codec is supported.
  ///
  /// Example: 'avc1.640028' (H.264 High Profile)
  static bool isVideoCodecSupported(String codec) {
    return platform.isVideoCodecSupported(codec);
  }

  /// Check if a specific audio codec is supported.
  ///
  /// Example: 'mp4a.40.2' (AAC-LC)
  static bool isAudioCodecSupported(String codec) {
    return platform.isAudioCodecSupported(codec);
  }

  /// Check if the platform supports HLS playback.
  static bool get supportsHls => platform.supportsHls;

  /// Check if the platform supports fMP4 (fragmented MP4) playback.
  static bool get supportsFmp4 => platform.supportsFmp4;

  /// Check if the platform supports direct file playback.
  static bool get supportsDirectPlay => platform.supportsDirectPlay;

  /// Whether this browser has what hls.js needs (`MediaSource` or
  /// `ManagedMediaSource`). Always true on native.
  ///
  /// False identifies iOS Safari below 17.1: it has neither, so hls.js
  /// cannot work there. Callers should check this before starting a
  /// streaming session and point the viewer at the native app instead of
  /// letting playback fail once it is already underway.
  static bool get hasHlsMediaSourceSupport => platform.hasHlsMediaSourceSupport;

  /// Check if running on web platform.
  static bool get isWeb => kIsWeb;

  /// Check if running on native platform.
  static bool get isNative => !kIsWeb;
}
