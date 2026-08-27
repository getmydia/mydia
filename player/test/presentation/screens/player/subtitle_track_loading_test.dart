import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/presentation/screens/player/subtitle_track_builder.dart';

void main() {
  const textTrack = SubtitleTrack(
    id: 'uuid-1',
    language: 'en',
    title: 'English',
    format: 'vtt',
    embedded: false,
  );

  const imageTrack = SubtitleTrack(
    id: '3',
    language: 'spa',
    title: 'Spanish',
    format: 'pgs',
    embedded: true,
    deliverable: false,
  );

  const embeddedTextTrack = SubtitleTrack(
    id: '2',
    language: 'eng',
    title: 'English',
    format: 'srt',
    embedded: true,
  );

  /// What `_applySubtitleTracks` builds out of a media_kit track: the `mk_`
  /// prefix is what keeps mpv's id space apart from the server's ffprobe
  /// stream indices.
  const mkTrack = SubtitleTrack(
    id: 'mk_1',
    language: 'eng',
    title: 'English',
    embedded: true,
  );

  group('selectableTracks', () {
    test('keeps image tracks in direct play', () {
      final tracks = selectableTracks(
        [textTrack, imageTrack],
        isDirectPlay: true,
      );
      expect(tracks, contains(imageTrack));
    });

    test('hides non-deliverable tracks when streaming', () {
      final tracks = selectableTracks(
        [textTrack, imageTrack],
        isDirectPlay: false,
      );
      expect(tracks, isNot(contains(imageTrack)));
      expect(tracks, contains(textTrack));
    });

    test(
        'keeps deliverable tracks when streaming even before content has '
        'been fetched', () {
      // `content` is resolved lazily, at selection time, over the
      // SubtitleContent query -- it is never populated at this stage. A
      // filter that checked content presence here (the pre-correction
      // design) would drop every streaming-eligible track before the viewer
      // ever got a chance to pick one.
      const notYetFetched = SubtitleTrack(
        id: 'uuid-2',
        language: 'fr',
        format: 'srt',
        embedded: false,
      );
      final tracks = selectableTracks([notYetFetched], isDirectPlay: false);
      expect(tracks, contains(notYetFetched));
    });

    test('keeps embedded text tracks in both modes', () {
      expect(
        selectableTracks([embeddedTextTrack], isDirectPlay: true),
        contains(embeddedTextTrack),
      );
      expect(
        selectableTracks([embeddedTextTrack], isDirectPlay: false),
        contains(embeddedTextTrack),
      );
    });
  });

  group('resolveSubtitleTracks', () {
    test('ignores media_kit entirely when streaming', () {
      // Streaming delivers every track's body as text over GraphQL, so the
      // server's list is the only one that means anything and image tracks
      // cannot be rendered at all.
      final tracks = resolveSubtitleTracks(
        serverTracks: [textTrack, embeddedTextTrack, imageTrack],
        mpvTracks: [mkTrack],
        isDirectPlay: false,
      );

      expect(tracks, [textTrack, embeddedTextTrack]);
    });

    test('prefers media_kit tracks over the server list in direct play', () {
      // mpv reads embedded tracks straight from the container, at no fetch
      // cost, so its own tracks win. Sidecars are not in the container and
      // still come from the server.
      final tracks = resolveSubtitleTracks(
        serverTracks: [textTrack, embeddedTextTrack],
        mpvTracks: [mkTrack],
        isDirectPlay: true,
      );

      expect(tracks, [mkTrack, textTrack]);
    });

    test(
        'falls back to the server list when media_kit has probed nothing '
        'yet in direct play', () {
      // The regression this whole change exists for. mpv discovers tracks
      // asynchronously while it probes, and on a remote file the probe
      // routinely outruns the fixed 500ms sample after `open()`. Dropping
      // the server's embedded tracks here left `_subtitleTracks` empty and
      // `panel_controls.dart`'s `subtitleTrackCount > 0` gate rendered the
      // button dead for the whole session.
      final tracks = resolveSubtitleTracks(
        serverTracks: [textTrack, embeddedTextTrack],
        mpvTracks: const [],
        isDirectPlay: true,
      );

      expect(tracks, [textTrack, embeddedTextTrack]);
    });

    test('drops image tracks from the direct-play fallback', () {
      // PGS and VobSub are bitmaps. In direct play mpv renders them from the
      // container; without mpv there is no body to fetch and nothing that
      // could draw them, so offering one would be a selection that silently
      // fails.
      final tracks = resolveSubtitleTracks(
        serverTracks: [textTrack, imageTrack],
        mpvTracks: const [],
        isDirectPlay: true,
      );

      expect(tracks, isNot(contains(imageTrack)));
      expect(tracks, contains(textTrack));
    });

    test('derives an equal list from unchanged inputs', () {
      // What lets `_applySubtitleTracks` skip the rebuild on a repeated
      // media_kit emission. That skip is load-bearing:
      // `_syncSelectedSubtitleTrack` bumps `_subtitleSelectionGeneration`,
      // and a bump discards whatever selection the viewer has in flight.
      List<SubtitleTrack> derive() => resolveSubtitleTracks(
            serverTracks: [textTrack, embeddedTextTrack],
            mpvTracks: [mkTrack],
            isDirectPlay: true,
          );

      expect(listEquals(derive(), derive()), isTrue);
    });
  });

  group('shouldApplySubtitleSelection', () {
    test('applies when nothing changed while the selection was in flight', () {
      expect(
        shouldApplySubtitleSelection(
          requestGeneration: 1,
          currentGeneration: 1,
          mounted: true,
          hasPlayer: true,
        ),
        isTrue,
      );
    });

    test('discards when a newer selection has already been requested', () {
      // e.g. the viewer picks T1 (generation 1, its content fetch starts),
      // then picks "Off" before T1's fetch resolves (generation 2). T1's
      // fetch finishing afterwards must not let it win the race just
      // because its network round trip happened to land last.
      expect(
        shouldApplySubtitleSelection(
          requestGeneration: 1,
          currentGeneration: 2,
          mounted: true,
          hasPlayer: true,
        ),
        isFalse,
      );
    });

    test(
        'discards when the screen was unmounted while the selection was '
        'in flight', () {
      expect(
        shouldApplySubtitleSelection(
          requestGeneration: 1,
          currentGeneration: 1,
          mounted: false,
          hasPlayer: true,
        ),
        isFalse,
      );
    });

    test(
        'discards when the player disappeared while the selection was '
        'in flight', () {
      // e.g. casting ended and _restartLocalPlayback cleared the player
      // without unmounting the screen, so `mounted` alone would not have
      // caught this.
      expect(
        shouldApplySubtitleSelection(
          requestGeneration: 1,
          currentGeneration: 1,
          mounted: true,
          hasPlayer: false,
        ),
        isFalse,
      );
    });

    // No fifth "distinct generation values" case here on purpose: a review
    // round pointed out the earlier one (3 vs 5, both true) discriminated
    // nothing the "1 vs 2" case above didn't already cover, since this is a
    // plain equality check with no code path that could pass one pair and
    // fail the other. Dropped rather than kept for the sake of a round
    // number.
  });

  group('shouldStartSubtitleSelection', () {
    test('starts when the requested target differs from the pending one', () {
      expect(
        shouldStartSubtitleSelection(
          requested: textTrack,
          pending: null,
          mounted: true,
        ),
        isTrue,
      );
    });

    test('is a no-op when the requested target matches the pending one', () {
      expect(
        shouldStartSubtitleSelection(
          requested: textTrack,
          pending: textTrack,
          mounted: true,
        ),
        isFalse,
      );
    });

    test(
        'is a no-op when unmounted, even if requested differs from '
        'pending', () {
      expect(
        shouldStartSubtitleSelection(
          requested: textTrack,
          pending: null,
          mounted: false,
        ),
        isFalse,
      );
    });
  });

  group('pendingSubtitleSelectionAfterFailure', () {
    test(
        'falls back to null when nothing is applied and this attempt is '
        'still current', () {
      expect(
        pendingSubtitleSelectionAfterFailure(
          requestGeneration: 1,
          currentGeneration: 1,
          currentPending: textTrack,
          appliedSelection: null,
        ),
        isNull,
      );
    });

    test('falls back to whatever non-null selection is actually applied', () {
      expect(
        pendingSubtitleSelectionAfterFailure(
          requestGeneration: 1,
          currentGeneration: 1,
          currentPending: textTrack,
          appliedSelection: embeddedTextTrack,
        ),
        embeddedTextTrack,
      );
    });

    test(
        'leaves pending untouched when a newer attempt has already '
        'superseded this one', () {
      // A superseded attempt must not clobber the newer request's own
      // target -- `currentPending` here stands in for whatever that newer
      // attempt already wrote.
      expect(
        pendingSubtitleSelectionAfterFailure(
          requestGeneration: 1,
          currentGeneration: 2,
          currentPending: embeddedTextTrack,
          appliedSelection: null,
        ),
        embeddedTextTrack,
      );
    });
  });

  group('effectiveSubtitleDelayMs', () {
    test('is zero when nothing is stored and nothing is nudged', () {
      expect(
        effectiveSubtitleDelayMs(
          storedOffsetMs: 0,
          bakedOffsetMs: 0,
          nudgeMs: 0,
        ),
        0,
      );
    });

    test('a server-fetched body needs no further delay', () {
      // The server already shifted the body by the stored offset, so
      // applying it again through sub-delay would double it.
      expect(
        effectiveSubtitleDelayMs(
          storedOffsetMs: 2000,
          bakedOffsetMs: 2000,
          nudgeMs: 0,
        ),
        0,
      );
    });

    test('an mpv-native track carries the full stored offset', () {
      // mpv read this track from the container; the server never touched it.
      expect(
        effectiveSubtitleDelayMs(
          storedOffsetMs: 2000,
          bakedOffsetMs: 0,
          nudgeMs: 0,
        ),
        2000,
      );
    });

    test('a nudge adds on top of a baked-in body', () {
      expect(
        effectiveSubtitleDelayMs(
          storedOffsetMs: 2000,
          bakedOffsetMs: 2000,
          nudgeMs: 300,
        ),
        300,
      );
    });

    test('a nudge adds on top of an mpv-native track', () {
      expect(
        effectiveSubtitleDelayMs(
          storedOffsetMs: 2000,
          bakedOffsetMs: 0,
          nudgeMs: -300,
        ),
        1700,
      );
    });

    test('saving a nudge leaves the effective delay unchanged', () {
      // This is what makes save free of a refetch: storedOffsetMs absorbs
      // the nudge and nudgeMs resets, and the result does not move.
      const before = 300;

      final beforeSave = effectiveSubtitleDelayMs(
        storedOffsetMs: 2000,
        bakedOffsetMs: 2000,
        nudgeMs: before,
      );

      final afterSave = effectiveSubtitleDelayMs(
        storedOffsetMs: 2000 + before,
        bakedOffsetMs: 2000,
        nudgeMs: 0,
      );

      expect(afterSave, beforeSave);
    });
  });

  group('isMpvNativeSubtitleTrackId', () {
    test('is true for an mpv-native track id', () {
      expect(isMpvNativeSubtitleTrackId('mk_1'), isTrue);
    });

    test('is false for a server track id', () {
      expect(isMpvNativeSubtitleTrackId('3'), isFalse);
      expect(isMpvNativeSubtitleTrackId('uuid-1'), isFalse);
    });
  });

  group('canSaveSubtitleDelay', () {
    test('refuses an mpv-native track', () {
      // Its id is media_kit's own container-local one, not the ffprobe
      // stream index `trackRef` actually means for an embedded track --
      // saving would persist under an id the next session has no reason to
      // reproduce.
      expect(canSaveSubtitleDelay('mk_1'), isFalse);
    });

    test('allows a server track id', () {
      expect(canSaveSubtitleDelay('3'), isTrue);
      expect(canSaveSubtitleDelay('uuid-1'), isTrue);
    });

    test('refuses when no track is selected', () {
      expect(canSaveSubtitleDelay(null), isFalse);
    });
  });

  group('subtitleDelayDisplayMs', () {
    test('hides the row when no track is selected', () {
      expect(
        subtitleDelayDisplayMs(
          trackId: null,
          offsetsLoaded: true,
          storedOffsetMs: 500,
          nudgeMs: 0,
        ),
        isNull,
      );
    });

    test('hides the row when the offsets query never succeeded', () {
      // Even with a track selected and a non-zero stored value passed in --
      // this is the exact shape that must be trusted enough to persist over,
      // and an unloaded query is precisely what makes it untrustworthy.
      expect(
        subtitleDelayDisplayMs(
          trackId: 'uuid-1',
          offsetsLoaded: false,
          storedOffsetMs: 500,
          nudgeMs: 0,
        ),
        isNull,
      );
    });

    test('shows stored plus the live nudge once a track is selected', () {
      expect(
        subtitleDelayDisplayMs(
          trackId: 'uuid-1',
          offsetsLoaded: true,
          storedOffsetMs: 500,
          nudgeMs: 300,
        ),
        800,
      );
    });

    test('shows zero for a fresh track with nothing stored or nudged', () {
      expect(
        subtitleDelayDisplayMs(
          trackId: 'uuid-1',
          offsetsLoaded: true,
          storedOffsetMs: 0,
          nudgeMs: 0,
        ),
        0,
      );
    });
  });

  group('subtitleDelaySnackBarMessage', () {
    test('reports the delay plainly when it applies immediately', () {
      expect(
        subtitleDelaySnackBarMessage(totalMs: 100, appliesImmediately: true),
        'Subtitle delay +100 ms',
      );
    });

    test('signs a negative total the same way', () {
      expect(
        subtitleDelaySnackBarMessage(totalMs: -200, appliesImmediately: true),
        'Subtitle delay -200 ms',
      );
    });

    test('signs zero as positive', () {
      expect(
        subtitleDelaySnackBarMessage(totalMs: 0, appliesImmediately: true),
        'Subtitle delay +0 ms',
      );
    });

    // The regression this exists for: on web, applySubtitleDelay is a
    // genuine no-op (media_kit's web backend has no mpv sub-delay to set),
    // so a viewer nudging there sees an OSD claiming a change that has not
    // happened. Saving is what actually persists the nudge -- see
    // subtitleDelaySavedMessage below for why even Save does not make it
    // visible on web either.
    test('does not claim an immediate change when it does not apply yet', () {
      final message = subtitleDelaySnackBarMessage(
        totalMs: 100,
        appliesImmediately: false,
      );

      expect(message, isNot('Subtitle delay +100 ms'));
      expect(message, contains('100 ms'));
      expect(message, contains('Save'));
    });
  });

  group('subtitleDelaySavedMessage', () {
    test('confirms the save plainly when it applies immediately', () {
      expect(
        subtitleDelaySavedMessage(appliesImmediately: true),
        'Subtitle delay saved',
      );
    });

    // The finding this exists for: saving persists the offset to the server
    // and updates local state, but never evicts or refetches the
    // SubtitleContent body already cached for this track in
    // _mediaKitSubtitleTrackMap. That body still has the *old* offset baked
    // in, so a web viewer who saves keeps seeing the old timing until the
    // track loads again -- the finding-4 fix made the nudge OSD promise
    // "after Save", which made this gap into a promise the code does not
    // keep unless this message says otherwise.
    test('does not claim an immediate change when it does not apply yet', () {
      final message = subtitleDelaySavedMessage(appliesImmediately: false);

      expect(message, isNot('Subtitle delay saved'));
      expect(message, contains('saved'));
      expect(message, contains('next time'));
    });
  });

  group('failed-fetch retry (regression coverage)', () {
    test(
        'a track whose fetch failed can be requested again, instead of '
        'silently matching stale pending state', () {
      // Reproduces the exact regression a second review round caught: T1
      // is requested, its fetch fails while nothing else has superseded
      // it, and the viewer taps T1 again. Before this fix, the second tap
      // compared its target against a pending value the first attempt
      // never cleared and was silently swallowed -- no fetch, no log, no
      // snackbar, despite a snackbar having just told the viewer to retry.
      const generation = 1;

      // 1. T1 requested: pending becomes T1 (mirrors
      //    `_pendingSubtitleSelection = selected;` in _showSubtitleSelector).
      SubtitleTrack? pending = textTrack;

      // 2. The fetch fails. This attempt is still current (nothing else
      //    ran), so pending must fall back to what's actually applied
      //    (nothing, in this scenario) rather than staying at T1.
      pending = pendingSubtitleSelectionAfterFailure(
        requestGeneration: generation,
        currentGeneration: generation,
        currentPending: pending,
        appliedSelection: null,
      );
      expect(pending, isNull,
          reason: 'pending must not still be T1 after its own fetch failed');

      // 3. The viewer taps T1 again. It must be recognised as a fresh
      //    attempt, not a no-op against the stale pending value from step 1.
      expect(
        shouldStartSubtitleSelection(
          requested: textTrack,
          pending: pending,
          mounted: true,
        ),
        isTrue,
        reason: 're-tapping the same track after its fetch failed must '
            'start a new attempt',
      );
    });
  });
}
