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
