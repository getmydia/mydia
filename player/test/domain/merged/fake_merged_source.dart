import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

Source fakeServer(String accountId, {SourceKind kind = SourceKind.plex}) =>
    Source(
      account: ProviderAccount(
        id: accountId,
        kind: kind,
        displayName: 'Server $accountId',
        storageNamespace: 'source/$accountId',
        activeProfileId: 'owner',
      ),
      profile: SourceProfile(
          id: 'owner', accountId: accountId, name: 'Owner', isOwner: true),
      server: SourceServer(
          id: 's1',
          accountId: accountId,
          profileId: 'owner',
          name: 'Server $accountId'),
    );

ItemSummary item(Source s, String id,
        {ItemKind kind = ItemKind.movie,
        String? title,
        String? sortTitle,
        DateTime? addedAt,
        DateTime? lastPlayedAt,
        String? airDate}) =>
    ItemSummary(
      ref: ItemRef(sourceId: s.id, kind: kind, externalId: id),
      title: title ?? 'Invented $id',
      sortTitle: sortTitle,
      addedAt: addedAt,
      lastPlayedAt: lastPlayedAt,
      airDate: airDate,
    );

/// One movie library (and optionally a show library) served from a sorted
/// list, plus the optional row capabilities.
class FakeMergedSource extends MediaSource
    implements ContinueWatching, RecentlyAdded, Searchable {
  FakeMergedSource(
    this.source, {
    this.movies = const [],
    this.shows = const [],
    this.sorts = const [
      SortOption(id: 'title', label: 'Title', shared: SharedSort.title),
      SortOption(
          id: 'added',
          label: 'Added',
          descendingByDefault: true,
          shared: SharedSort.added),
    ],
    this.resuming = const [],
    this.recent = const [],
    this.found = const [],
    this.caps = const {
      SourceCapability.continueWatching,
      SourceCapability.recentlyAdded,
      SourceCapability.searchable,
    },
  });

  @override
  final Source source;

  /// Already in the order the requested sort would return.
  final List<ItemSummary> movies;
  final List<ItemSummary> shows;
  final List<SortOption> sorts;
  final List<ItemSummary> resuming;
  final List<ItemSummary> recent;
  final List<ItemSummary> found;
  final Set<SourceCapability> caps;

  /// Fails every call when set; `failAfterPages` fails browse from that page.
  SourceException? failWith;
  int? failAfterPages;

  /// Browse answers this many empty pages (with a cursor) before real ones.
  int emptyLeadingPages = 0;

  /// Browse always answers an empty page echoing the cursor it was given.
  bool stuckEmpty = false;

  /// Completes calls only when set to a completed future.
  Completer<void>? gate;
  final browseCalls = <BrowseQuery>[];

  Future<void> _wait() async {
    final g = gate;
    if (g != null) await g.future;
    final f = failWith;
    if (f != null) throw f;
  }

  @override
  Set<SourceCapability> get capabilities => caps;

  @override
  SourceConnectionStatus get connection => SourceConnectionStatus.local;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable =>
      ValueNotifier(SourceConnectionStatus.local);

  @override
  T? as<T extends Object>() {
    final ok = switch (T) {
      const (ContinueWatching) =>
        caps.contains(SourceCapability.continueWatching),
      const (RecentlyAdded) => caps.contains(SourceCapability.recentlyAdded),
      const (Searchable) => caps.contains(SourceCapability.searchable),
      _ => true,
    };
    return ok && this is T ? this as T : null;
  }

  @override
  Future<List<Library>> libraries() async {
    await _wait();
    return [
      Library(
          ref: LibraryRef(sourceId: id, id: 'movies'),
          title: 'Films',
          kind: LibraryKind.movies,
          sortOptions: sorts),
      if (shows.isNotEmpty)
        Library(
            ref: LibraryRef(sourceId: id, id: 'shows'),
            title: 'Series',
            kind: LibraryKind.shows,
            sortOptions: sorts),
    ];
  }

  @override
  Future<Page<ItemSummary>> browse(LibraryRef library, BrowseQuery query,
      {Cursor? cursor}) async {
    browseCalls.add(query);
    await _wait();
    final start = int.tryParse(cursor?.value ?? '') ?? 0;
    final failFrom = failAfterPages;
    if (failFrom != null && start ~/ query.pageSize >= failFrom) {
      throw const SourceException.unreachable();
    }
    if (stuckEmpty) {
      return Page(items: const [], nextCursor: cursor ?? const Cursor('0'));
    }
    if (browseCalls.length <= emptyLeadingPages) {
      // An empty first page that still points onward (cursor `0`).
      return const Page(items: [], nextCursor: Cursor('0'));
    }
    final all = library.id == 'shows' ? shows : movies;
    final page = all.skip(start).take(query.pageSize).toList();
    final next = start + page.length;
    return Page(
        items: page,
        total: all.length,
        nextCursor: next < all.length ? Cursor('$next') : null);
  }

  @override
  Future<List<ItemSummary>> continueWatching() async {
    await _wait();
    return resuming;
  }

  @override
  bool canRemoveFromContinueWatching(ItemSummary item) => true;

  @override
  Future<void> removeFromContinueWatching(ItemRef ref) async {}

  @override
  Future<List<ItemSummary>> recentlyAdded() async {
    await _wait();
    return recent;
  }

  @override
  Future<List<ItemSummary>> search(String query) async {
    await _wait();
    return found;
  }

  @override
  Future<ItemDetail> item(ItemRef ref) => throw UnimplementedError();

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async =>
      const Page(items: []);

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async =>
      null;

  @override
  void dispose() {}
}
