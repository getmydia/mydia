import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/hub.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

const _id = SourceId('acc1:owner:srv1');

const _episode = ItemSummary(
  ref: ItemRef(sourceId: _id, kind: ItemKind.episode, externalId: 'e7'),
  title: 'The Lantern Keeper',
  subtitle: 'S2 E7',
  showTitle: 'Harbor Lights',
  year: 2031,
  poster: ArtworkRef('/art/p.jpg'),
  backdrop: ArtworkRef('/art/b.jpg'),
  durationSeconds: 2640,
  userState: UserState(watched: true, progressSeconds: 120),
  childCount: 3,
  index: 7,
  parentIndex: 2,
  overview: 'A storm closes the harbor.',
  airDate: '2031-04-02',
  defaultVersionId: 'v1',
  sortTitle: 'Lantern Keeper, The',
);

final _detail = ItemDetail(
  summary: ItemSummary(
    ref: _episode.ref,
    title: _episode.title,
    addedAt: DateTime.utc(2031, 4, 3, 10),
    lastPlayedAt: DateTime.utc(2031, 4, 5, 21, 30),
  ),
  overview: 'Long overview',
  genres: const ['Drama'],
  people: const ['Ada Quill'],
  studio: 'North Pier',
  tags: const ['coastal'],
  rating: 7.5,
  versions: const [
    MediaVersion(
      id: 'v1',
      container: 'mkv',
      videoCodec: 'hevc',
      audioCodec: 'eac3',
      height: 2160,
      bitrateKbps: 18000,
      durationSeconds: 2640,
      streamPath: '/parts/1/file.mkv',
      streams: [
        MediaStreamInfo(
          id: 's1',
          kind: MediaStreamKind.subtitle,
          codec: 'srt',
          language: 'en',
          title: 'English',
          isDefault: true,
          externalPath: '/subs/1.srt',
        ),
      ],
    ),
  ],
  cast: const [
    Person(name: 'Ada Quill', role: 'Keeper', photo: ArtworkRef('/p/1.jpg')),
  ],
  trailerUrl: 'https://example.test/trailer',
  contentRating: 'TV-14',
  isFavorite: true,
  show: const ItemRef(sourceId: _id, kind: ItemKind.show, externalId: 's1'),
  season:
      const ItemRef(sourceId: _id, kind: ItemKind.season, externalId: 'se2'),
);

/// Through a real JSON string, as the cache stores it.
Map<String, Object?> _viaString(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  test('a fully populated summary survives the codec', () {
    final json = _episode.toJson();
    expect(ItemSummary.fromJson(_viaString(json)).toJson(), json);
  });

  test('a fully populated detail survives the codec', () {
    final json = _detail.toJson();
    expect(ItemDetail.fromJson(_viaString(json)).toJson(), json);
  });

  test('a minimal summary survives the codec', () {
    const minimal = ItemSummary(
      ref: ItemRef(sourceId: _id, kind: ItemKind.movie, externalId: 'm1'),
      title: 'Quiet Orchard',
    );
    final json = minimal.toJson();
    final back = ItemSummary.fromJson(_viaString(json));
    expect(back.toJson(), json);
    expect(back.userState.watched, isFalse);
  });

  test('a library and a page survive the codec', () {
    const library = Library(
      ref: LibraryRef(sourceId: _id, id: '3'),
      title: 'Films',
      kind: LibraryKind.movies,
      sortOptions: [
        SortOption(
          id: 'addedAt',
          label: 'Recently added',
          descendingByDefault: true,
          shared: SharedSort.added,
        ),
      ],
      filterOptions: [FilterOption(id: 'unwatched', label: 'Unwatched')],
    );
    expect(Library.fromJson(_viaString(library.toJson())).toJson(),
        library.toJson());

    const page = Page(items: [_episode], nextCursor: Cursor('60'), total: 130);
    final json = page.toJson((i) => i.toJson());
    final back = Page.fromJson(_viaString(json), ItemSummary.fromJson);
    expect(back.toJson((i) => i.toJson()), json);
    expect(back.hasMore, isTrue);
  });

  test('a hub survives the codec', () {
    const hub = Hub(
      id: 'home.recent',
      title: 'Recently Released',
      items: [_episode],
      library: LibraryRef(sourceId: _id, id: '3'),
    );
    expect(Hub.fromJson(_viaString(hub.toJson())).toJson(), hub.toJson());
  });
}
