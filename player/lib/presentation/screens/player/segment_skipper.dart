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

  /// Whether intros and credits are skipped without asking. Off unless the
  /// viewer opted in; loaded once when the screen initializes and deliberately
  /// not watched, since flipping it mid-episode is not a case worth a rebuild.
  bool autoSkipIntroCredits = false;

  /// Whether commercial breaks are skipped without asking. On unless the
  /// viewer opted out, loaded the same way as [autoSkipIntroCredits].
  bool autoSkipCommercials = true;

  /// Whether the stored auto-skip choices have been applied. Nothing is
  /// skipped automatically before then: [autoSkipCommercials] starts on, and
  /// a position tick that beat the storage read would otherwise skip a break
  /// the viewer opted out of. Set once per screen, not reset per media.
  bool _preferencesLoaded = false;

  /// Marks the stored choices as applied (or as unreadable, in which case the
  /// defaults stand). Call it when the read completes, success or not.
  void preferencesLoaded() => _preferencesLoaded = true;

  bool _autoSkips(MediaSegment segment) => switch (segment.type) {
    SegmentType.commercial => autoSkipCommercials,
    SegmentType.intro || SegmentType.credits => autoSkipIntroCredits,
    SegmentType.unknown => false,
  };

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
    if (!_preferencesLoaded || _segments.isEmpty) return;

    final target = _tracker.takeAutoSkip(_segments.where(_autoSkips), position);
    if (target == null) return;

    debugPrint('[PlayerScreen] Auto-skipping to ${target.end}');
    unawaited(seek(target.end));
  }

  /// The segment covering [position], or null when playback is between them.
  ///
  /// When segments overlap (a commercial break inside a long intro), the one
  /// that started latest wins: it is the innermost, so its button shows for
  /// its span and the outer segment's button returns once it ends.
  MediaSegment? segmentAt(Duration position) {
    MediaSegment? found;
    for (final segment in _segments) {
      if (!segment.containsPosition(position)) continue;
      if (found == null || segment.startMs > found.startMs) found = segment;
    }
    return found;
  }
}
