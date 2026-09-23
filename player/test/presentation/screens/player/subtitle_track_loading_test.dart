import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/image_subtitle_sidecar.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/presentation/screens/player/subtitle_selection_target.dart';
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

  /// DVB from a server predating DVB in its image list, which reported it
  /// as deliverable text.
  const oldServerDvb = SubtitleTrack(
    id: '4',
    language: 'ger',
    format: 'dvb_subtitle',
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

    test('offers an embedded bitmap track as a sidecar on native', () {
      final tracks = selectableTracks(
        [textTrack, imageTrack],
        isDirectPlay: false,
        imageSidecars: true,
      );
      expect(tracks, [textTrack, imageTrack]);
    });

    test('reads a bitmap from its format, not from deliverable', () {
      expect(
        selectableTracks([oldServerDvb], isDirectPlay: false),
        isEmpty,
      );
      expect(
        selectableTracks(
          [oldServerDvb],
          isDirectPlay: false,
          imageSidecars: true,
        ),
        [oldServerDvb],
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
      // mpv discovers tracks asynchronously while it probes, and on a remote
      // file the probe routinely outruns the fixed 500ms sample after
      // `open()`. Dropping the server's embedded tracks here left
      // `_subtitleTracks` empty for the whole session, so the sheet offered
      // nothing for a file whose container was full of subtitles.
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

    test('offers bitmap sidecars when streaming on native', () {
      final tracks = resolveSubtitleTracks(
        serverTracks: [textTrack, embeddedTextTrack, imageTrack],
        mpvTracks: [mkTrack],
        isDirectPlay: false,
        imageSidecars: true,
      );
      expect(tracks, [textTrack, embeddedTextTrack, imageTrack]);
    });

    test('keeps bitmap tracks out of the direct-play fallback, even on native',
        () {
      // There is no HLS session to fetch a sidecar from in direct play;
      // mpv's own list brings the bitmap tracks once it has probed.
      final tracks = resolveSubtitleTracks(
        serverTracks: [textTrack, imageTrack],
        mpvTracks: const [],
        isDirectPlay: true,
        imageSidecars: true,
      );
      expect(tracks, [textTrack]);
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
    final trackX = SubtitleTrack(id: 'x', language: 'eng', embedded: true);
    final trackY = SubtitleTrack(id: 'y', language: 'fra', embedded: true);

    test('an Off tapped with no attempt in flight starts one', () {
      // The whole point of the type. `null` pending means idle, not "Off is
      // pending", so the viewer who opens the sheet purely to say "never
      // subtitles for this show" is heard.
      expect(
        shouldStartSubtitleSelection(
          requested: const TargetOff(),
          pending: null,
          mounted: true,
        ),
        isTrue,
      );
    });

    test('an Off repeating an in-flight Off is a no-op', () {
      expect(
        shouldStartSubtitleSelection(
          requested: const TargetOff(),
          pending: const TargetOff(),
          mounted: true,
        ),
        isFalse,
      );
    });

    test('re-picking the track already targeted is a no-op', () {
      expect(
        shouldStartSubtitleSelection(
          requested: TargetTrack(trackX),
          pending: TargetTrack(trackX),
          mounted: true,
        ),
        isFalse,
      );
    });

    test('picking a different track from the one in flight starts an attempt',
        () {
      expect(
        shouldStartSubtitleSelection(
          requested: TargetTrack(trackY),
          pending: TargetTrack(trackX),
          mounted: true,
        ),
        isTrue,
      );
    });

    test('an unmounted screen starts nothing', () {
      expect(
        shouldStartSubtitleSelection(
          requested: const TargetOff(),
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
          currentPending: TargetTrack(textTrack),
          appliedTarget: null,
        ),
        isNull,
      );
    });

    test('falls back to whatever non-null selection is actually applied', () {
      expect(
        pendingSubtitleSelectionAfterFailure(
          requestGeneration: 1,
          currentGeneration: 1,
          currentPending: TargetTrack(textTrack),
          appliedTarget: TargetTrack(embeddedTextTrack),
        ),
        TargetTrack(embeddedTextTrack),
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
          currentPending: TargetTrack(embeddedTextTrack),
          appliedTarget: null,
        ),
        TargetTrack(embeddedTextTrack),
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

  group('subtitleDelayToastMessage', () {
    test('reports the delay plainly when it applies immediately', () {
      expect(
        subtitleDelayToastMessage(totalMs: 100, appliesImmediately: true),
        'Subtitle delay +100 ms',
      );
    });

    test('signs a negative total the same way', () {
      expect(
        subtitleDelayToastMessage(totalMs: -200, appliesImmediately: true),
        'Subtitle delay -200 ms',
      );
    });

    test('signs zero as positive', () {
      expect(
        subtitleDelayToastMessage(totalMs: 0, appliesImmediately: true),
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
      final message = subtitleDelayToastMessage(
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
      // toast, despite a toast having just told the viewer to retry.
      const generation = 1;

      // 1. T1 requested: pending becomes T1 (mirrors
      //    `_pendingSubtitleSelection = selected;` in _showSubtitleSelector).
      SubtitleSelectionTarget? pending = TargetTrack(textTrack);

      // 2. The fetch fails. This attempt is still current (nothing else
      //    ran), so pending must fall back to what's actually applied
      //    (nothing, in this scenario) rather than staying at T1.
      pending = pendingSubtitleSelectionAfterFailure(
        requestGeneration: generation,
        currentGeneration: generation,
        currentPending: pending,
        appliedTarget: null,
      );
      expect(pending, isNull,
          reason: 'pending must not still be T1 after its own fetch failed');

      // 3. The viewer taps T1 again. It must be recognised as a fresh
      //    attempt, not a no-op against the stale pending value from step 1.
      expect(
        shouldStartSubtitleSelection(
          requested: TargetTrack(textTrack),
          pending: pending,
          mounted: true,
        ),
        isTrue,
        reason: 're-tapping the same track after its fetch failed must '
            'start a new attempt',
      );
    });
  });

  // Tracks shaped like one file seen from both sides of a quality switch:
  // the server's list (sidecar plus two embedded streams at ffprobe indices
  // 3 and 5), and mpv's own list in direct play, where mpv numbers the same
  // two streams 1 and 2.
  const sidecar = SubtitleTrack(
    id: 'uuid-sidecar',
    language: 'eng',
    title: 'English (SDH)',
    format: 'srt',
  );
  const serverEnglish = SubtitleTrack(
    id: '3',
    language: 'eng',
    title: 'English',
    format: 'subrip',
    embedded: true,
  );
  const serverPgs = SubtitleTrack(
    id: '5',
    language: 'fre',
    title: 'French',
    format: 'pgs',
    embedded: true,
    deliverable: false,
  );
  const mpvEnglish = SubtitleTrack(
    id: 'mk_1',
    language: 'eng',
    title: 'English',
    embedded: true,
  );
  const mpvFrench = SubtitleTrack(
    id: 'mk_2',
    language: 'fre',
    title: 'French',
    embedded: true,
  );
  const serverList = [sidecar, serverEnglish, serverPgs];
  const streamingList = [sidecar, serverEnglish];
  const directPlayList = [mpvEnglish, mpvFrench, sidecar];
  const indices = {'1': 3, '2': 5};

  group('mpvIdOfSubtitleTrack', () {
    test('strips the prefix from an mpv-native id', () {
      expect(mpvIdOfSubtitleTrack('mk_12'), '12');
    });

    test('is null for a server track id', () {
      expect(mpvIdOfSubtitleTrack('3'), isNull);
      expect(mpvIdOfSubtitleTrack('uuid-sidecar'), isNull);
    });
  });

  group('subtitleLanguagesCompatible', () {
    test('matches the same code regardless of case', () {
      expect(subtitleLanguagesCompatible('eng', 'ENG'), isTrue);
    });

    test('rejects two different known languages', () {
      expect(subtitleLanguagesCompatible('eng', 'fre'), isFalse);
    });

    test('lets an undetermined or missing language match anything', () {
      expect(subtitleLanguagesCompatible('und', 'fre'), isTrue);
      expect(subtitleLanguagesCompatible('eng', 'und'), isTrue);
      expect(subtitleLanguagesCompatible('', 'eng'), isTrue);
    });
  });

  group('subtitleIntentBeforeSwitch', () {
    test('has nothing to carry when the viewer never chose', () {
      // mpv keeps its own defaults across the switch, as on a fresh open.
      expect(
        subtitleIntentBeforeSwitch(
          selected: null,
          viewerChose: false,
          selectedStreamIndex: null,
          serverTracks: serverList,
        ),
        isNull,
      );
    });

    test('carries an explicit Off', () {
      expect(
        subtitleIntentBeforeSwitch(
          selected: null,
          viewerChose: true,
          selectedStreamIndex: null,
          serverTracks: serverList,
        ),
        isA<IntentOff>(),
      );
    });

    test('carries a server track as itself', () {
      for (final track in [sidecar, serverEnglish]) {
        expect(
          subtitleIntentBeforeSwitch(
            selected: track,
            viewerChose: true,
            selectedStreamIndex: null,
            serverTracks: serverList,
          ),
          isA<IntentTrack>().having((i) => i.track, 'track', track),
        );
      }
    });

    test('translates an mpv track through its stream index', () {
      expect(
        subtitleIntentBeforeSwitch(
          selected: mpvEnglish,
          viewerChose: true,
          selectedStreamIndex: 3,
          serverTracks: serverList,
        ),
        isA<IntentTrack>().having((i) => i.track, 'track', serverEnglish),
      );
    });

    test('cannot carry an mpv track whose index was not read', () {
      expect(
        subtitleIntentBeforeSwitch(
          selected: mpvEnglish,
          viewerChose: true,
          selectedStreamIndex: null,
          serverTracks: serverList,
        ),
        isA<IntentUnmappable>(),
      );
    });

    test('cannot carry an mpv track with no server stream at that index', () {
      expect(
        subtitleIntentBeforeSwitch(
          selected: mpvEnglish,
          viewerChose: true,
          selectedStreamIndex: 9,
          serverTracks: serverList,
        ),
        isA<IntentUnmappable>(),
      );
    });

    test('rejects an index match whose language disagrees', () {
      // Index 3 is the English stream on the server; an mpv track tagged
      // French claiming index 3 means the indices do not line up.
      expect(
        subtitleIntentBeforeSwitch(
          selected: mpvFrench,
          viewerChose: true,
          selectedStreamIndex: 3,
          serverTracks: serverList,
        ),
        isA<IntentUnmappable>(),
      );
    });

    test('accepts an index match when mpv reports no language', () {
      const untagged = SubtitleTrack(id: 'mk_1', language: 'und');
      expect(
        subtitleIntentBeforeSwitch(
          selected: untagged,
          viewerChose: true,
          selectedStreamIndex: 3,
          serverTracks: serverList,
        ),
        isA<IntentTrack>().having((i) => i.track, 'track', serverEnglish),
      );
    });
  });

  group('resolveSubtitleIntent', () {
    test('an explicit Off stays off on any source', () {
      for (final tracks in [streamingList, directPlayList]) {
        expect(
          resolveSubtitleIntent(
            intent: const IntentOff(),
            tracks: tracks,
            streamIndexByMpvId: indices,
          ),
          isA<RestoreOff>(),
        );
      }
    });

    test('a sidecar is found again on either source', () {
      for (final tracks in [streamingList, directPlayList]) {
        expect(
          resolveSubtitleIntent(
            intent: const IntentTrack(sidecar),
            tracks: tracks,
            streamIndexByMpvId: indices,
          ),
          isA<RestoreTrack>().having((r) => r.track, 'track', sidecar),
        );
      }
    });

    test('an embedded text track is delivered by the server in a transcode',
        () {
      expect(
        resolveSubtitleIntent(
          intent: const IntentTrack(serverEnglish),
          tracks: streamingList,
          streamIndexByMpvId: const {},
        ),
        isA<RestoreTrack>().having((r) => r.track, 'track', serverEnglish),
      );
    });

    test('an embedded track becomes mpv\'s own track in direct play', () {
      expect(
        resolveSubtitleIntent(
          intent: const IntentTrack(serverEnglish),
          tracks: directPlayList,
          streamIndexByMpvId: indices,
        ),
        isA<RestoreTrack>().having((r) => r.track, 'track', mpvEnglish),
      );
    });

    test('an image track cannot be carried into a transcode', () {
      expect(
        resolveSubtitleIntent(
          intent: const IntentTrack(serverPgs),
          tracks: streamingList,
          streamIndexByMpvId: const {},
        ),
        isA<RestoreUnavailable>().having(
            (r) => r.message, 'message', kImageSubtitleUnavailableMessage),
      );
    });

    test('an image track is carried into a native transcode as a sidecar', () {
      expect(
        resolveSubtitleIntent(
          intent: const IntentTrack(serverPgs),
          tracks: const [sidecar, serverEnglish, serverPgs],
          streamIndexByMpvId: const {},
        ),
        isA<RestoreTrack>().having((r) => r.track, 'track', serverPgs),
      );
    });

    test('an image track is mpv\'s own track back in direct play', () {
      expect(
        resolveSubtitleIntent(
          intent: const IntentTrack(serverPgs),
          tracks: directPlayList,
          streamIndexByMpvId: indices,
        ),
        isA<RestoreTrack>().having((r) => r.track, 'track', mpvFrench),
      );
    });

    test('direct play with unreadable indices reports it plainly', () {
      // Not the image message: the viewer is at Original, where the track
      // would play if only it could be found.
      expect(
        resolveSubtitleIntent(
          intent: const IntentTrack(serverPgs),
          tracks: directPlayList,
          streamIndexByMpvId: const {},
        ),
        isA<RestoreUnavailable>()
            .having((r) => r.message, 'message', kSubtitleNotCarriedMessage),
      );
    });

    test('direct play with no mpv tracks falls back to the server copy', () {
      // Web, or mpv published nothing: the derived list is the server's.
      expect(
        resolveSubtitleIntent(
          intent: const IntentTrack(serverEnglish),
          tracks: streamingList,
          streamIndexByMpvId: const {},
        ),
        isA<RestoreTrack>().having((r) => r.track, 'track', serverEnglish),
      );
    });

    test('an unmappable intent turns subtitles off with a reason', () {
      expect(
        resolveSubtitleIntent(
          intent: const IntentUnmappable(),
          tracks: streamingList,
          streamIndexByMpvId: const {},
        ),
        isA<RestoreUnavailable>()
            .having((r) => r.message, 'message', kSubtitleNotCarriedMessage),
      );
    });

    test('a track that vanished from the new list is reported', () {
      const gone = SubtitleTrack(id: 'uuid-gone', language: 'eng');
      expect(
        resolveSubtitleIntent(
          intent: const IntentTrack(gone),
          tracks: streamingList,
          streamIndexByMpvId: const {},
        ),
        isA<RestoreUnavailable>()
            .having((r) => r.message, 'message', kSubtitleNotCarriedMessage),
      );
    });
  });

  group('shouldSyncSubtitleSelectionFromPlayer', () {
    test('syncs only when no switch and no carried choice is pending', () {
      expect(
        shouldSyncSubtitleSelectionFromPlayer(
            switchInFlight: false, intentPending: false),
        isTrue,
      );
      expect(
        shouldSyncSubtitleSelectionFromPlayer(
            switchInFlight: true, intentPending: false),
        isFalse,
      );
      expect(
        shouldSyncSubtitleSelectionFromPlayer(
            switchInFlight: false, intentPending: true),
        isFalse,
      );
      expect(
        shouldSyncSubtitleSelectionFromPlayer(
            switchInFlight: true, intentPending: true),
        isFalse,
      );
    });
  });

  group('shouldAcceptSubtitlePick', () {
    test('ignores a pick while a switch is in flight', () {
      expect(shouldAcceptSubtitlePick(switchInFlight: true), isFalse);
      expect(shouldAcceptSubtitlePick(switchInFlight: false), isTrue);
    });
  });

  group('subtitleRestoreConsumed', () {
    test('keeps the intent after an unavailable restore', () {
      expect(
        subtitleRestoreConsumed(
          restore: const RestoreUnavailable(kImageSubtitleUnavailableMessage),
          selected: null,
        ),
        isFalse,
      );
    });

    test('clears the intent once the track is actually selected', () {
      expect(
        subtitleRestoreConsumed(
          restore: const RestoreTrack(sidecar),
          selected: sidecar,
        ),
        isTrue,
      );
      expect(
        subtitleRestoreConsumed(
          restore: const RestoreTrack(sidecar),
          selected: null,
        ),
        isFalse,
      );
    });

    test('clears the intent once Off is actually applied', () {
      expect(
        subtitleRestoreConsumed(
          restore: const RestoreOff(),
          selected: null,
        ),
        isTrue,
      );
    });
  });

  group('bakedSubtitleOffsetMs', () {
    const offsets = {'uuid-1': 400, '3': 250, 'mk_1': 900};

    test('is the stored offset for a text body the server shifted', () {
      expect(bakedSubtitleOffsetMs(track: textTrack, offsets: offsets), 400);
    });

    test('is zero for no track, an mpv-native track, and a bitmap sidecar', () {
      expect(bakedSubtitleOffsetMs(track: null, offsets: offsets), 0);
      expect(bakedSubtitleOffsetMs(track: mkTrack, offsets: offsets), 0);
      expect(bakedSubtitleOffsetMs(track: imageTrack, offsets: offsets), 0);
    });
  });

  group('imageSidecarFailureMessage', () {
    test('a server that cannot serve sidecars keeps the Original message', () {
      expect(
        imageSidecarFailureMessage(const SidecarUnsupported()),
        kImageSubtitleUnavailableMessage,
      );
    });

    test('anything else invites a retry', () {
      expect(
        imageSidecarFailureMessage(const SidecarFailed('HTTP 415')),
        kSubtitleLoadFailedMessage,
      );
    });
  });

  group('nativeTwinOf', () {
    const serverEnglish = SubtitleTrack(
      id: '5',
      language: 'eng',
      title: 'SDH',
      embedded: true,
      hearingImpaired: true,
    );
    const mpvTracks = [
      SubtitleTrack(id: 'mk_1', language: 'eng', embedded: true),
      SubtitleTrack(id: 'mk_2', language: 'eng', embedded: true),
      SubtitleTrack(id: 'mk_3', language: 'spa', embedded: true),
    ];

    test('finds the mpv track carrying the same stream index', () {
      expect(
        nativeTwinOf(
          serverEnglish,
          tracks: mpvTracks,
          streamIndexByMpvId: const {'1': 4, '2': 5, '3': 6},
        ),
        mpvTracks[1],
      );
    });

    test('refuses a stream index whose language disagrees', () {
      expect(
        nativeTwinOf(
          serverEnglish,
          tracks: mpvTracks,
          streamIndexByMpvId: const {'3': 5},
        ),
        isNull,
      );
    });

    test('a sidecar or an unread index has no twin', () {
      const sidecar = SubtitleTrack(id: 'a1b2', language: 'eng');
      expect(
        nativeTwinOf(sidecar,
            tracks: mpvTracks, streamIndexByMpvId: const {'1': 5}),
        isNull,
      );
      expect(
        nativeTwinOf(serverEnglish,
            tracks: mpvTracks, streamIndexByMpvId: const {}),
        isNull,
      );
    });
  });
}
