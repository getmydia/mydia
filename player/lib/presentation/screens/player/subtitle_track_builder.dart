import '../../../domain/models/subtitle_track.dart';

/// Which subtitle tracks the user may pick from, given the delivery mode.
///
/// Image-based tracks (PGS, VobSub) are bitmaps. In direct play the media
/// engine reads them straight from the container and renders them natively,
/// so they stay selectable. When streaming, the server can only hand back
/// text, so only [SubtitleTrack.deliverable] tracks are offered.
///
/// This filter runs before any subtitle body has been fetched: [content] is
/// resolved lazily, once, when the viewer actually selects a track (see
/// `_resolveMediaKitSubtitleTrack` in `player_screen.dart`), never here. A
/// filter that inspected `content` at this stage would drop every
/// streaming-eligible track before the viewer got a chance to pick one.
List<SubtitleTrack> selectableTracks(
  List<SubtitleTrack> tracks, {
  required bool isDirectPlay,
}) {
  if (isDirectPlay) return tracks;

  return tracks.where((t) => t.deliverable).toList();
}

/// Whether an in-flight subtitle selection's result should still be applied
/// to the player, once its async work (a media_kit "Off" call, or a
/// `SubtitleContent` fetch) finishes.
///
/// `player_screen.dart`'s `_showSubtitleSelector` does real async work per
/// selection, and the tap that starts it is fire-and-forget from a sheet
/// that has already closed, so a second selection (including "Off") can
/// start before an earlier one's async work resolves. Whichever one's work
/// happens to finish last must not automatically win — only the most
/// *recently requested* selection may ever reach the player or
/// `_selectedSubtitleTrack`. This predicate is the single decision that
/// enforces that, called after every await in `_showSubtitleSelector`
/// rather than reimplemented at each one with a different subset of these
/// checks (which is what let the third check point in that function go
/// missing entirely in an earlier revision — see the Task 14 fix report).
///
/// Pure and independent of `Player`/`GraphQLClient`/`State` on purpose: the
/// race itself is fully described by these four values, so testing it
/// needs none of the infrastructure the surrounding async code does.
///
/// Discards (returns `false`) whenever:
///  - [requestGeneration] no longer equals [currentGeneration]: a later
///    selection has already been requested, and this one has been
///    superseded by it;
///  - [mounted] is false: the screen was disposed while this selection's
///    async work was in flight;
///  - [hasPlayer] is false: there is no player left to apply the result to
///    (e.g. mid-`_restartLocalPlayback`, which clears the player without
///    unmounting the screen, so [mounted] alone would not catch it).
bool shouldApplySubtitleSelection({
  required int requestGeneration,
  required int currentGeneration,
  required bool mounted,
  required bool hasPlayer,
}) {
  return requestGeneration == currentGeneration && mounted && hasPlayer;
}
