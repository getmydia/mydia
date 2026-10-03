import 'package:flutter/foundation.dart';

import '../../../domain/models/subtitle_track.dart' as app_models;
import '../../widgets/toast/toaster.dart' show ToastKind;
import 'session/playback_session_types.dart' show WriteOutcome;
import 'subtitle_track_builder.dart';

/// The subtitle delay for whichever track is selected: offsets the server
/// stored per track, what it already baked into the loaded body, and the
/// viewer's live nudge.
class SubtitleDelayController {
  SubtitleDelayController({
    required this.selectedTrack,
    required this.applyDelay,
    required this.saveOffset,
    required this.canPersist,
    required this.toast,
    required this.mounted,
    required this.onChanged,
  });

  final app_models.SubtitleTrack? Function() selectedTrack;

  /// Sends a delay to mpv. A no-op when there is no player.
  final Future<void> Function(int delayMs) applyDelay;
  final Future<WriteOutcome> Function({
    required String trackRef,
    required int offsetMs,
  }) saveOffset;

  /// Not offline, and the session can write.
  final bool Function() canPersist;
  final void Function(String message, {ToastKind kind}) toast;
  final bool Function() mounted;
  final VoidCallback onChanged;

  /// Stored per-track subtitle offsets from the server, keyed by track ref
  /// (the same id space `SubtitleTrack.id`/`SubtitleContent` use). Empty
  /// both before the offsets fetch has run and after it has failed;
  /// [_offsetsLoaded] is what tells those two apart.
  Map<String, int> _offsets = {};

  /// Whether the offsets fetch has completed successfully at least
  /// once for the media file now loaded, even when it found nothing to
  /// report. `subtitleTrackSettings` does not exist on a server that
  /// predates this feature, and it is a standalone root query precisely so
  /// that failure stays contained to it (see the query's own doc comment)
  /// rather than taking playback down with it.
  ///
  /// Gates the sheet's delay row and the `z`/`shift+z` keyboard nudge: with
  /// this false, an empty [_offsets] is indistinguishable from "the
  /// server genuinely has nothing stored" and cannot be trusted enough to
  /// nudge relative to, let alone Save over. See [subtitleDelayDisplayMs].
  bool _offsetsLoaded = false;

  /// What the server had already shifted into the body currently loaded.
  /// Equal to the stored offset for a track fetched over `SubtitleContent`
  /// (`Delivery.content/3` applies it before returning); zero for an
  /// mpv-native track mpv read straight out of the container, which the
  /// server never saw, and for a bitmap sidecar, which it cannot shift. See
  /// [bakedSubtitleOffsetMs] and [effectiveSubtitleDelayMs].
  int _bakedMs = 0;

  /// The live, unsaved adjustment from the sheet's steppers or the
  /// `z`/`shift+z` keys. Reset to zero on every track change by
  /// [onTrackChanged].
  ///
  /// Applies to mpv the same way regardless of track origin -- but for an
  /// mpv-native track, [save] refuses to persist it (see
  /// [canSaveSubtitleDelay]). The asymmetry is real, not an oversight: the
  /// live delay only needs [_nudgeMs] and [_bakedMs],
  /// neither of which cares what id space a track's id lives in, while
  /// persisting needs a `trackRef` the next session's mpv probe can
  /// reproduce, which an `mk_`-prefixed id is not.
  int _nudgeMs = 0;

  /// Feeds the subtitle sheet's delay row. A `ValueNotifier`, not a plain
  /// field: the delay row lives inside a modal bottom sheet, a different
  /// route from the screen's own build method, so a `setState` there would
  /// never reach it. `null` hides the row entirely -- no track selected, or
  /// the offsets query never succeeded. Disposed in [dispose].
  final ValueNotifier<int?> _display = ValueNotifier<int?>(null);

  ValueListenable<int?> get display => _display;

  /// Forgets the previous file's offsets before a fetch. Pure; the screen
  /// wraps it in `setState`.
  void clear() {
    _offsets = {};
    _offsetsLoaded = false;
  }

  /// Takes a fetched offset map. Pure; the screen wraps it in `setState`
  /// and calls [sync] after.
  void setOffsets(Map<String, int> offsets) {
    _offsets = offsets;
    _offsetsLoaded = true;

    // Defensive, not expected to fire in the normal flow: this is
    // awaited inside the screen's progress and episodes fetch, which always
    // completes before any track is auto-selected or picked. If a
    // track were already selected by the time this resolves, its
    // baked offset -- assumed zero until now for anything not read
    // straight from the container -- needs to catch up to what the
    // server actually shifted into the body it already delivered.
    final current = selectedTrack();
    if (current != null && !isMpvNativeSubtitleTrackId(current.id)) {
      _bakedMs = _offsets[current.id] ?? 0;
    }
  }

  /// Resets the live nudge and recomputes the baked offset for whichever
  /// track is now selected, then applies the result to mpv and the sheet's
  /// delay display.
  ///
  /// Called from every site that can change the selected subtitle track --
  /// both success paths of the subtitle sheet, the auto-detected
  /// default track when tracks change, and the remote-control
  /// `selectTrack` -- so a delay nudged for one track never leaks onto the
  /// next regardless of which of those paths picked it.
  ///
  /// [keepNudge] is for the restore after a source switch: the viewer did
  /// not change tracks, so a delay they nudged survives, while the baked
  /// offset is still recomputed for whichever track id the restore landed
  /// on (the server's copy of a stream and mpv's own differ there).
  Future<void> onTrackChanged({bool keepNudge = false}) async {
    final track = selectedTrack();
    if (!keepNudge) _nudgeMs = 0;
    _bakedMs = bakedSubtitleOffsetMs(track: track, offsets: _offsets);
    await sync();
  }

