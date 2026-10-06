import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/screens/detail/detail_providers.dart';

void main() {
  const file = MediaFile(id: 'f1', directPlaySupported: true);

  const src = SourceId('a:o:s');
  const movieRef =
      ItemRef(sourceId: src, kind: ItemKind.movie, externalId: 'm1');
  const showRef = ItemRef(sourceId: src, kind: ItemKind.show, externalId: 's1');
  const episodeRef =
      ItemRef(sourceId: src, kind: ItemKind.episode, externalId: 'e1');

  test('detail locations name the source and the kind', () {
    expect(detailLocation(const SourceTarget(movieRef)), '/s/a:o:s/movie/m1');
    expect(detailLocation(const SourceTarget(showRef)), '/s/a:o:s/show/s1');
    expect(
      detailLocation(const SourceTarget(episodeRef)),
      '/s/a:o:s/episode/e1',
    );
  });

  test('a movie plays through its source player route', () {
    const movie = MovieView(
      target: SourceTarget(movieRef),
      title: 'Meridian Drift',
    );
    expect(
      moviePlayerLocation(movie, file),
      '/s/a:o:s/player/m1?kind=movie&fileId=f1&title=Meridian+Drift',
    );
  });

  const episode = EpisodeView(
    target: SourceTarget(episodeRef),
    showTarget: SourceTarget(showRef),
    showTitle: 'Invented Series',
    seasonNumber: 2,
    episodeNumber: 4,
    title: 'Glass',
  );

  test('an episode plays with its show and season', () {
    expect(
      episodePlayerLocation(episode, file, resumeSeconds: 300),
      '/s/a:o:s/player/e1?kind=episode&fileId=f1'
      '&title=Invented+Series+-+S02E04'
      '&showId=s1&seasonNumber=2&resume=300',
    );
  });

  test('an episode without resume omits the suffix', () {
    expect(
      episodePlayerLocation(episode, file),
      '/s/a:o:s/player/e1?kind=episode&fileId=f1'
      '&title=Invented+Series+-+S02E04'
      '&showId=s1&seasonNumber=2',
    );
  });

  test('freshness keys follow the item, and a show also its children', () {
    expect(
      freshnessKeys(const SourceTarget(movieRef)),
      [SourceKeys.item(movieRef)],
    );
    expect(
      freshnessKeys(const SourceTarget(showRef)),
      [SourceKeys.item(showRef), SourceKeys.children(showRef)],
    );
    expect(
      freshnessKeys(const SourceTarget(episodeRef)),
      [SourceKeys.item(episodeRef)],
    );
  });

  group('source locations', () {
    const id = SourceId('a:o:s');
    const ref =
        ItemRef(sourceId: id, kind: ItemKind.movie, externalId: 'x/y 1');

    test('home, library, search, listings, collection and filter', () {
      expect(sourceHomeLocation(id), '/s/a:o:s');
      expect(sourceLibraryLocation(const LibraryRef(sourceId: id, id: 'l/1')),
          '/s/a:o:s/library/l%2F1');
      expect(sourceSearchLocation(id), '/s/a:o:s/search');
      expect(sourceSearchLocation(id, query: 'a b'), '/s/a:o:s/search?q=a+b');
      expect(sourceListingLocation(id, SourceListing.recentlyAdded),
          '/s/a:o:s/recently-added');
      expect(sourceListingLocation(id, SourceListing.continueWatching),
          '/s/a:o:s/continue-watching');
      expect(collectionLocation(id, 'x/y'), '/s/a:o:s/collection/x%2Fy');
      expect(filterLocation(id, 'f 1'), '/s/a:o:s/filter/f%201');
    });

    test('every listing has a distinct segment under the source', () {
      final all = [
        for (final l in SourceListing.values) sourceListingLocation(id, l)
      ];
      expect(all.toSet(), hasLength(SourceListing.values.length));
    });

    test('item locations encode ids and route videos to the item route', () {
      expect(sourceItemLocation(ref), '/s/a:o:s/movie/x%2Fy%201');
      expect(
          sourceItemLocation(const ItemRef(
              sourceId: id, kind: ItemKind.video, externalId: 'v/1')),
          '/s/a:o:s/item/video/v%2F1');
    });

    // Uri(pathSegments:) keeps `:` and `@` literal (the old encodeComponent
    // wrote %3A/%40); go_router decodes both forms to the same id.
    test('ids keep `:` and `@` literal and encode `/`', () {
      const colon =
          ItemRef(sourceId: id, kind: ItemKind.movie, externalId: 'a:b@c');
      expect(sourceItemLocation(colon), '/s/a:o:s/movie/a:b@c');
      const slash =
          ItemRef(sourceId: id, kind: ItemKind.movie, externalId: 'a/b');
      expect(sourceItemLocation(slash), '/s/a:o:s/movie/a%2Fb');
      expect(sourcePlayerLocation(slash), startsWith('/s/a:o:s/player/a%2Fb?'));
      expect(Uri.parse(sourceItemLocation(slash)).pathSegments.last, 'a/b');
    });

    test('the player location carries kind, file, title and extras', () {
      expect(
        sourcePlayerLocation(ref,
            fileId: 'f1', title: 'Quill Harbor', extra: {'resume': '5'}),
        '/s/a:o:s/player/x%2Fy%201'
        '?kind=movie&fileId=f1&title=Quill+Harbor&resume=5',
      );
      expect(sourcePlayerLocation(ref), '/s/a:o:s/player/x%2Fy%201?kind=movie');
    });
  });
}
