import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_mapping.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

import 'mydia_fixtures.dart' as fx;

const s = SourceId(fx.sid);

void main() {
  test('season ids round-trip', () {
    final id = seasonExternalId('s-1', 2);
    expect(id, 's-1.s2');
    expect(parseSeasonExternalId(id), (showId: 's-1', seasonNumber: 2));
    expect(parseSeasonExternalId('m-1'), isNull);
  });

  test('a movie carries added and last played', () {
    final m = movieSummary(s, {
      ...fx.movie('m-1'),
      'addedAt': '2024-03-01T10:00:00Z',
      'progress': {
        'positionSeconds': 60,
        'watched': false,
        'lastWatchedAt': '2024-04-02T21:30:00Z',
      },
    });
    expect(m.addedAt, DateTime.utc(2024, 3, 1, 10));
    expect(m.lastPlayedAt, DateTime.utc(2024, 4, 2, 21, 30));
    expect(m.sortTitle, isNull);
  });

  test('a movie maps its summary, resume point and artwork', () {
    final m = movieSummary(s, fx.movie('m-1', position: 300));
    expect(m.ref,
        const ItemRef(sourceId: s, kind: ItemKind.movie, externalId: 'm-1'));
    expect(m.title, 'The Quiet Orchard m-1');
    expect(m.year, 2021);
    expect(m.poster, const ArtworkRef('https://img.example/m-1-poster.jpg'));
    expect(m.durationSeconds, 104 * 60);
    expect(m.userState.progressSeconds, 300);
    expect(m.userState.watched, isFalse);
    expect(m.defaultVersionId, 'f-m-1');
  });

  test('an image-based subtitle track is not offered', () {
    final f = fx.file('f-1');
    final subs = f['subtitles'] as List;
    subs.add({
      'trackId': 'sub-img',
      'language': 'fr',
      'title': 'French',
      'format': 'pgs',
      'embedded': false,
      'deliverable': false,
      'url': '/api/v1/subtitles/sub-img.vtt',
    });
    final v = mediaVersion(f, durationSeconds: 60);
    expect(v.streams.map((s) => s.id), ['sub-1']);
  });

  test('movie detail carries the version, sidecar subtitles and favorite', () {
    final d = movieDetail(s, fx.movie('m-1'));
    expect(d.summary.ref.externalId, 'm-1');
    expect(d.overview, 'A beekeeper inherits a valley.');
    expect(d.genres, ['Drama']);
    expect(d.contentRating, 'PG');
    expect(d.rating, 7.4);
    expect(d.isFavorite, isTrue);
    final v = d.versions.single;
    expect(v.id, 'f-m-1');
    expect(v.videoCodec, 'hevc');
    expect(v.audioCodec, 'eac3');
    expect(v.height, 1080);
    expect(v.bitrateKbps, 8000);
    expect(v.durationSeconds, 104 * 60);
    final sub = v.streams.single;
    expect(sub.kind, MediaStreamKind.subtitle);
    expect(sub.language, 'en');
    expect(sub.externalPath, '/api/v1/subtitles/sub-1.vtt');
  });

  test('show detail maps cast, trailer and watched state', () {
    final d = showDetail(s, fx.show('s-1'));
    expect(d.summary.ref.kind, ItemKind.show);
    expect(d.summary.childCount, 2);
    expect(d.cast.single.name, 'Ines Varga');
    expect(d.cast.single.role, 'Keeper');
    expect(
        d.cast.single.photo, const ArtworkRef('https://img.example/ines.jpg'));
    expect(d.trailerUrl, 'https://video.example/trailer');
    expect(d.isFavorite, isFalse);
  });

  test('seasons map with the show as parent and their own watched state', () {
    final season = seasonSummary(s, 's-1',
        (fx.show('s-1')['seasons'] as List).first as Map<String, dynamic>);
    expect(
        season.ref,
        const ItemRef(
            sourceId: s, kind: ItemKind.season, externalId: 's-1.s1'));
    expect(season.index, 1);
    expect(season.title, 'Season 1');
    expect(season.childCount, 3);
    expect(season.userState.watched, isTrue);
  });

  test('season detail links back to its show', () {
    final d = seasonDetail(s, fx.show('s-1'), 2);
    expect(d.summary.ref.externalId, 's-1.s2');
    expect(d.show,
        const ItemRef(sourceId: s, kind: ItemKind.show, externalId: 's-1'));
  });

  test('an episode maps numbers, air date and its show and season links', () {
    final d = episodeDetail(s, fx.episode('e-21'));
    expect(d.summary.index, 1);
    expect(d.summary.parentIndex, 2);
    expect(d.summary.airDate, '2019-04-02');
    expect(d.summary.showTitle, 'Lantern Street s-1');
    expect(d.summary.userState.progressSeconds, 60);
    expect(d.show,
        const ItemRef(sourceId: s, kind: ItemKind.show, externalId: 's-1'));
    expect(
        d.season,
        const ItemRef(
            sourceId: s, kind: ItemKind.season, externalId: 's-1.s2'));
    expect(d.versions.single.id, 'f-e-21');
  });

  test('continue watching maps movies and episodes, skips unknown types', () {
    final movie = continueWatchingSummary(s, {
      'id': 'm-1',
      'type': 'MOVIE',
      'title': 'The Quiet Orchard',
      'showId': null,
      'showTitle': null,
      'seasonNumber': null,
      'episodeNumber': null,
      'artwork': fx.art('m-1'),
      'progress': {
        'positionSeconds': 90,
        'durationSeconds': 6000,
        'percentage': 1.5,
        'watched': false,
        'lastWatchedAt': null
      },
      'files': [
        {'id': 'f-m-1'}
      ],
    });
    expect(movie!.ref.kind, ItemKind.movie);
    expect(movie.userState.progressSeconds, 90);
    expect(movie.defaultVersionId, 'f-m-1');

    final ep = continueWatchingSummary(s, {
      'id': 'e-21',
      'type': 'EPISODE',
      'title': 'Low Tide',
      'showId': 's-1',
      'showTitle': 'Lantern Street',
      'seasonNumber': 2,
      'episodeNumber': 1,
      'artwork': fx.art('s-1'),
      'progress': {
        'positionSeconds': 0,
        'durationSeconds': 1440,
        'percentage': 0.0,
        'watched': false,
        'lastWatchedAt': null
      },
      'files': [
        {'id': 'f-e-21'}
      ],
    });
    expect(ep!.ref.kind, ItemKind.episode);
    expect(ep.showTitle, 'Lantern Street');
    expect(ep.parentIndex, 2);
    expect(ep.index, 1);
    expect(ep.showRef,
        const ItemRef(sourceId: s, kind: ItemKind.show, externalId: 's-1'));
    expect(ep.dismissRef, ep.showRef);
    expect(movie.showRef, isNull);
    expect(movie.dismissRef, movie.ref);
    // The show ref survives the cache round trip, and an old record without
    // the key reads as none.
    expect(ItemSummary.fromJson(ep.toJson()).showRef, ep.showRef);
    expect(
        ItemSummary.fromJson((ep.toJson()..remove('showRef'))).showRef, isNull);

    expect(
        continueWatchingSummary(s, {
          'id': 'x',
          'type': 'TV_SHOW',
          'title': 'x',
          'progress': <String, dynamic>{}
        }),
        isNull);
  });

  test('search results map movies and shows, skip episodes without a parent',
      () {
    expect(
        searchResultSummary(s, {
          'id': 'm-1',
          'type': 'MOVIE',
          'title': 'A',
          'year': 2020,
          'artwork': fx.art('m-1')
        })!
            .ref
            .kind,
        ItemKind.movie);
    expect(
        searchResultSummary(s, {
          'id': 's-1',
          'type': 'TV_SHOW',
          'title': 'B',
          'year': 2019,
          'artwork': null
        })!
            .ref
            .kind,
        ItemKind.show);
    expect(
        searchResultSummary(s,
            {'id': 'e-1', 'type': 'EPISODE', 'title': 'C', 'parentId': null}),
        isNull);
  });

  test('missing artwork is no artwork', () {
    final m = fx.movie('m-2')
      ..['artwork'] = {
        'posterUrl': '',
        'backdropUrl': null,
        'thumbnailUrl': null
      };
    expect(movieSummary(s, m).poster, isNull);
  });

  test('movie and show summaries carry catalogue ids', () {
    final m = movieSummary(s, {
      'id': '1',
      'title': 'The Invented Voyage',
      'tmdbId': 42,
      'imdbId': 'tt0000042'
    });
    expect(m.externalIds, const ExternalIds(tmdb: '42', imdb: 'tt0000042'));
    final sh = showSummary(
        s, {'id': '2', 'title': 'Invented Harbour', 'tvdbId': 9001});
    expect(sh.externalIds, const ExternalIds(tvdb: '9001'));
  });
}
