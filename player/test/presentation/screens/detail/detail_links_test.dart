import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/query_keys.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/screens/detail/detail_providers.dart';

void main() {
  const file = MediaFile(id: 'f1', directPlaySupported: true);

  test('Mydia detail locations keep their routes', () {
    expect(
      detailLocation(const MydiaTarget(DetailKind.movie, 'm1')),
      '/movie/m1',
    );
    expect(
      detailLocation(const MydiaTarget(DetailKind.show, 's1')),
      '/show/s1',
    );
    expect(
      detailLocation(const MydiaTarget(DetailKind.episode, 'e1')),
      '/episode/e1',
    );
  });

  test('a Mydia movie plays through /player/movie', () {
    const movie = MovieView(
      target: MydiaTarget(DetailKind.movie, 'm1'),
      title: 'Meridian Drift',
    );
    expect(
      moviePlayerLocation(movie, file),
      '/player/movie/m1?fileId=f1&title=Meridian%20Drift',
    );
  });

  const episode = EpisodeView(
    target: MydiaTarget(DetailKind.episode, 'e1'),
    showTarget: MydiaTarget(DetailKind.show, 's1'),
    showTitle: 'Invented Series',
    seasonNumber: 2,
    episodeNumber: 4,
    title: 'Glass',
  );

  test('a Mydia episode plays with its show and season', () {
    expect(
      episodePlayerLocation(episode, file, resumeSeconds: 300),
      '/player/episode/e1?fileId=f1'
      '&title=${Uri.encodeComponent('Invented Series - S02E04')}'
      '&showId=s1&seasonNumber=2&resume=300',
    );
  });

  test('an episode without resume omits the suffix', () {
    expect(
      episodePlayerLocation(episode, file),
      '/player/episode/e1?fileId=f1'
      '&title=${Uri.encodeComponent('Invented Series - S02E04')}'
      '&showId=s1&seasonNumber=2',
    );
  });

  test('freshness keys match the controllers', () {
    expect(
      freshnessKeys(const MydiaTarget(DetailKind.movie, 'm1')),
      [QueryKeys.movieDetail('m1')],
    );
    expect(
      freshnessKeys(const MydiaTarget(DetailKind.show, 's1'), seasonNumber: 2),
      [QueryKeys.showDetail('s1'), QueryKeys.seasonEpisodes('s1', 2)],
    );
    expect(
      freshnessKeys(const MydiaTarget(DetailKind.episode, 'e1')),
      [QueryKeys.episodeDetail('e1')],
    );
  });
}
