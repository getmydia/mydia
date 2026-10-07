import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_filters.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/library/library_sort.dart';

import 'mydia_fixtures.dart' as fx;

const sid = SourceId(fx.sid);

void main() {
  test('collections are listed', () async {
    final b = fx.build();
    final all = await b.source.collections();
    expect(all.map((c) => c.sourceId), everyElement(b.source.id));
    expect(all.map((c) => c.name), ['Invented Shelf c1', 'Invented Shelf c2']);
    expect(all.map((c) => c.smart), [false, true]);
    expect(all.first.posters.length, 1);
  });

  test('collection items are one page', () async {
    final b = fx.build();
    b.t.handlers['CollectionItems'] = (_) => {
          'collectionItems': [
            for (var i = 0; i < 23; i++) fx.listing('i-$i'),
          ]
        };
    final page = await b.source.collectionItems('c1');
    expect(b.t.calls.last.vars, {'collectionId': 'c1', 'first': 50});
    expect(page.items.length, 23);
    expect(page.nextCursor, isNull);

    b.t.calls.clear();
    final next =
        await b.source.collectionItems('c1', cursor: const Cursor('x'));
    expect(next.items, isEmpty);
    expect(b.t.calls, isEmpty);
  });

  test('calendar sends local ISO dates and sorts by air date', () async {
    final b = fx.build();
    b.t.handlers['Calendar'] = (_) => {
          'calendar': [
            fx.calendarEntry('late', airDate: '2026-10-20'),
            fx.calendarEntry('film', kind: 'movie', airDate: '2026-10-02'),
          ]
        };
    final items =
        await b.source.calendar(DateTime(2026, 10, 1), DateTime(2026, 10, 31));
    expect(b.t.calls.last.vars, {'start': '2026-10-01', 'end': '2026-10-31'});
    expect(items.map((i) => i.airDate), ['2026-10-02', '2026-10-20']);
    final movie = items.first;
    expect(movie.ref.kind, ItemKind.movie);
    expect(movie.ref.externalId, 'item-film');
    final episode = items.last;
    expect(episode.ref.kind, ItemKind.episode);
    expect(episode.ref.externalId, 'late');
    expect(episode.showTitle, 'Lantern Street');
    expect(episode.parentIndex, 2);
    expect(episode.index, 5);
    expect(episode.defaultVersionId, 'cf-2');
  });

  test('unwatched and favorites map watch state and counts', () async {
    final b = fx.build();
    b.t.handlers['UnwatchedListing'] = (_) => {
          'unwatched': [
            fx.listing('s-1', type: 'TV_SHOW', unwatched: 4),
            fx.listing('s-2',
                type: 'TV_SHOW',
                newEpisodes: 1,
                latestSeason: 1,
                latestEpisode: 2),
          ]
        };
    final page = await b.source.unwatched();
    expect(page.items.first.userState.unwatchedCount, 4);
    expect(page.items.last.subtitle, 'S01E02');
    expect(page.nextCursor, isNull);
    expect(b.t.calls.last.vars['first'], 20);
  });

  test('a full flat page carries the offset cursor of its last item', () async {
    final b = fx.build();
    b.t.handlers['FavoritesListing'] = (_) => {
          'favorites': [for (var i = 0; i < 20; i++) fx.listing('m-$i')]
        };
    final first = await b.source.favorites();
    expect(first.nextCursor?.value, offsetCursor(19));
    await b.source.favorites(cursor: first.nextCursor);
    expect(b.t.calls.last.vars['after'], offsetCursor(19));
  });

  test('filterQuery maps a saved filter', () {
    final b = fx.build();
    final category = MediaCategoryFilter.forKind(MediaKind.shows).first;
    final q = b.source.filterQuery(MediaFilter(
      kind: MediaKind.shows,
      category: category,
      watch: WatchScope.unwatched,
      sort: const LibrarySort(
          field: SortField.year, direction: SortDirection.desc),
    ));
    expect(q?.library, const LibraryRef(sourceId: sid, id: 'shows'));
    expect(
        q?.query,
        BrowseQuery(sortId: 'YEAR', descending: true, filterIds: {
          'watch:unwatched',
          'category:${category.wireName}',
        }));
  });

  test('browse with watch:favorites uses FavoritesListing', () async {
    final b = fx.build();
    b.t.handlers['FavoritesListing'] = (_) => {
          'favorites': [fx.listing('s-1', type: 'TV_SHOW')]
        };
    final page = await b.source.browse(
        const LibraryRef(sourceId: sid, id: 'shows'),
        const BrowseQuery(filterIds: {'watch:favorites'}));
    expect(b.t.calls.last.operation, 'FavoritesListing');
    expect(b.t.calls.last.vars['types'], ['TV_SHOW']);
    expect(page.items.length, 1);
  });

  test('hubs surface a schema rejection once the ids-free document fails too',
      () async {
    final b = fx.build();
    b.t.handlers['HomeRows'] = (_) =>
        throw const SourceException.server('Cannot query field "watchStatus"');
    b.t.handlers['HomeRowsNoIds'] = (_) =>
        throw const SourceException.server('Cannot query field "watchStatus"');
    b.t.calls.clear();
    await expectLater(b.source.hubs(), throwsA(isA<SourceException>()));
    expect(b.t.calls.map((c) => c.operation), ['HomeRows', 'HomeRowsNoIds']);
  });

  test('a server without catalogue ids keeps its rails', () async {
    final b = fx.build();
    b.t.handlers['HomeRows'] = (_) => throw const SourceException.server(
        'Cannot query field "tmdbId" on type "RecentlyAddedItem".');
    b.t.handlers['HomeRowsNoIds'] = (_) => {
          'recentlyAdded': [fx.listing('m-4')],
          'favorites': [fx.listing('s-1', type: 'TV_SHOW')],
        };
    final hubs = await b.source.hubs();
    expect(hubs.length, 2);
    expect(hubs.first.items.single.externalIds, ExternalIds.none);
    b.t.calls.clear();
    await b.source.hubs();
    expect(b.t.calls.map((c) => c.operation), ['HomeRowsNoIds']);
  });

  test('media info surfaces a schema rejection without a second document',
      () async {
    final b = fx.build();
    b.t.handlers['MovieMediaInfo'] = (_) =>
        throw const SourceException.server('Cannot query field "streams"');
    b.t.calls.clear();
    await expectLater(
      b.source.mediaInfo(const ItemRef(
          sourceId: sid, kind: ItemKind.movie, externalId: 'm-1')),
      throwsA(isA<SourceException>()),
    );
    expect(b.t.calls.map((c) => c.operation), ['MovieMediaInfo']);
  });

  test('registerNode never throws', () async {
    final b = fx.build();
    expect(await b.source.registerNode('node-1'), isTrue);
    b.t.handlers['RegisterDeviceNode'] = (_) => throw StateError('boom');
    expect(await b.source.registerNode('node-1'), isFalse);
  });

  test('revokeDevice sends the id', () async {
    final b = fx.build();
    expect(await b.source.revokeDevice('d1'), isTrue);
    expect(b.t.calls.last.operation, 'RevokeDevice');
    expect(b.t.calls.last.vars, {'id': 'd1'});
  });

  test('devices are mapped from the list', () async {
    final b = fx.build();
    b.t.handlers['DevicesList'] = (_) => {
          'devices': [
            {
              'id': 'd1',
              'deviceName': 'Den TV',
              'platform': 'android',
              'lastSeenAt': null,
              'isRevoked': false,
              'createdAt': '2026-01-02T03:04:05Z',
            }
          ]
        };
    final devices = await b.source.devices();
    expect(devices.single.deviceName, 'Den TV');
    expect(devices.single.lastSeenAt, isNull);
  });
}
