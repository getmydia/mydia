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
///    that left the list empty, so the sheet offered nothing and a viewer
///    had to go searching online for subtitles the file already carried.
///    Selecting one of these fetches its body over the
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

/// The mpv track id inside an mpv-native [trackId] (`'mk_2'` gives `'2'`),
/// or null for a server track. The key `subtitleStreamIndices` uses.
String? mpvIdOfSubtitleTrack(String trackId) =>
    isMpvNativeSubtitleTrackId(trackId) ? trackId.substring(3) : null;

/// Whether two tracks' language tags allow them to be the same stream.
///
/// Only a disagreement between two known tags rules a match out. `und`
/// (ffprobe's "undetermined") or a missing tag carries no evidence either
/// way, and container tags are the same ISO 639-2 codes on both sides.
bool subtitleLanguagesCompatible(String a, String b) {
  final left = a.trim().toLowerCase();
  final right = b.trim().toLowerCase();
  if (left.isEmpty || right.isEmpty || left == 'und' || right == 'und') {
    return true;
  }
  return left == right;
}

/// Shown when a restore after a source switch cannot find the viewer's
/// track on the new source.
const kSubtitleNotCarriedMessage =
    "Couldn't keep your subtitles at this quality. Pick them again.";

/// Shown when the viewer's track is an image format (PGS, VobSub) and the
/// new source is a transcode, which can only deliver text.
const kImageSubtitleUnavailableMessage =
    'Image-based subtitles only play at Original quality.';

/// The viewer's subtitle choice while a source switch carries it, in the
/// server's id space, which every source can resolve.
///
/// A source switch opens a new file. mpv drops a `sub-add`ed track when it
/// does, and media_kit resets its own record of the selection, so neither
/// can be asked afterwards what should be showing. This is that record.
sealed class SubtitleIntent {
  const SubtitleIntent();
}

/// The viewer chose "Off".
final class IntentOff extends SubtitleIntent {
  const IntentOff();
}

/// The viewer chose [track], a track from the server's list: a sidecar, a
/// downloaded subtitle, or an embedded stream (whose id is its ffprobe
/// stream index).
final class IntentTrack extends SubtitleIntent {
  final SubtitleTrack track;
  const IntentTrack(this.track);
}

/// The viewer chose an mpv-native track that could not be matched to any
/// server track, so no source but the one being left could show it.
final class IntentUnmappable extends SubtitleIntent {
  const IntentUnmappable();
}

/// What to carry across a source switch, given the latest pick.
///
/// [selected] is the pending selection (a pick still resolving counts). Null
/// with [viewerChose] false means the viewer never touched subtitles this
/// playback, and the answer is null: nothing to carry, so mpv keeps its own
/// defaults exactly as on a fresh open. Forcing Off there would hide a
/// forced or default track mpv shows on a fresh open at Original.
///
/// An mpv-native [selected] is translated through [selectedStreamIndex],
/// its `ff-index`, read while its file was still loaded; the server's
/// embedded track with that id is the same stream, provided the languages
/// agree (see [subtitleLanguagesCompatible]).
SubtitleIntent? subtitleIntentBeforeSwitch({
  required SubtitleTrack? selected,
  required bool viewerChose,
  required int? selectedStreamIndex,
  required List<SubtitleTrack> serverTracks,
}) {
  if (selected == null) return viewerChose ? const IntentOff() : null;
  if (!isMpvNativeSubtitleTrackId(selected.id)) return IntentTrack(selected);
  if (selectedStreamIndex == null) return const IntentUnmappable();

  final match = serverTracks
      .where((t) =>
          t.embedded &&
          int.tryParse(t.id) == selectedStreamIndex &&
          subtitleLanguagesCompatible(t.language, selected.language))
      .firstOrNull;
  return match == null ? const IntentUnmappable() : IntentTrack(match);
}

/// What a restore after a source switch should apply.
sealed class SubtitleRestore {
  const SubtitleRestore();
}

/// Apply [track], a member of the new source's list.
final class RestoreTrack extends SubtitleRestore {
  final SubtitleTrack track;
  const RestoreTrack(this.track);
}

/// Apply "Off".
final class RestoreOff extends SubtitleRestore {
  const RestoreOff();
}

/// Apply "Off" and tell the viewer [message]: their track cannot be shown
/// on the new source.
final class RestoreUnavailable extends SubtitleRestore {
  final String message;
  const RestoreUnavailable(this.message);
}

