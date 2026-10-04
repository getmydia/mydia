// player/test/presentation/screens/detail/mydia_detail_mapping_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_art.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/models/episode.dart';
import 'package:player/domain/models/episode_detail.dart';
import 'package:player/domain/models/movie_detail.dart';
import 'package:player/domain/models/show_detail.dart';
import 'package:player/presentation/screens/detail/mydia_detail_mapping.dart';

final _movieJson = <String, dynamic>{
  'id': 'm-1',
  'title': 'Meridian Drift',
  'originalTitle': null,
  'year': 2024,
  'overview': 'A drifting research platform runs out of air.',
  'runtime': 146,
  'genres': ['Sci-Fi'],
  'contentRating': 'PG-13',
  'rating': 8.1,
  'tmdbId': null,
  'imdbId': null,
  'category': null,
  'monitored': true,
  'addedAt': null,
  'artwork': {
    'posterUrl': 'https://img.test/p.jpg',
    'backdropUrl': 'https://img.test/b.jpg',
    'thumbnailUrl': null,
  },
  'progress': null,
  'files': [
    {'id': 'f1', 'resolution': '1080p', 'directPlaySupported': true},
  ],
  'isFavorite': true,
  'cast': [
    {'name': 'Ana Bergström', 'character': 'Kira Solt', 'profileUrl': null},
    {
      'name': 'Tomas Ilve',
      'character': null,
      'profileUrl': 'https://img.test/t.jpg'
    },
  ],
  'trailerUrl': 'https://video.test/trailer',
  'similar': <dynamic>[],
};

void main() {
  test('movieViewFromMydia keeps every field the screen renders', () {
    final m = MovieDetail.fromJson(_movieJson);
    final v = movieViewFromMydia(m);
    expect(v.target, const MydiaTarget(DetailKind.movie, 'm-1'));
    expect(v.title, 'Meridian Drift');
    expect(v.runtime, 146);
    expect(v.contentRating, 'PG-13');
    expect(v.backdrop, const UrlArt('https://img.test/b.jpg'));
    expect(v.poster, const UrlArt('https://img.test/p.jpg'));
    expect(v.files.single.id, 'f1');
    expect(v.isFavorite, isTrue);
    expect(v.trailerUrl, 'https://video.test/trailer');
    expect(v.cast.map((c) => c.name), ['Ana Bergström', 'Tomas Ilve']);
    expect(v.cast.first.photo, isNull);
    expect(v.cast.last.photo, const UrlArt('https://img.test/t.jpg'));
    expect(v.features, mydiaFeatures);
    expect(v.mydia, same(m));
  });

  test('episodeViewFromMydia carries the show it belongs to', () {
    final e = Episode.fromJson({
      'id': 'e-9',
      'seasonNumber': 1,
      'episodeNumber': 3,
      'title': 'Copper Weather',
      'overview': null,
      'airDate': '2024-03-01',
      'runtime': 42,
      'monitored': true,
      'thumbnailUrl': 'https://img.test/e9.jpg',
      'hasFile': true,
      'progress': null,
      'files': <dynamic>[],
    });
    final v = episodeViewFromMydia(e, show: null);
    expect(v.target, const MydiaTarget(DetailKind.episode, 'e-9'));
    expect(v.still, const UrlArt('https://img.test/e9.jpg'));
    expect(v.episodeCode, 'S01E03');
    expect(v.mydia, same(e));
  });

  test('episodeViewFromMydiaDetail links back to the show', () {
    final d = EpisodeDetail.fromJson({
      'id': 'e-9',
      'seasonNumber': 1,
      'episodeNumber': 3,
      'title': 'Copper Weather',
      'overview': 'Rain on the tin roofs.',
      'airDate': null,
      'runtime': 42,
      'monitored': true,
      'thumbnailUrl': null,
      'hasFile': true,
      'progress': null,
      'files': <dynamic>[],
      'show': {
        'id': 's-2',
        'title': 'Invented Series',
        'artwork': {
          'posterUrl': null,
          'backdropUrl': 'https://img.test/sb.jpg',
          'thumbnailUrl': null,
        },
      },
    });
    final v = episodeViewFromMydiaDetail(d);
    expect(v.showTarget, const MydiaTarget(DetailKind.show, 's-2'));
    expect(v.showTitle, 'Invented Series');
    expect(v.showBackdrop, const UrlArt('https://img.test/sb.jpg'));
    expect(v.mydiaDetail, same(d));
  });

  test('showViewFromMydia maps seasons and next up', () {
    final s = ShowDetail.fromJson({
      'id': 's-2',
      'title': 'Invented Series',
      'genres': <dynamic>[],
      'monitored': true,
      'seasonCount': 1,
      'episodeCount': 2,
      'artwork': {'posterUrl': null, 'backdropUrl': null, 'thumbnailUrl': null},
      'seasons': [
        {'seasonNumber': 1, 'episodeCount': 2, 'hasFiles': true},
      ],
      'isFavorite': false,
      'cast': <dynamic>[],
      'similar': <dynamic>[],
    });
    final v = showViewFromMydia(s);
    expect(v.target, const MydiaTarget(DetailKind.show, 's-2'));
    expect(v.seasons.single.number, 1);
    expect(v.seasons.single.hasFiles, isTrue);
    expect(v.nextUpEpisodeId, isNull);
  });

  test('showViewFromMydia names the next up episode and its season', () {
    final s = ShowDetail.fromJson({
      'id': 's-3',
      'title': 'Another Invented Series',
      'status': 'Continuing',
      'monitored': true,
      'isFavorite': false,
      'nextUp': {
        'progressState': 'next',
        'episode': {'id': 'e-5', 'seasonNumber': 2, 'episodeNumber': 1},
      },
    });
    final v = showViewFromMydia(s);
    expect(v.nextUpEpisodeId, 'e-5');
    expect(v.nextUpSeasonNumber, 2);
    expect(v.status, 'Continuing');
  });
}
