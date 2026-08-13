import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/graphql/fragments/media_file_fragment.graphql.dart';
import 'package:player/graphql/mutations/download_subtitle.graphql.dart';

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

  group('SubtitleTrack.fromDownload', () {
    Mutation$DownloadSubtitle$downloadSubtitle result({
      String trackId = 'trk-new',
      String language = 'en',
      String title = 'English (External)',
      String format = 'srt',
      bool embedded = false,
      bool deliverable = true,
    }) {
      return Mutation$DownloadSubtitle$downloadSubtitle(
        trackId: trackId,
        language: language,
        title: title,
        format: format,
        embedded: embedded,
        deliverable: deliverable,
      );
    }

    test('carries the server\'s track id, which the selection is keyed on', () {
      final track = SubtitleTrack.fromDownload(result(trackId: 'trk-42'));

      expect(track.id, 'trk-42');
    });

    test('carries every descriptive field the mutation returns', () {
      final track = SubtitleTrack.fromDownload(result(
        language: 'es',
        title: 'Spanish',
        format: 'vtt',
      ));

      expect(track.language, 'es');
      expect(track.title, 'Spanish');
      expect(track.format, 'vtt');
    });

    test('reports a freshly downloaded sidecar as external, not embedded', () {
      final track = SubtitleTrack.fromDownload(result(embedded: false));

      expect(track.embedded, isFalse);
    });

    test('carries deliverable through, even when false', () {
      final track = SubtitleTrack.fromDownload(result(deliverable: false));

      expect(track.deliverable, isFalse);
    });

    test('leaves content null, so the body is fetched lazily on selection', () {
      // The mutation reports the new track's identity, not its body. A
      // factory that invented an empty string here would make the track
      // look already-loaded to any `content?.isNotEmpty` check.
      final track = SubtitleTrack.fromDownload(result());

      expect(track.content, isNull);
    });
  });
}
