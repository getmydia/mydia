import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../domain/models/media_segment.dart';
import '../../widgets/video_controls/skip_segment_button.dart'
    show SegmentSkipTracker;

/// The skippable intro/credits segments for the file being played, and the
/// once-per-media record of which ones were skipped automatically.
class SegmentSkipper {
  /// Skippable intro/credits segments for the file being played, as reported
  /// by the server. Empty whenever detection has not run, found nothing, or
  /// the query failed: an older server has no `segments` field at all, and
  /// that must degrade to "no skip button", never to a playback error.
  List<MediaSegment> _segments = const [];

  /// Once-per-playback record of automatic skips. Reset when the media
  /// changes, not when a seek restarts the HLS session, so a restart mid-intro
  /// cannot re-arm a skip the viewer already overrode.
  final SegmentSkipTracker _tracker = SegmentSkipTracker();

  /// Identifies the media [_tracker] is currently armed for. See
  /// [resetIfMediaChanged].
  String? _mediaKey;

  /// Whether detected segments are skipped without asking. Off unless the
  /// viewer opted in; loaded once when the screen initializes and deliberately
  /// not watched, since flipping it mid-episode is not a case worth a rebuild.
  bool autoSkip = false;

  List<MediaSegment> get segments => _segments;

  /// Drops the previous media's segments and re-arms the once-per-session
  /// skip guard, but only when [mediaKey] differs from the media it is armed
  /// for. Returns whether it did.
  ///
  /// The comparison, not the clearing, is the load-bearing half. This runs on
  /// every player initialization, and a seek past the transcoded end
  /// restarts the whole session for the *same* file. Resetting unconditionally
  /// would let auto-skip fire a second time on a segment the viewer had
  /// deliberately seeked back into, which is precisely what the guard exists
  /// to prevent.
  bool resetIfMediaChanged(String mediaKey) {
    if (_mediaKey == mediaKey) return false;
    _mediaKey = mediaKey;
    _segments = const [];
    _tracker.reset();
    return true;
  }

  void setSegments(List<MediaSegment> segments) => _segments = segments;

  /// The auto-skip decision, in real media coordinates.
  ///
  /// Shared by local playback and casting because only the two ends differ:
  /// where a position comes from, and what a seek means. The preference, the
  /// once-per-session tracker and the segment lookup are one rule, and a
  /// second copy of it is the thing that would drift.
  void maybeAutoSkip(Duration position, Future<void> Function(Duration) seek) {
    if (!autoSkip || _segments.isEmpty) return;

    final target = _tracker.takeAutoSkip(_segments, position);
    if (target == null) return;

    debugPrint('[PlayerScreen] Auto-skipping to ${target.end}');
    unawaited(seek(target.end));
  }

  /// The segment covering [position], or null when playback is between them.
  MediaSegment? segmentAt(Duration position) {
    for (final segment in _segments) {
      if (segment.containsPosition(position)) return segment;
    }
    return null;
  }
}
