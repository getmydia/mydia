import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/files/match/relay_tmdb.dart';

void main() {
  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  test('searchMovies sends query and year and reads candidates', () async {
    late Uri seen;
    final tmdb = RelayTmdb(
      baseUrl: 'https://relay.test',
      client: MockClient((r) async {
        seen = r.url;
        return json({
          'results': [
            {
              'id': 7,
              'title': 'Copper Valley',
              'original_title': 'Vallée',
              'release_date': '2018-05-01',
            },
          ],
        });
      }),
    );
    final c = await tmdb.searchMovies('Copper Valley', year: 2018);
    expect(seen.path, '/tmdb/movies/search');
    expect(seen.queryParameters, {'query': 'Copper Valley', 'year': '2018'});
    expect((c.single.id, c.single.title, c.single.year),
        (7, 'Copper Valley', 2018));
    expect(c.single.originalTitle, 'Vallée');
  });

  test('searchShows uses first_air_date_year only with a year', () async {
    final seen = <Uri>[];
    final tmdb = RelayTmdb(
      baseUrl: 'https://relay.test',
      client: MockClient((r) async {
        seen.add(r.url);
        return json({
          'results': [
            {'id': 3, 'name': 'Moon Harbor', 'first_air_date': '2001-01-01'},
          ],
        });
      }),
    );
    final c = await tmdb.searchShows('Moon Harbor', year: 2001);
    await tmdb.searchShows('Moon Harbor');
    expect(seen[0].path, '/tmdb/tv/search');
    expect(seen[0].queryParameters['first_air_date_year'], '2001');
    expect(seen[1].queryParameters.containsKey('first_air_date_year'), isFalse);
    expect(c.single.year, 2001);
  });

  test('429_throws_relay_unavailable', () async {
    final tmdb = RelayTmdb(
      baseUrl: 'https://relay.test',
      client: MockClient((_) async => http.Response('slow down', 429)),
    );
    expect(tmdb.searchMovies('x'), throwsA(isA<RelayUnavailable>()));
  });

  test('network errors and 404 on details are RelayUnavailable', () async {
    final down = RelayTmdb(
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    expect(down.movie(1), throwsA(isA<RelayUnavailable>()));
    final missing = RelayTmdb(
      client: MockClient((_) async => http.Response('nope', 404)),
    );
    expect(missing.movie(1), throwsA(isA<RelayUnavailable>()));
  });

  test('movie maps details', () async {
    final tmdb = RelayTmdb(
      client: MockClient((_) async => json({
            'title': 'Copper Valley',
            'release_date': '2018-05-01',
            'overview': 'Words',
            'poster_path': '/p.jpg',
            'backdrop_path': '/b.jpg',
            'runtime': 101,
          })),
    );
    final m = await tmdb.movie(7);
    expect((m.tmdbId, m.year, m.runtimeMinutes, m.posterPath),
        (7, 2018, 101, '/p.jpg'));
    expect(m.releaseDate, '2018-05-01');
  });

  test('show_fetches_only_requested_seasons', () async {
    final paths = <String>[];
    final tmdb = RelayTmdb(
      baseUrl: 'https://relay.test',
      client: MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path == '/tmdb/tv/shows/3') {
          return json({
            'name': 'Moon Harbor',
            'first_air_date': '2001-01-01',
            'episode_run_time': [45],
          });
        }
        return json({
          'episodes': [
            {
              'episode_number': 1,
              'name': 'Pilot',
              'still_path': '/s.jpg',
              'air_date': '2001-01-01'
            },
            {'episode_number': 2, 'name': 'Two', 'runtime': 50},
          ],
        });
      }),
    );
    final s = await tmdb.show(3, seasons: [2, 2, 4]);
    expect(paths,
        ['/tmdb/tv/shows/3', '/tmdb/tv/shows/3/2', '/tmdb/tv/shows/3/4']);
    expect(s.seasons.keys, unorderedEquals([2, 4]));
    final eps = s.seasons[2]!;
    expect(eps[0].runtimeMinutes, 45);
    expect(eps[1].runtimeMinutes, 50);
    expect(eps[0].stillPath, '/s.jpg');
    expect(s.year, 2001);
  });
}
