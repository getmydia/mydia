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

  /// Whether media_kit will play HLS with the browser's own engine rather than
  /// hls.js. Always false on native.
  ///
  /// **This is a capability probe, not a support check.** True does not mean
  /// unplayable, and it must not be used to refuse playback. Measured, not
  /// assumed:
  ///
  /// - Chromium 149 answers `canPlayType('application/vnd.apple.mpegurl')`
  ///   with `maybe`. This is therefore true on ordinary desktop Chrome, where
  ///   media_kit plays with `element.src` and no hls.js at all.
  /// - A `<video>` element pointed at a Service Worker-served manifest in that
  ///   same Chromium fetched both the manifest and its segment through the
  ///   worker. The native loader is not bypassing it.
  ///
  /// It is true on every WebKit browser too (macOS Safari, iOS Safari, and iOS
  /// Chrome/Firefox/Edge, which are WebKit underneath), and whether WebKit's
  /// loader also fetches through a Service Worker is the open question this
  /// probe exists to help answer. Answer it with the manual browser matrix
  /// before gating anything on it, and gate on the browser that actually
  /// fails rather than on this, which desktop Chrome shares.
  ///
  /// [hasHlsMediaSourceSupport] is the check that may be used to refuse: a
  /// browser with neither `MediaSource` nor `ManagedMediaSource` cannot run
  /// hls.js under any circumstances.
  static bool get prefersNativeHls => platform.prefersNativeHls;

  /// Check if running on web platform.
  static bool get isWeb => kIsWeb;

  /// Check if running on native platform.
  static bool get isNative => !kIsWeb;
}
