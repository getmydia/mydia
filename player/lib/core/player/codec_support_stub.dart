/// Stub implementation for native platforms.
///
/// On native platforms, media_kit handles most codec detection internally,
/// so we use a more permissive approach based on known platform capabilities.
library;

/// Check if a MIME type with codecs is supported for playback.
///
/// On native platforms, this returns true for common formats since
/// media_kit uses FFmpeg which supports most codecs.
bool isTypeSupported(String mimeType) {
  // media_kit with FFmpeg supports almost all common codecs
  // We're more permissive on native since FFmpeg handles decoding
  return true;
}

/// Check if a specific video codec is supported.
bool isVideoCodecSupported(String codec) {
  // FFmpeg supports virtually all video codecs
  return true;
}

/// Check if a specific audio codec is supported.
bool isAudioCodecSupported(String codec) {
  // FFmpeg supports virtually all audio codecs
  return true;
}

/// Check if the platform supports HLS playback.
bool get supportsHls => true;

/// Check if the platform supports fMP4 (fragmented MP4) playback.
bool get supportsFmp4 => true;

/// Check if the platform supports direct file playback.
bool get supportsDirectPlay => true;

/// Whether this browser has what hls.js needs (`MediaSource` or
/// `ManagedMediaSource`).
///
/// Always true on native: media_kit talks to mpv/FFmpeg directly here, never
/// a browser HLS player, so there is no MSE dependency to check.
bool get hasHlsMediaSourceSupport => true;

/// Whether media_kit will hand this browser's own HLS engine the manifest
/// instead of running it through hls.js.
///
/// Always false on native: there is no browser here, and media_kit plays HLS
/// through mpv/FFmpeg, which has no such fork.
bool get prefersNativeHls => false;