/// Finds [intent] on the source that just landed.
///
/// [tracks] is `_subtitleTracks` derived for the new source, so it holds
/// mpv-native tracks only in native direct play, and otherwise the server's
/// selectable tracks. [streamIndexByMpvId] is `subtitleStreamIndices` for
/// the new file (empty when there is nothing to read).
///
/// A track still in [tracks] is applied as is. An embedded track missing
/// from it is looked for among mpv's tracks by stream index, which is how a
/// server-delivered stream comes back as mpv's own in direct play. An image
/// track with no mpv tracks to match against is on a transcode, which
/// cannot deliver it.
SubtitleRestore resolveSubtitleIntent({
  required SubtitleIntent intent,
  required List<SubtitleTrack> tracks,
  required Map<String, int> streamIndexByMpvId,
}) {
  switch (intent) {
    case IntentOff():
      return const RestoreOff();
    case IntentUnmappable():
      return const RestoreUnavailable(kSubtitleNotCarriedMessage);
    case IntentTrack(:final track):
      final same = tracks.where((t) => t.id == track.id).firstOrNull;
      if (same != null) return RestoreTrack(same);

      if (track.embedded) {
        final streamIndex = int.tryParse(track.id);
        final native = tracks.where((t) {
          final mpvId = mpvIdOfSubtitleTrack(t.id);
          return mpvId != null &&
              streamIndex != null &&
              streamIndexByMpvId[mpvId] == streamIndex &&
              subtitleLanguagesCompatible(t.language, track.language);
        }).firstOrNull;
        if (native != null) return RestoreTrack(native);

        final onNativeSource =
            tracks.any((t) => isMpvNativeSubtitleTrackId(t.id));
        if (!track.deliverable && !onNativeSource) {
          return const RestoreUnavailable(kImageSubtitleUnavailableMessage);
        }
      }
      return const RestoreUnavailable(kSubtitleNotCarriedMessage);
  }
}

/// Whether `_syncSelectedSubtitleTrack` may overwrite the selection with
/// whatever media_kit reports.
///
/// Never while a switch is in flight or a carried choice is waiting to be
/// restored: media_kit's `open()` resets its record to `auto`, so a sync
/// then would wipe the viewer's choice before the restore reads it, and
/// its generation bump would cancel a restore still fetching a body.
bool shouldSyncSubtitleSelectionFromPlayer({
  required bool switchInFlight,
  required bool intentPending,
}) =>
    !switchInFlight && !intentPending;

/// Whether a subtitle pick from the sheet or a remote may start now.
///
/// Not during a source switch, the same way the quality picker ignores a
/// tap then: the switch is about to replace the file the pick would apply
/// to, and it carries the current choice across itself.
bool shouldAcceptSubtitlePick({required bool switchInFlight}) =>
    !switchInFlight;

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
/// `SubtitleContent` query. `_subtitleNudgeMs` is still tracked and still
/// contributes to what Save persists, so the nudge itself is not dropped on
/// web; only the wording changes, to stop claiming a visible change that has
/// not happened yet. See [subtitleDelaySavedMessage] for the other half of
/// this: Save does not make the change visible on web either, only
/// persists it.
String subtitleDelaySnackBarMessage({
  required int totalMs,
  required bool appliesImmediately,
}) {
  final signed = '${totalMs >= 0 ? '+' : ''}$totalMs ms';
  if (appliesImmediately) return 'Subtitle delay $signed';
  return 'Subtitle delay will be $signed after Save';
}

/// What the OSD snackbar should say right after a successful subtitle delay
/// save.
///
/// [appliesImmediately] is `false` on web for a second, distinct reason from
/// [subtitleDelaySnackBarMessage]'s: `_saveSubtitleDelay` persists the offset
/// to the server and updates `_subtitleOffsets`/`_subtitleNudgeMs`, but never
/// evicts or refetches the `SubtitleContent` body already cached in
/// `_mediaKitSubtitleTrackMap` for this track. That cached body still has the
/// *old* offset baked in by the server, so a web viewer who saves keeps
/// seeing the old timing until this track loads again. Native is unaffected
/// -- after a save, `effectiveSubtitleDelayMs` reduces to the (now zero)
/// nudge and `sub-delay` already carries the correct value live, so "saved"
/// there is also already true of what is on screen.
///
/// A refetch-on-save was deliberately not built to close this gap: it would
/// mean reloading a track mid-session, which lands in the subtitle-selection
/// race machinery (`_subtitleSelectionGeneration`, `_pendingSubtitleSelection`,
/// `shouldApplySubtitleSelection`) that took real effort to get right, on a
/// surface (the Flutter web build) that is not the primary UI. The message
/// is corrected instead of the behavior.
String subtitleDelaySavedMessage({required bool appliesImmediately}) {
  if (appliesImmediately) return 'Subtitle delay saved';
  return 'Subtitle delay saved. It applies next time this track loads.';
}
