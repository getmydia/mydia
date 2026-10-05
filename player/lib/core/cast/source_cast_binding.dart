/// The seam between the cast session and a third-party source. The session
/// manager lives in `core/` and the source playback sessions in
/// `presentation/`, so the manager only sees this interface.
library;

import '../../domain/models/cast_device.dart';
import '../player/periodic_progress_reporter.dart';
import '../player/progress_service.dart';
import '../player/stream_timeline.dart';
import 'cast_content.dart';
import 'cast_route_resolver.dart';

/// Where a source cast's position goes.
abstract interface class CastProgressSink {
  /// One position report. Watched is sent the first time [position] crosses
  /// the threshold.
  Future<void> report({
    required Duration position,
    required Duration duration,
    required bool paused,
  });

  /// The cast ended. Reports the last position, once.
  Future<void> stopped();
}

/// Drives a source's own reporter from receiver positions instead of a
/// local `Player`.
class ReporterCastProgressSink implements CastProgressSink {
  ReporterCastProgressSink(this._reporter);

  final PeriodicProgressReporter _reporter;
  ({int positionSeconds, int durationSeconds})? _last;
  bool _watchedSent = false;
  bool _stopped = false;

  @override
  Future<void> report({
    required Duration position,
    required Duration duration,
    required bool paused,
  }) async {
    final sync =
        ProgressService.resolveSync(position, duration, StreamTimeline.zero);
    if (sync == null || _stopped) return;
    _last = sync;
    await _reporter.sendProgress(
      positionSeconds: sync.positionSeconds,
      durationSeconds: sync.durationSeconds,
      paused: paused,
    );
    if (!_watchedSent &&
        ProgressService.isWatchedAt(position, duration, StreamTimeline.zero)) {
      _watchedSent = true;
      await _reporter.sendWatched();
    }
  }

  @override
  Future<void> stopped() async {
    final last = _last;
    if (_stopped || last == null) return;
    _stopped = true;
    await _reporter.sendStopped(
      positionSeconds: last.positionSeconds,
      durationSeconds: last.durationSeconds,
    );
  }
}

/// One item on one source, ready to cast.
abstract interface class SourceCastBinding {
  /// A route the receiver can open directly: credential in the query,
  /// receiver codecs. [subtitleTrackId] matters only for a burned-in track.
  /// Throws `CastBackendException` when the source refuses.
  Future<CastRoute> resolve({
    required CastProtocolKind protocol,
    required Duration startPosition,
    required String? subtitleTrackId,
    required bool forceTranscode,
  });

  /// Ends a server-side transcode a [resolve] started.
  Future<void> endServerSession(String sessionId);

  /// A fresh progress sink for this item.
  CastProgressSink openProgress();
}

/// Builds the binding for [SourceCastContent]. Throws `CastBackendException`
/// when the source is gone, needs signing in again, or is locked.
typedef SourceCastBinder = Future<SourceCastBinding> Function(
    SourceCastContent content);
