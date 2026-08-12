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

    test(
        'a stale generation is not rescued by mounted and hasPlayer both '
        'being true', () {
      // Distinct generation values (not just "1 vs 2") so a check that
      // merely compares against a hardcoded constant instead of the actual
      // current generation cannot pass by accident.
      expect(
        shouldApplySubtitleSelection(
          requestGeneration: 3,
          currentGeneration: 5,
          mounted: true,
          hasPlayer: true,
        ),
        isFalse,
      );
    });
  });
}