  /// Applies [effectiveSubtitleDelayMs] to mpv for whichever track is
  /// currently selected, and refreshes [display] alongside
  /// it -- the two must never drift apart, since the display is the only
  /// place the viewer can see the number this just sent to mpv.
  Future<void> sync() async {
    final track = selectedTrack();
    final storedOffsetMs = _offsets[track?.id] ?? 0;

    if (mounted()) {
      _display.value = subtitleDelayDisplayMs(
        trackId: track?.id,
        offsetsLoaded: _offsetsLoaded,
        storedOffsetMs: storedOffsetMs,
        nudgeMs: _nudgeMs,
      );
    }

    await applyDelay(
      effectiveSubtitleDelayMs(
        storedOffsetMs: storedOffsetMs,
        bakedOffsetMs: _bakedMs,
        nudgeMs: _nudgeMs,
      ),
    );
  }

  /// Nudges the live subtitle delay by [deltaMs] and applies it immediately.
  /// Bound to the `z`/`shift+z` keys and the sheet's steppers.
  ///
  /// Gated on [_offsetsLoaded]: with the offsets query never having
  /// succeeded, [_offsets] cannot be trusted to hold the server's
  /// real baseline (see that field's dartdoc), so nudging would move mpv
  /// relative to an unknown starting point and a viewer would have no way
  /// to tell how far off zero they actually are. No-ops rather than
  /// nudging partially-informed.
  Future<void> nudge(int deltaMs) async {
    final track = selectedTrack();
    if (track == null || !_offsetsLoaded) return;

    _nudgeMs += deltaMs;
    onChanged();
    final total = (_offsets[track.id] ?? 0) + _nudgeMs;

    await sync();

    // applySubtitleDelay is a genuine no-op on web -- there is no mpv
    // sub-delay to set, and the body a web viewer sees always comes
    // pre-baked from the SubtitleContent query. The nudge is still tracked
    // and still contributes to what Save persists, but the OSD must not
    // claim a visible change that has not happened yet.
    toast(
      subtitleDelayToastMessage(
        totalMs: total,
        appliesImmediately: !kIsWeb,
      ),
    );
  }

  /// Discards the live nudge, returning the delay to whatever is actually
  /// stored for this track (or zero, for a track the server has no
  /// correction for).
  Future<void> resetNudge() async {
    final track = selectedTrack();
    if (track == null || !_offsetsLoaded) return;
    if (_nudgeMs == 0) return;

    _nudgeMs = 0;
    onChanged();
    await sync();
  }

  /// Persists the current nudge, replacing whatever offset the server had
  /// stored for this track.
  ///
  /// `storedOffsetMs` (via [_offsets]) absorbs the nudge and
  /// `nudgeMs` resets, which leaves [effectiveSubtitleDelayMs] at exactly
  /// the same value -- see that function's dartdoc. Nothing refetches,
  /// nothing flickers, and the displayed number does not jump.
  ///
  /// The sheet already hides its Save button for an mpv-native track (see
  /// [canSaveSubtitleDelay]), but this checks again rather than trusting
  /// that UI gate alone -- the same defensive posture every other guard in
  /// this method already takes.
  ///
  /// On web this only ever persists the offset and updates local state; it
  /// never evicts or refetches the `SubtitleContent` body already cached in
  /// the screen's media_kit track map for the track, so what the viewer sees
  /// does not actually change until the track loads again. See
  /// [subtitleDelaySavedMessage]'s dartdoc for why that gap is closed with
  /// an honest message rather than a reload.
  Future<void> save() async {
    final track = selectedTrack();
    if (track == null || !_offsetsLoaded) return;
    if (!canSaveSubtitleDelay(track.id)) return;
    if (!canPersist()) return;

    final total = (_offsets[track.id] ?? 0) + _nudgeMs;

    final outcome = await saveOffset(trackRef: track.id, offsetMs: total);
    switch (outcome) {
      case WriteOutcome.unavailable:
        return;
      case WriteOutcome.failed:
        toast('Could not save the subtitle delay', kind: ToastKind.error);
        return;
      case WriteOutcome.done:
        break;
    }

    try {
      if (!mounted()) return;

      // Safe regardless of what is selected now: this is keyed by
      // `track.id`, the specific track this save was for. Resetting the
      // live nudge is not -- that only belongs to whichever track is
      // *currently* selected, so it is skipped entirely if the viewer
      // picked a different track while this request was in flight. An
      // unconditional reset here would wipe out a nudge already in
      // progress for a track this save was never about.
      _offsets = {..._offsets, track.id: total};
      onChanged();
      if (selectedTrack()?.id == track.id) {
        _nudgeMs = 0;
        onChanged();
        await sync();
      }

      // On web this save never touches the SubtitleContent body already
      // cached in the screen's media_kit track map for this track -- it still
      // has the old offset baked in, so nothing the viewer sees actually
      // moves yet. See subtitleDelaySavedMessage's dartdoc for why a refetch
      // was not built to close that gap.
      toast(
        subtitleDelaySavedMessage(appliesImmediately: !kIsWeb),
        kind: ToastKind.success,
      );
    } catch (e) {
      debugPrint('[PlayerScreen] Could not save subtitle delay: $e');
      toast('Could not save the subtitle delay', kind: ToastKind.error);
    }
  }

  void dispose() => _display.dispose();
}
