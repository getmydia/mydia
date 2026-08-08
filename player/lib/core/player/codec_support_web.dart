/// Web implementation using browser APIs for codec detection.
library;

import 'dart:js_interop';

/// JavaScript interop for MediaSource API
@JS('MediaSource')
external JSFunction? get _mediaSourceConstructor;

@JS('MediaSource.isTypeSupported')
external bool _mediaSourceIsTypeSupported(String type);

/// JavaScript interop for ManagedMediaSource, the iOS 17.1+ equivalent of
/// MediaSource. Apple grants MSE only to Safari's own HLS engine; every other
/// browser on iOS (all of them WebKit under the hood) gets ManagedMediaSource
/// instead, so hls.js has to check both.
@JS('ManagedMediaSource')
external JSFunction? get _managedMediaSourceConstructor;

/// JavaScript interop for HTMLVideoElement.canPlayType
@JS()
@staticInterop
class _HTMLVideoElement {}

extension _HTMLVideoElementExtension on _HTMLVideoElement {
  external String canPlayType(String type);
}

@JS('document.createElement')
external _HTMLVideoElement _createElement(String tagName);

/// Check if MediaSource API is available
bool get _hasMediaSource => _mediaSourceConstructor != null;

/// Check if ManagedMediaSource API is available
bool get _hasManagedMediaSource => _managedMediaSourceConstructor != null;

/// Whether this browser has what hls.js needs to play HLS at all.
///
/// hls.js is built on the Media Source Extensions API, either the standard
/// `MediaSource` or its iOS 17.1+ counterpart `ManagedMediaSource`. Neither
/// existing means hls.js cannot work here, full stop — this is the
/// pre-flight check that catches that before a streaming session is even
/// requested, rather than failing inscrutably once playback starts.
bool get hasHlsMediaSourceSupport => _hasMediaSource || _hasManagedMediaSource;

/// Check if a MIME type with codecs is supported for playback.
///
/// Uses MediaSource.isTypeSupported() for MSE-based playback (HLS.js),
/// falls back to HTMLVideoElement.canPlayType() for direct playback.
bool isTypeSupported(String mimeType) {
  // First try MediaSource.isTypeSupported for MSE compatibility
  if (_hasMediaSource) {
    try {
      return _mediaSourceIsTypeSupported(mimeType);
    } catch (_) {
      // Fall through to canPlayType
    }
  }

  // Fall back to canPlayType for direct playback support
  try {
    final video = _createElement('video');
    final result = video.canPlayType(mimeType);
    // canPlayType returns '', 'maybe', or 'probably'
    return result == 'probably' || result == 'maybe';
  } catch (_) {
    return false;
  }
}

/// Check if a specific video codec is supported.
///
/// Tests common container+codec combinations.
bool isVideoCodecSupported(String codec) {
  // Test with MP4 container for most codecs
  final testTypes = [
    'video/mp4; codecs="$codec"',
    'video/webm; codecs="$codec"',
  ];

  for (final type in testTypes) {
    if (isTypeSupported(type)) {
      return true;
    }
  }
  return false;
}

/// Check if a specific audio codec is supported.
bool isAudioCodecSupported(String codec) {
  final testTypes = [
    'audio/mp4; codecs="$codec"',
    'audio/webm; codecs="$codec"',
  ];

  for (final type in testTypes) {
    if (isTypeSupported(type)) {
      return true;
    }
  }
  return false;
}

/// Check if the platform supports HLS playback.
///
/// On web, HLS is supported via hls.js library which is included in the player.
bool get supportsHls => true;

/// Check if the platform supports fMP4 (fragmented MP4) playback.
bool get supportsFmp4 {
  // Check for fMP4 support via MSE
  return isTypeSupported('video/mp4; codecs="avc1.42E01E"');
}

/// Check if the platform supports direct file playback.
///
/// Web has limited direct play support compared to native.
bool get supportsDirectPlay {
  // Check basic MP4/H.264 support
  return isTypeSupported('video/mp4; codecs="avc1.42E01E, mp4a.40.2"');
}
