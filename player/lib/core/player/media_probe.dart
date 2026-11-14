import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/files/backend/file_system_backend.dart';
import 'media_probe_stub.dart' if (dart.library.io) 'media_probe_native.dart'
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

/// Runs probes one at a time, process wide, and turns every failure into null.
class SerializedMediaProbe implements MediaProbe {
  SerializedMediaProbe(this._inner);

  final MediaProbe _inner;
  Future<void> _tail = Future<void>.value();

  @override
  Future<ProbeResult?> probe(
    PlayableFile playable, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    final result = _tail.then<ProbeResult?>((_) async {
      try {
        return await _inner.probe(playable, timeout: timeout);
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
