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

/// The subtitle tracks to offer the viewer, given both places they can come
/// from.
///
/// [serverTracks] is what `MediaFileFragment` reported: embedded tracks
/// ffprobe found, plus sidecars from the database. [mpvTracks] is what
/// media_kit has probed out of the container so far, already mapped onto
/// this app's model with `mk_`-prefixed ids.
///
/// Three cases:
///
///  - **Streaming.** The server is the only source that means anything --
///    every body arrives as text over GraphQL -- so media_kit's list is
///    ignored and image tracks are filtered out.
///  - **Direct play, media_kit has tracks.** Its tracks win: it reads them
///    from the container at no fetch cost, including image-based ones it
///    renders natively. Sidecars are not in the container, so those still
///    come from [serverTracks].
///  - **Direct play, media_kit has nothing yet.** Fall back to the server's
///    deliverable tracks. mpv discovers tracks asynchronously while it
///    probes, so on a remote file the probe routinely finishes after the
///    fixed sample taken just after `open()`. Before this fallback existed
///    that left the list empty and `panel_controls.dart`'s
///    `subtitleTrackCount > 0` gate rendered the subtitle button
///    permanently dead. Selecting one of these fetches its body over the
///    `SubtitleContent` query, the same path sidecars already take; image
///    tracks are dropped because there is no body to fetch for a bitmap.
///
/// The two lists are never merged into one. ffprobe stream indices and
/// media_kit's own track ids do not correspond, so a merge would list every
/// embedded track twice.
List<SubtitleTrack> resolveSubtitleTracks({
  required List<SubtitleTrack> serverTracks,
  required List<SubtitleTrack> mpvTracks,
  required bool isDirectPlay,
}) {
  if (isDirectPlay && mpvTracks.isNotEmpty) {
    return [
      ...mpvTracks,
      ...serverTracks.where((t) => !t.embedded && t.deliverable),
    ];
  }

  return selectableTracks(serverTracks, isDirectPlay: false);
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

/// Whether a tap on the subtitle sheet should start a new selection
/// attempt, or be treated as a no-op.
///
/// Compared against [pending] — the target of whichever selection attempt
/// is already in flight, tracked separately from what has actually been
/// applied to the player (`_selectedSubtitleTrack` in `player_screen.dart`)
/// — not against the applied value itself. A tap repeating an in-flight
/// attempt's own target (a retry, or a cancel back to whatever's still
/// displayed as current while that attempt resolves) is a no-op; a tap
/// naming anything else, including a target that matches what's *already
/// applied*, starts a fresh attempt.
///
/// This is the other half of the fix [pendingSubtitleSelectionAfterFailure]
/// is for: comparing against a pending value that a failed attempt never
/// clears would make every retry of that attempt read as a no-op forever.
bool shouldStartSubtitleSelection({
  required SubtitleTrack? requested,
  required SubtitleTrack? pending,
  required bool mounted,
}) {
  if (!mounted) return false;
  return requested != pending;
}

/// What the pending selection target should become when an attempt
/// concludes without applying — a failed fetch, the player disappearing
/// mid-attempt, or the attempt having been superseded before it got that
/// far.
///
/// If [requestGeneration] no longer matches [currentGeneration], a newer
/// attempt has already been requested and now owns the pending value: this
/// returns [currentPending] unchanged, because overwriting it here would
/// clobber that newer attempt's own target with this, older one's.
/// Otherwise this attempt is the one that set [currentPending] in the
/// first place — nothing else could have without also bumping the
/// generation — so this falls the tracker back to [appliedSelection],
/// what is actually true on the player right now, rather than leaving it
/// pointed at a target this attempt never reached.
///
/// Without this, a tap repeating that unreached target reads as a no-op
/// forever (see [shouldStartSubtitleSelection]), and a genuine retry
/// becomes impossible without picking something else first — exactly the
/// regression this function exists to close: a failed `SubtitleContent`
/// fetch (a dropped connection, a server error) left the pending target
/// stuck at the track that just failed, so re-tapping it after the
/// "could not load" snackbar was a silent no-op.
SubtitleTrack? pendingSubtitleSelectionAfterFailure({
  required int requestGeneration,
  required int currentGeneration,
  required SubtitleTrack? currentPending,
  required SubtitleTrack? appliedSelection,
}) {
  if (requestGeneration != currentGeneration) return currentPending;
  return appliedSelection;
}

/// The subtitle delay to hand mpv right now, in milliseconds.
///
/// Three values, one subtraction:
///
///  - [storedOffsetMs] is what the server has persisted for this track,
///    fetched by the `subtitleTrackSettings` query.
///  - [bakedOffsetMs] is what the server already shifted into the body
///    currently loaded. It equals [storedOffsetMs] for a track fetched over
///    `SubtitleContent`, because `Delivery.content/3` applies the offset
///    before returning, and it is zero for an mpv-native track that mpv read
///    out of the container itself, which the server never saw.
///  - [nudgeMs] is the live, unsaved adjustment from the +/- controls. It
///    resets to zero on track change.
///
/// Subtracting [bakedOffsetMs] is what prevents a double-apply. A
/// server-shifted body plus an mpv `sub-delay` of the same magnitude would be
/// wrong by twice the offset, in the direction that reads as "the feature is
/// broken" rather than "the feature is missing".
///
/// It also makes saving cheap. Persisting sets `storedOffsetMs += nudgeMs`
/// and `nudgeMs = 0`, which leaves this expression at exactly the same
/// value, so nothing refetches, nothing flickers, and the OSD number does
/// not jump.
int effectiveSubtitleDelayMs({
  required int storedOffsetMs,
  required int bakedOffsetMs,
  required int nudgeMs,
}) {
  return storedOffsetMs - bakedOffsetMs + nudgeMs;
}

/// Whether [trackId] identifies a track media_kit read straight out of the
/// container, rather than one the server has ever touched.
///
/// `player_screen.dart`'s `_applySubtitleTracks` is the only place that
/// mints an id in this shape (`'mk_${mkTrack.id}'`), so the prefix alone is
/// sufficient. Checking `_mediaKitSubtitleTrackMap` for membership instead
/// is NOT reliable for this: `_resolveMediaKitSubtitleTrack` adds a
/// content-fetched track to that same map, under its own non-`mk_` id, once
/// resolved -- so by the time a selection has succeeded the map holds both
/// kinds of track and membership alone no longer tells them apart.
bool isMpvNativeSubtitleTrackId(String trackId) => trackId.startsWith('mk_');

/// Whether the subtitle sheet's Save button should be offered for
/// [trackId]. `null` (no track selected) is never savable.
///
/// False for an mpv-native track ([isMpvNativeSubtitleTrackId]). The
/// server's `trackRef` for an embedded track means its ffprobe stream
/// index, but an mpv-native track's id is media_kit's own container-local
/// one (`'mk_${mkTrack.id}'`) -- a different id space the codebase already
/// documents as not corresponding (see `resolveSubtitleTracks`'s dartdoc).
/// Persisting a correction under that id would key it to something the
/// next session's mpv probe has no reason to reproduce, so the save would
/// silently not carry forward -- worse than the button being absent,
/// because it reports success. Mapping the id back to a stream index
/// heuristically (by language, title, or position) was considered and
/// rejected for the same reason: a wrong guess would attach the offset to
/// the wrong track. The live delay still applies for the current session
/// regardless of this -- only persistence is unavailable.
bool canSaveSubtitleDelay(String? trackId) =>
    trackId != null && !isMpvNativeSubtitleTrackId(trackId);

/// What the subtitle sheet's delay row should show, or `null` to hide it
/// entirely.
///
/// Two independent reasons to hide it: no track is selected ([trackId] is
/// null, the "Off" state), or [offsetsLoaded] is false, meaning the
/// `subtitleTrackSettings` query has not yet succeeded even once for this
/// media file. The second case matters because an empty stored-offsets map
/// looks identical whether nothing has ever been saved for this file or the
/// query simply failed (an older server, a network blip) -- showing Save in
/// that case would let it persist just the viewer's live nudge on top of an
/// assumed-zero baseline, silently discarding whatever offset the server
/// actually has on file. See [effectiveSubtitleDelayMs]'s dartdoc for the
/// stored/baked relationship this would otherwise corrupt.
int? subtitleDelayDisplayMs({
  required String? trackId,
  required bool offsetsLoaded,
  required int storedOffsetMs,
  required int nudgeMs,
}) {
  if (trackId == null || !offsetsLoaded) return null;
  return storedOffsetMs + nudgeMs;
}

/// What the OSD snackbar should say right after a `z`/`shift+z` nudge (or a
/// sheet stepper tap), given the new total delay in [totalMs].
///
/// [appliesImmediately] is `false` on web: `applySubtitleDelay` is a genuine
/// no-op there (media_kit's web backend has no mpv `sub-delay` property to
/// set), and the body a web viewer sees always comes pre-baked from the
/// `SubtitleContent` query -- Save, followed by a refetch, is the only web
/// path that actually moves anything. `_subtitleNudgeMs` is still tracked and
/// still contributes to what Save persists, so the nudge itself is not
/// dropped on web; only the wording changes, to stop claiming a visible
/// change that has not happened yet.
String subtitleDelaySnackBarMessage({
  required int totalMs,
  required bool appliesImmediately,
}) {
  final signed = '${totalMs >= 0 ? '+' : ''}$totalMs ms';
  if (appliesImmediately) return 'Subtitle delay $signed';
  return 'Subtitle delay will be $signed after Save';
}
