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
}
