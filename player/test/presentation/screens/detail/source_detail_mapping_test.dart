import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_art.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/source_detail_mapping.dart';

import '../sources/fake_media_source.dart';

void main() {
  const features = {DetailFeature.watched};

  test('a source movie keeps its fields and gains no Mydia features', () {
    final detail = ItemDetail(
      summary: fakeMovie(1, progress: 600),
      overview: 'Invented overview.',
      genres: const ['Drama'],
      contentRating: 'PG',
      rating: 7.25,
      trailerUrl: 'https://video.test/t',
      cast: const [
        Person(name: 'Ana Bergstrom', role: 'Kira', photo: ArtworkRef('/p/1')),
      ],
      versions: const [
        MediaVersion(
            id: 'part-1',
            container: 'mkv',
            height: 1080,
            videoCodec: 'hevc',
            bitrateKbps: 8000),
      ],
    );
    final v = movieViewFromSource(detail, features: features);
    expect(v.target, SourceTarget(fakeMovie(1).ref));
    expect(v.year, 2001);
    expect(v.runtime, 100);
    expect(
        v.backdrop, const SourceArt(fakeSourceId, ArtworkRef('/backdrop/m1')));
    expect(v.progress?.positionSeconds, 600);
    expect(v.progress?.percentage, closeTo(10, 0.01));
    expect(v.files.single.id, 'part-1');
    expect(v.files.single.resolution, '1080p');
    expect(v.files.single.bitrate, 8000000);
    expect(
        v.cast.single.photo, const SourceArt(fakeSourceId, ArtworkRef('/p/1')));
    expect(v.features, features);
  });

  test('a source show lists seasons by index and its next up', () {
    final view = showViewFromSource(
      const ItemDetail(summary: fakeShow),
      const [fakeSeason],
      features: features,
      nextUp: fakeEpisode(2),
    );
    expect(view.seasons.single.number, 1);
    expect(view.seasons.single.target, SourceTarget(fakeSeason.ref));
    expect(view.nextUpEpisodeId, 'e2');
    expect(view.nextUpSeasonNumber, 1);
  });

  test('a source episode in a list plays its default version', () {
    final e = ItemSummary(
      ref: fakeEpisode(1).ref,
      title: 'Invented Episode 1',
      index: 1,
      parentIndex: 1,
      defaultVersionId: 'part-9',
    );
    final v = episodeViewFromSource(e,
        showTitle: 'Invented Series', features: features);
    expect(v.files.single.id, 'part-9');
    expect(v.episodeCode, 'S01E01');
  });

  test('progress from user state', () {
    expect(progressFromUserState(const UserState(), 100), isNull);
    expect(progressFromUserState(const UserState(watched: true), 100)?.watched,
        isTrue);
  });

  test('a target names its item, and only some kinds have a detail screen', () {
    expect(SourceTarget(fakeMovie(1).ref).ref, fakeMovie(1).ref);
    expect(detailKindOf(ItemKind.video), isNull);
  });
}
