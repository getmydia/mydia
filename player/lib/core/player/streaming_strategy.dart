import 'package:flutter/foundation.dart' show kIsWeb;

/// Streaming strategies available from the server
enum StreamingStrategy {
  /// Direct playback without transcoding (requires compatible codecs)
  directPlay('DIRECT_PLAY'),

  /// Remux to fMP4 container without re-encoding (same codecs, different container)
  remux('REMUX'),

  /// HLS streaming with codec copy (no transcoding)
  hlsCopy('HLS_COPY'),

  /// HLS streaming with transcoding to H264/AAC
  transcode('TRANSCODE');

  const StreamingStrategy(this.value);
  final String value;

  /// Parse a strategy from its string value
  static StreamingStrategy? fromValue(String value) {
    for (final strategy in StreamingStrategy.values) {
      if (strategy.value == value) {
        return strategy;
      }
    }
    return null;
  }

  @override
  String toString() => value;
}

/// Service to determine optimal streaming strategy based on platform and codec support
class StreamingStrategyService {
  /// Determine the optimal streaming strategy for web platform
  ///
  /// Web browsers have limited codec support compared to native platforms.
  /// This method returns the best strategy based on:
  /// - Platform (web vs native)
  /// - Browser capabilities (though media_kit handles this internally)
  /// - HLS support via hls.js
  static StreamingStrategy getOptimalStrategy({
    bool forceHls = false,
  }) {
    // On web, prefer HLS for better compatibility and adaptive streaming
    if (kIsWeb || forceHls) {
      // Use HLS_COPY first (no transcoding, faster startup)
      // The server will fall back to TRANSCODE if codecs aren't compatible
      return StreamingStrategy.hlsCopy;
    }

    // On native platforms, direct play is more efficient
    return StreamingStrategy.directPlay;
  }

  /// Build a stream URL with the specified strategy
  static String buildStreamUrl({
    required String serverUrl,
    required String fileId,
    required StreamingStrategy strategy,
    String? mediaToken,
  }) {
    final url =
        '$serverUrl/api/v1/stream/file/$fileId?strategy=${strategy.value}';

    // Append token if provided (for claim code mode)
    // Server expects 'token' query parameter, not 'media_token'
    if (mediaToken != null) {
      return '$url&token=$mediaToken';
    }

    return url;
  }

  /// Check if HLS is supported on this platform
  static bool get isHlsSupported {
    // HLS is supported on web via hls.js, which media_kit bundles as a
    // package asset (assets/packages/media_kit/assets/web/hls1.4.10.js) and
    // loads itself, same-origin, with no CDN and no index.html changes
    // needed, and natively on iOS/Safari.
    return true; // media_kit handles platform-specific implementation
  }

  /// Check if adaptive bitrate streaming is available
  static bool get supportsAdaptiveBitrate {
    // HLS provides adaptive bitrate streaming
    // Direct play does not
    return kIsWeb;
  }

  /// Get human-readable strategy description
  static String getStrategyDescription(StreamingStrategy strategy) {
    switch (strategy) {
      case StreamingStrategy.directPlay:
        return 'Direct Play';
      case StreamingStrategy.remux:
        return 'Remux (fMP4)';
      case StreamingStrategy.hlsCopy:
        return 'HLS (Stream Copy)';
      case StreamingStrategy.transcode:
        return 'HLS (Transcoded)';
    }
  }
}
