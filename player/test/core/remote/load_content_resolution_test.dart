import 'package:flutter_test/flutter_test.dart';
import 'package:player/app.dart';
import 'package:player/core/player/best_file.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/domain/models/media_file.dart';

MediaFile _file(String id, String resolution) => MediaFile(
      id: id,
      resolution: resolution,
      directPlaySupported: true,
    );

/// Fails the test outright if called: the movie side of a `LoadContent`
/// resolution should never be reached for an intent carrying an episode id.
Future<List<MediaFile>> _unreachable(String id) {
  fail('fetcher should not have been called for id $id');
}

void main() {
  group('resolveLoadContentRoute', () {
    test('a movie resolves to the same file pickBestFile would choose',
        () async {
      final sd = _file('sd', '480p');
      final hd = _file('hd', '1080p');
      final files = [sd, hd];
      const screenWidth = 1600.0;

      final expected = await pickBestFile(files, screenWidth);

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
        screenWidth,
        fetchMovieFiles: (id) async {
          expect(id, 'movie-1');
          return files;
        },
        fetchEpisodeFiles: _unreachable,
      );

      expect(route, startsWith('/player/movie/movie-1?'));
      expect(route, contains('fileId=${expected!.id}'));
    });

    test('an episode resolves against its own files, not the show\'s',
        () async {
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
        fetchMovieFiles: _unreachable,
        fetchEpisodeFiles: (id) async {
          expect(id, 'ep-9');
          return [_file('ep-file', '720p')];
        },
      );

      expect(route, startsWith('/player/episode/ep-9?'));
      expect(route, contains('fileId=ep-file'));
    });

    test('startAt becomes resumeSeconds', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-2',
        episodeId: null,
        startAt: Duration(seconds: 754),
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieFiles: (id) async => [_file('only', '1080p')],
        fetchEpisodeFiles: _unreachable,
      );

      expect(route, contains('resume=754'));
    });

    test('audioTrack and subtitleTrack are carried through when present',
        () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-3',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: 'audio-eng',
        subtitleTrack: 'sub-fre',
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieFiles: (id) async => [_file('only', '1080p')],
        fetchEpisodeFiles: _unreachable,
      );

      expect(route, contains('audioTrack=audio-eng'));
      expect(route, contains('subtitleTrack=sub-fre'));
    });

    test('audioTrack and subtitleTrack are omitted when null', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-4',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieFiles: (id) async => [_file('only', '1080p')],
        fetchEpisodeFiles: _unreachable,
      );

      expect(route, isNot(contains('audioTrack')));
      expect(route, isNot(contains('subtitleTrack')));
    });

    test('autoplay: false is carried through, and true is left implicit',
        () async {
      const skipsAutoplay = LoadContentIntent(
        mediaItemId: 'movie-5',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: false,
      );

      final route = await resolveLoadContentRoute(
        skipsAutoplay,
        800,
        fetchMovieFiles: (id) async => [_file('only', '1080p')],
        fetchEpisodeFiles: _unreachable,
      );

      expect(route, contains('autoplay=false'));

      const playsImmediately = LoadContentIntent(
        mediaItemId: 'movie-6',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final defaultRoute = await resolveLoadContentRoute(
        playsImmediately,
        800,
        fetchMovieFiles: (id) async => [_file('only', '1080p')],
        fetchEpisodeFiles: _unreachable,
      );

      expect(defaultRoute, isNot(contains('autoplay')));
    });

    test('a fetch failure resolves to null rather than throwing', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-7',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieFiles: (id) async => throw Exception('server unreachable'),
        fetchEpisodeFiles: _unreachable,
      );

      expect(route, isNull);
    });

    test('no files at all resolves to null rather than throwing', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-8',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieFiles: (id) async => const [],
        fetchEpisodeFiles: _unreachable,
      );

      expect(route, isNull);
    });
  });
}
