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

LoadContentTarget _target(
  List<MediaFile> files, {
  String title = 'Untitled fixture',
  String? showId,
  int? seasonNumber,
}) =>
    LoadContentTarget(
      files: files,
      title: title,
      showId: showId,
      seasonNumber: seasonNumber,
    );

/// Fails the test outright if called: the movie side of a `LoadContent`
/// resolution should never be reached for an intent carrying an episode id.
Future<LoadContentTarget> _unreachable(String id) {
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
        fetchMovieTarget: (id) async {
          expect(id, 'movie-1');
          return _target(files, title: 'Arrival');
        },
        fetchEpisodeTarget: _unreachable,
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
        fetchMovieTarget: _unreachable,
        fetchEpisodeTarget: (id) async {
          expect(id, 'ep-9');
          return _target([_file('ep-file', '720p')], title: 'Half Loop');
        },
      );

      expect(route, startsWith('/player/episode/ep-9?'));
      expect(route, contains('fileId=ep-file'));
    });

    test(
        'a movie carries its title, so describe() never falls back to '
        "'Untitled'", () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-title',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieTarget: (id) async =>
            _target([_file('only', '1080p')], title: 'Arrival'),
        fetchEpisodeTarget: _unreachable,
      );

      expect(route, contains('title=Arrival'));
    });

    test(
        'an episode carries showId and seasonNumber, so next/previous-episode '
        'stays available on a remotely-started episode', () async {
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
        fetchMovieTarget: _unreachable,
        fetchEpisodeTarget: (id) async => _target(
          [_file('ep-file', '720p')],
          title: 'Half Loop',
          showId: 'show-1',
          seasonNumber: 2,
        ),
      );

      expect(route, contains('title=Half+Loop'));
      expect(route, contains('showId=show-1'));
      expect(route, contains('seasonNumber=2'));
    });

    test('a movie omits showId and seasonNumber, which a movie has no use for',
        () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-9',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      final route = await resolveLoadContentRoute(
        intent,
        800,
        fetchMovieTarget: (id) async => _target([_file('only', '1080p')]),
        fetchEpisodeTarget: _unreachable,
      );

      expect(route, isNot(contains('showId')));
      expect(route, isNot(contains('seasonNumber')));
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
        fetchMovieTarget: (id) async => _target([_file('only', '1080p')]),
        fetchEpisodeTarget: _unreachable,
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
        fetchMovieTarget: (id) async => _target([_file('only', '1080p')]),
        fetchEpisodeTarget: _unreachable,
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
        fetchMovieTarget: (id) async => _target([_file('only', '1080p')]),
        fetchEpisodeTarget: _unreachable,
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
        fetchMovieTarget: (id) async => _target([_file('only', '1080p')]),
        fetchEpisodeTarget: _unreachable,
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
        fetchMovieTarget: (id) async => _target([_file('only', '1080p')]),
        fetchEpisodeTarget: _unreachable,
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
        fetchMovieTarget: (id) async => throw Exception('server unreachable'),
        fetchEpisodeTarget: _unreachable,
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
        fetchMovieTarget: (id) async => _target(const []),
        fetchEpisodeTarget: _unreachable,
      );

      expect(route, isNull);
    });
  });

  group('pushLoadContentDestination', () {
    test('pushes the resolved player route when resolution succeeds', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-1',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      String? pushed;

      await pushLoadContentDestination(
        intent,
        800,
        fetchMovieTarget: (id) async =>
            _target([_file('only', '1080p')], title: 'Arrival'),
        fetchEpisodeTarget: _unreachable,
        push: (path) => pushed = path,
      );

      expect(pushed, isNotNull);
      expect(pushed, startsWith('/player/movie/movie-1?'));
      expect(pushed, contains('fileId=only'));
    });

    test(
        'falls back to the movie detail screen — never throws — when '
        'resolution fails', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'movie-dead',
        episodeId: null,
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      String? pushed;

      await pushLoadContentDestination(
        intent,
        800,
        fetchMovieTarget: (id) async => throw Exception('server unreachable'),
        fetchEpisodeTarget: _unreachable,
        push: (path) => pushed = path,
      );

      expect(pushed, '/movie/movie-dead');
    });

    test(
        'falls back to the episode detail screen when nothing resolves to a '
        'playable file', () async {
      const intent = LoadContentIntent(
        mediaItemId: 'show-1',
        episodeId: 'ep-empty',
        startAt: Duration.zero,
        audioTrack: null,
        subtitleTrack: null,
        autoplay: true,
      );

      String? pushed;

      await pushLoadContentDestination(
        intent,
        800,
        fetchMovieTarget: _unreachable,
        fetchEpisodeTarget: (id) async => _target(const []),
        push: (path) => pushed = path,
      );

      expect(pushed, '/episode/ep-empty');
    });
  });
}
