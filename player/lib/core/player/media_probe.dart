import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/files/backend/file_system_backend.dart';
import 'media_probe_stub.dart'
    if (dart.library.io) 'media_probe_native.dart'
    as platform;
import 'mpv_probe_mapping.dart';

/// Reads container, duration and track details from a file without playing it.
abstract interface class MediaProbe {
  /// Null when the file could not be probed (timeout, unsupported platform,
  /// unreadable file). Never throws.
  Future<ProbeResult?> probe(
    PlayableFile playable, {
    Duration timeout = const Duration(seconds: 15),
  });
}

/// Whether a decoded mpv `track-list` holds at least one real video, audio or
/// subtitle track. An empty list (file not loaded yet) is not ready.
bool hasRealTracks(Object? decodedTrackList) {
  if (decodedTrackList is! List) return false;
  return decodedTrackList.any(
    (t) =>
        t is Map &&
        (t['type'] == 'video' || t['type'] == 'audio' || t['type'] == 'sub'),
  );
}

/// Runs probes one at a time, process wide, and turns every failure into null.
class SerializedMediaProbe implements MediaProbe {
  SerializedMediaProbe(this._inner, {this.grace = const Duration(seconds: 5)});

  final MediaProbe _inner;

  /// How long past its own timeout an inner probe may take before it is
  /// abandoned.
  final Duration grace;
  Future<void> _tail = Future<void>.value();

  @override
  Future<ProbeResult?> probe(
    PlayableFile playable, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    final result = _tail.then<ProbeResult?>((_) async {
      try {
        // A probe that ignores its own deadline must not hold the lock.
        return await _inner
            .probe(playable, timeout: timeout)
            .timeout(timeout + grace);
      } on TimeoutException {
        debugPrint('[MediaProbe] probe stalled past its deadline');
        return null;
      } catch (error) {
        debugPrint('[MediaProbe] probe failed: $error');
        return null;
      }
    });
    _tail = result.then<void>((_) {});
    return result;
  }
}

/// The one probe the app uses. Serialized so only one headless player exists.
final mediaProbeProvider = Provider<MediaProbe>(
  (ref) => SerializedMediaProbe(platform.createPlatformMediaProbe()),
);
