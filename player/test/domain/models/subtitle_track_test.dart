import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/graphql/fragments/media_file_fragment.graphql.dart';

void main() {
  group('SubtitleTrack.fromGraphQL', () {
    test('carries the fragment\'s deliverable flag through, even when false',
        () {
      final sub = Fragment$MediaFileFragment$subtitles(
        trackId: 'trk-1',
        language: 'eng',
        title: 'English (PGS)',
        format: 'pgs',
        embedded: true,
        deliverable: false,
        url: null,
      );

      final track = SubtitleTrack.fromGraphQL(sub);

      expect(track.deliverable, isFalse);
    });

    test('leaves content null, since the fragment does not carry it', () {
      final sub = Fragment$MediaFileFragment$subtitles(
        trackId: 'trk-2',
        language: 'eng',
        title: 'English',
        format: 'srt',
        embedded: true,
        deliverable: true,
        url: 'https://example.test/subtitle.vtt',
      );

      final track = SubtitleTrack.fromGraphQL(sub);

      expect(track.content, isNull);
    });
  });
}
