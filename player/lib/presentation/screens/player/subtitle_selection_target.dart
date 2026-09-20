/// What a subtitle selection attempt is trying to reach.
///
/// Exists because `SubtitleTrack?` cannot say the one thing the sheet's no-op
/// guard has to know. The guard compares a tap against the target of whatever
/// attempt is already in flight, and with a bare nullable track "no attempt is
/// in flight" and "an attempt targeting Off is in flight" are both `null`. A
/// viewer with nothing applied who taps Off therefore requested exactly what
/// the tracker already held, and the tap was dropped before it could be
/// applied or remembered.
///
/// The same bug, one layer up, is why [SubtitleTrackSelection] exists: the
/// sheet used to return a bare `SubtitleTrack?` and a dismissal was
/// indistinguishable from choosing Off.
///
/// The rule the whole fix rests on, and the one to keep when editing any
/// writer of `_pendingSubtitleSelection`:
///
///   `null` means no attempt is in flight. Every write that means "an attempt
///   targeting X" is non-null.
///
/// Pure and free of `Player`, `GraphQLClient` and `State`, like its
/// neighbours in `subtitle_track_builder.dart`, so the race it describes can
/// be tested without any of the infrastructure the async code needs.
library;

import '../../../domain/models/subtitle_track.dart';

sealed class SubtitleSelectionTarget {
  const SubtitleSelectionTarget();
}

/// Subtitles off. A real target, not an absence: an explicit Off has to beat
/// mpv's own default-disposition pick, and has to be remembered for the show.
final class TargetOff extends SubtitleSelectionTarget {
  const TargetOff();

  @override
  bool operator ==(Object other) => other is TargetOff;

  @override
  int get hashCode => (TargetOff).hashCode;
}

/// A specific track.
///
/// Equality is the track's, which `SubtitleTrack.operator ==` defines by id.
/// That is the granularity every other selection path already keys on, so a
/// revision that changes only a title does not read as a different target.
final class TargetTrack extends SubtitleSelectionTarget {
  const TargetTrack(this.track);

  final SubtitleTrack track;

  @override
  bool operator ==(Object other) =>
      other is TargetTrack && other.track == track;

  @override
  int get hashCode => track.hashCode;
}
