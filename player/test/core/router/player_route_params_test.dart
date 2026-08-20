import 'package:flutter_test/flutter_test.dart';
import 'package:player/app.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/domain/models/media_file.dart';

void main() {
  group('PlayerRouteParams.fromUri', () {
    test('reads back every field a route can carry', () {
      final uri = Uri.parse(
        '/player/episode/ep-1?fileId=file-1&title=Half+Loop'
        '&showId=show-1&seasonNumber=2&resume=120'
        '&audioTrack=audio-eng&subtitleTrack=sub-fre&autoplay=false',
      );

      final params = PlayerRouteParams.fromUri(uri);

      expect(params.fileId, 'file-1');
      expect(params.title, 'Half Loop');
      expect(params.showId, 'show-1');
      expect(params.seasonNumber, 2);
      expect(params.resumeSeconds, 120);
      expect(params.audioTrack, 'audio-eng');
      expect(params.subtitleTrack, 'sub-fre');
      expect(params.autoplay, isFalse);
    });

    test('defaults to autoplay true and every other field null when absent',
        () {
      final params = PlayerRouteParams.fromUri(Uri.parse('/player/movie/m1'));

      expect(params.fileId, isNull);
      expect(params.title, isNull);
      expect(params.showId, isNull);
      expect(params.seasonNumber, isNull);
      expect(params.resumeSeconds, isNull);
      expect(params.audioTrack, isNull);
      expect(params.subtitleTrack, isNull);
      expect(params.autoplay, isTrue);
    });

    test(
        'a route built by resolveLoadContentRoute for a remote episode '
        "LoadContent hands back non-null showId/seasonNumber — the exact "
        'precondition PlayerScreen._hasNextEpisode/_hasPreviousEpisode gate '
        'on, so a remotely-started episode keeps next/previous instead of '
        'silently losing it', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'show-1',
        episodeId: 'ep-9',
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieTarget: (id) async => throw StateError('not a movie'),
        fetchEpisodeTarget: (id) async => const LoadContentTarget(
          files: [
            MediaFile(
              id: 'ep-file',
              resolution: '720p',
              directPlaySupported: true,
            ),
          ],
          title: 'Half Loop',
          showId: 'show-1',
          seasonNumber: 2,
        ),
      );

      expect(route, isNotNull);
      final params = PlayerRouteParams.fromUri(Uri.parse(route!));

      // This is the exact gate `_fetchSeasonEpisodes` and
      // `_hasNextEpisode`/`_hasPreviousEpisode` check on `PlayerScreen`
      // (player_screen.dart): both non-null is what lets the season-episode
      // list load at all.
      expect(params.showId, isNotNull);
      expect(params.seasonNumber, isNotNull);
      expect(params.showId, 'show-1');
      expect(params.seasonNumber, 2);
    });

    test(
        'a route built by resolveLoadContentRoute for a movie carries no '
        'showId/seasonNumber, which a movie has no use for', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-1',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieTarget: (id) async => const LoadContentTarget(
          files: [
            MediaFile(
              id: 'only',
              resolution: '1080p',
              directPlaySupported: true,
            ),
          ],
          title: 'Arrival',
        ),
        fetchEpisodeTarget: (id) async => throw StateError('not an episode'),
      );

      expect(route, isNotNull);
      final params = PlayerRouteParams.fromUri(Uri.parse(route!));

      expect(params.showId, isNull);
      expect(params.seasonNumber, isNull);
    });
  });
}
