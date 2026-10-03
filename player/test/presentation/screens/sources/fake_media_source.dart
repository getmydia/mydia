import 'package:flutter/foundation.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/hub.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

const fakeSourceId = SourceId('acc1:owner:aa11');

const fakeSource = Source(
  account: ProviderAccount(
    id: 'acc1',
    kind: SourceKind.plex,
    displayName: 'quill',
    storageNamespace: 'source/acc1',
    activeProfileId: 'owner',
  ),
  profile: SourceProfile(
      id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
  server: SourceServer(
      id: 'aa11', accountId: 'acc1', profileId: 'owner', name: 'Attic'),
);

ItemSummary fakeMovie(int n, {bool watched = false, int? progress}) =>
    ItemSummary(
      ref: ItemRef(
          sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm$n'),
      title: 'Invented Film $n',
      year: 2000 + n,
      poster: ArtworkRef('/art/m$n'),
      backdrop: ArtworkRef('/backdrop/m$n'),
      durationSeconds: 6000,
      userState: UserState(watched: watched, progressSeconds: progress),
    );

const fakeShow = ItemSummary(
  ref: ItemRef(sourceId: fakeSourceId, kind: ItemKind.show, externalId: 's1'),
  title: 'Invented Series',
  childCount: 1,
);

const fakeSeason = ItemSummary(
  ref:
      ItemRef(sourceId: fakeSourceId, kind: ItemKind.season, externalId: 'se1'),
  title: 'Season 1',
  index: 1,
);

ItemSummary fakeEpisode(int n) => ItemSummary(
      ref: ItemRef(
          sourceId: fakeSourceId, kind: ItemKind.episode, externalId: 'e$n'),
      title: 'Invented Episode $n',
      subtitle: 'S1 · E$n',
      index: n,
      parentIndex: 1,
      durationSeconds: 1800,
    );

class FakeMediaSource extends MediaSource implements WatchedState, Searchable {
  FakeMediaSource({this.movieCount = 7, this.failWith});

  final int movieCount;

  /// When set, every browse call throws it.
  SourceException? failWith;
  final watchedCalls = <(ItemRef, bool)>[];
  final browseCalls = <(BrowseQuery, Cursor?)>[];
  final _status = ValueNotifier(SourceConnectionStatus.local);

  static const movies = LibraryRef(sourceId: fakeSourceId, id: 'movies');
  static const shows = LibraryRef(sourceId: fakeSourceId, id: 'shows');

  @override
  Source get source => fakeSource;

  @override
  Set<SourceCapability> get capabilities => const {
        SourceCapability.watchedState,
        SourceCapability.searchable,
      };

  @override
  SourceConnectionStatus get connection => _status.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable => _status;

  @override
  T? as<T extends Object>() => this is T ? this as T : null;

  @override
  Future<List<Library>> libraries() async {
    if (failWith case final e?) throw e;
    return const [
      Library(
        ref: movies,
        title: 'Films',
        kind: LibraryKind.movies,
        sortOptions: [
          SortOption(id: 'title', label: 'Title'),
          SortOption(
              id: 'added', label: 'Recently added', descendingByDefault: true),
        ],
        filterOptions: [FilterOption(id: 'unwatched', label: 'Unwatched')],
      ),
      Library(
          ref: shows,
          title: 'Series',
          kind: LibraryKind.shows,
          sortOptions: [SortOption(id: 'title', label: 'Title')]),
    ];
  }

  @override
  Future<Page<ItemSummary>> browse(LibraryRef library, BrowseQuery query,
      {Cursor? cursor}) async {
    browseCalls.add((query, cursor));
    if (failWith case final e?) throw e;
    if (library == shows) return const Page(items: [fakeShow], total: 1);
    final all = [for (var n = 1; n <= movieCount; n++) fakeMovie(n)];
    final start = int.tryParse(cursor?.value ?? '') ?? 0;
    final page = all.skip(start).take(query.pageSize).toList();
    final next = start + page.length;
    return Page(
      items: page,
      total: all.length,
      nextCursor: next < all.length ? Cursor('$next') : null,
    );
  }

  @override
  Future<ItemDetail> item(ItemRef ref) async {
    if (ref.kind == ItemKind.show) {
      return const ItemDetail(
          summary: fakeShow, overview: 'An invented series.');
    }
    if (ref.kind == ItemKind.season) {
      return const ItemDetail(summary: fakeSeason);
    }
    final summary = ref.kind == ItemKind.episode
        ? fakeEpisode(int.parse(ref.externalId.substring(1)))
        : fakeMovie(int.parse(ref.externalId.substring(1)), progress: 120);
    return ItemDetail(
      summary: summary,
      overview: 'Invented overview.',
      genres: const ['Drama'],
      versions: const [
        MediaVersion(id: 'part-1', container: 'mkv', height: 1080)
      ],
    );
  }

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async =>
      switch (parent.kind) {
        ItemKind.show => const Page(items: [fakeSeason]),
        ItemKind.season => Page(items: [fakeEpisode(1), fakeEpisode(2)]),
        _ => const Page(items: []),
      };

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async =>
      ArtworkRequest(
        url: 'https://fake.test${art.path}?w=$width',
        headers: const {'X-Plex-Token': 'tok'},
        cacheKey: '$fakeSourceId|${art.path}|$width',
      );

  @override
  Future<void> setWatched(ItemRef ref, bool watched) async =>
      watchedCalls.add((ref, watched));

  @override
  Future<List<ItemSummary>> search(String query) async => [
        for (var n = 1; n <= movieCount; n++)
          if (fakeMovie(n).title.toLowerCase().contains(query.toLowerCase()))
            fakeMovie(n),
      ];

  @override
  void dispose() => _status.dispose();
}

const fakeResumingEpisode = ItemSummary(
  ref:
      ItemRef(sourceId: fakeSourceId, kind: ItemKind.episode, externalId: 'e2'),
  title: 'Invented Episode 2',
  subtitle: 'S1 · E2',
  showTitle: 'Invented Series',
  index: 2,
  parentIndex: 1,
  durationSeconds: 1800,
  userState: UserState(progressSeconds: 600),
);

/// A source with Continue Watching. Removing drops the item from
/// [resuming], as the server would.
class FakeResumingSource extends FakeMediaSource implements ContinueWatching {
  FakeResumingSource({List<ItemSummary>? resuming})
      : resuming =
            resuming ?? [fakeResumingEpisode, fakeMovie(3, progress: 1200)];

  List<ItemSummary> resuming;
  SourceException? continueError;
  SourceException? removeError;
  int continueCalls = 0;
  final removed = <ItemRef>[];

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.continueWatching};

  @override
  Future<List<ItemSummary>> continueWatching() async {
    continueCalls++;
    if (continueError case final e?) throw e;
    return resuming;
  }

  @override
  Future<void> removeFromContinueWatching(ItemRef ref) async {
    if (removeError case final e?) throw e;
    removed.add(ref);
    resuming = [
      for (final item in resuming)
        if (item.ref != ref) item,
    ];
  }
}

/// A source with Continue Watching and server hubs, as Plex has.
class FakeHubSource extends FakeResumingSource implements HomeHubs {
  FakeHubSource({super.resuming});

  SourceException? hubsError;

  /// Replaces the default two hubs when set.
  List<Hub>? hubList;

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.hubs};

  @override
  Future<List<Hub>> hubs() async {
    if (hubsError case final e?) throw e;
    if (hubList case final list?) return list;
    return [
      Hub(
        id: 'home.movies.recent',
        title: 'Recently Added in Films',
        items: [fakeMovie(5), fakeMovie(6)],
        library: FakeMediaSource.movies,
      ),
      Hub(
        id: 'home.mixed.released',
        title: 'Recently Released',
        items: [fakeMovie(7), fakeShow],
      ),
    ];
  }
}
