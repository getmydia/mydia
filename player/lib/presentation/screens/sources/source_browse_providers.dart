/// Per-screen state for the generic source screens, keyed by source. Screens
/// invalidate through `invalidateSourceItemWrites` after a write. Each leaf
/// provider is a `SourceWatcher`, so it paints from the cache and is refreshed
/// by `SourceRules`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/watcher_registry.dart';
import '../../../core/sources/cache/create_source_watcher.dart';
import '../../../core/sources/cache/source_codecs.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/cache/source_rules.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/models/media_stream.dart';
import '../../../domain/sources/collection.dart';
import '../../../domain/sources/hub.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../calendar/calendar_window.dart';

/// The live source for [id], or a not-found error when it is gone.
MediaSource requireSource(Ref ref, SourceId id) =>
    ref.watch(mediaSourceProvider(id)) ??
    (throw const SourceException.notFound());

final sourceLibrariesProvider =
    StreamProvider.autoDispose.family<List<Library>, SourceId>((ref, id) {
  final source = requireSource(ref, id);
  return createSourceWatcher(
    ref,
    key: SourceKeys.libraries(id),
    fetch: source.libraries,
    encode: encodeLibraries,
    decode: decodeLibraries,
  ).stream;
});

/// The home row for [library]: its "Recently added" sort when it has one.
final sourceLibraryPreviewProvider = StreamProvider.autoDispose
    .family<List<ItemSummary>, LibraryRef>((ref, library) async* {
  final source = requireSource(ref, library.sourceId);
  // selectAsync: a fresh libraries answer with the same sort must not
  // rebuild this row and fetch it twice.
  final sortId = await ref.watch(
    sourceLibrariesProvider(library.sourceId).selectAsync(
      (libraries) => libraries
          .where((l) => l.ref == library)
          .firstOrNull
          ?.sortOptions
          .where((o) => o.label == 'Recently added')
          .firstOrNull
          ?.id,
    ),
  );
  if (!ref.mounted) return;
  final query = BrowseQuery(sortId: sortId, pageSize: 20);
  yield* createSourceWatcher(
    ref,
    key: SourceKeys.browse(library, query),
    fetch: () => source.browse(library, query),
    encode: encodeSummaryPage,
    decode: decodeSummaryPage,
  ).stream.map((page) => page.items);
});

final sourceItemProvider =
    StreamProvider.autoDispose.family<ItemDetail, ItemRef>((ref, item) {
  final source = requireSource(ref, item.sourceId);
  return createSourceWatcher(
    ref,
    key: SourceKeys.item(item),
    fetch: () => source.item(item),
    encode: encodeDetail,
    decode: decodeDetail,
  ).stream;
});

/// Every child of [parent], following pages up to a sane cap.
final sourceChildrenProvider = StreamProvider.autoDispose
    .family<List<ItemSummary>, ItemRef>((ref, parent) {
  final source = requireSource(ref, parent.sourceId);
  return createSourceWatcher(
    ref,
    key: SourceKeys.children(parent),
    fetch: () => _allChildren(source, parent),
    encode: encodeSummaries,
    decode: decodeSummaries,
  ).stream;
});

Future<List<ItemSummary>> _allChildren(
    MediaSource source, ItemRef parent) async {
  final items = <ItemSummary>[];
  Cursor? cursor;
  for (var pages = 0; pages < 10; pages++) {
    final page = await source.children(parent, cursor: cursor);
    items.addAll(page.items);
    cursor = page.nextCursor;
    if (cursor == null) break;
  }
  return items;
}

/// Empty for a source without the capability. No automatic retry: a failed
/// row stays hidden until the next refresh rather than polling a down
/// server.
final sourceContinueWatchingProvider =
    StreamProvider.autoDispose.family<List<ItemSummary>, SourceId>(
  (ref, id) {
    final continueWatching = requireSource(ref, id).as<ContinueWatching>();
    if (continueWatching == null) return Stream.value(const []);
    return createSourceWatcher(
      ref,
      key: SourceKeys.continueWatching(id),
      fetch: continueWatching.continueWatching,
      encode: encodeSummaries,
      decode: decodeSummaries,
    ).stream;
  },
  retry: (_, __) => null,
);

/// Empty for a source without collections. Same retry rule as Continue
/// Watching.
final sourceCollectionsProvider =
    StreamProvider.autoDispose.family<List<SourceCollection>, SourceId>(
  (ref, id) {
    final collections = requireSource(ref, id).as<Collections>();
    if (collections == null) return Stream.value(const []);
    return createSourceWatcher(
      ref,
      key: SourceKeys.collections(id),
      fetch: collections.collections,
      encode: encodeCollections,
      decode: decodeCollections,
    ).stream;
  },
  retry: (_, __) => null,
);

/// The calendar over `calendarWindow` of today, empty for a source without
/// one.
final sourceCalendarProvider =
    StreamProvider.autoDispose.family<List<ItemSummary>, SourceId>(
  (ref, id) {
    final calendar = requireSource(ref, id).as<Calendar>();
    if (calendar == null) return Stream.value(const []);
    final window = calendarWindow(DateTime.now());
    return createSourceWatcher(
      ref,
      key: SourceKeys.calendar(id, window.start, window.end),
      fetch: () => calendar.calendar(window.start, window.end),
      encode: encodeSummaries,
      decode: decodeSummaries,
    ).stream;
  },
  retry: (_, __) => null,
);

/// Empty for a source without the capability.
final sourceRecentlyAddedProvider =
    StreamProvider.autoDispose.family<List<ItemSummary>, SourceId>(
  (ref, id) {
    final recentlyAdded = requireSource(ref, id).as<RecentlyAdded>();
    if (recentlyAdded == null) return Stream.value(const []);
    return createSourceWatcher(
      ref,
      key: SourceKeys.recentlyAdded(id),
      fetch: recentlyAdded.recentlyAdded,
      encode: encodeSummaries,
      decode: decodeSummaries,
    ).stream;
  },
  retry: (_, __) => null,
);

/// The files of [item] for the Media Info panel. Not cached: it is read on
/// demand, and a source without the capability is an error the panel shows.
final sourceMediaInfoProvider =
    FutureProvider.autoDispose.family<List<MediaFileInfo>, ItemRef>(
  (ref, item) {
    final info = requireSource(ref, item.sourceId).as<MediaInfo>();
    if (info == null) throw const SourceException.unsupported();
    return info.mediaInfo(item);
  },
  retry: (_, __) => null,
);

/// Null for a source without hubs, whose home keeps one row per library.
final sourceHubsProvider =
    StreamProvider.autoDispose.family<List<Hub>?, SourceId>(
  (ref, id) {
    final hubs = requireSource(ref, id).as<HomeHubs>();
    if (hubs == null) return Stream.value(null);
    return createSourceWatcher<List<Hub>?>(
      ref,
      key: SourceKeys.hubs(id),
      fetch: hubs.hubs,
      encode: encodeHubs,
      decode: decodeHubs,
    ).stream;
  },
  retry: (_, __) => null,
);

/// Progress or watched state of [item] changed: every live watcher on its
/// source that shows watch state refetches, the rest mount cold. See
/// `SourceRules.watchedChanged`.
void invalidateSourceItemWrites(WidgetRef ref, ItemRef item) => unawaited(ref
    .read(invalidatorProvider)
    .invalidate(SourceRules.watchedChanged(item.sourceId)));

/// [item] was favorited or unfavorited. See `SourceRules.favoriteChanged`.
void invalidateSourceFavoriteWrites(WidgetRef ref, ItemRef item) =>
    unawaited(ref
        .read(invalidatorProvider)
        .invalidate(SourceRules.favoriteChanged(item.sourceId)));

/// [invalidateSourceItemWrites] through a container, for a write that
/// finishes after its notifier is disposed: a `Ref` throws then, a container
/// does not.
void invalidateSourceContainerWrites(
  ProviderContainer container,
  ItemRef item,
) =>
    unawaited(container
        .read(invalidatorProvider)
        .invalidate(SourceRules.watchedChanged(item.sourceId)));

/// [item] was dismissed from Continue Watching; only the rail and the hubs
/// change.
void invalidateSourceContinueWatchingWrites(WidgetRef ref, ItemRef item) =>
    unawaited(ref
        .read(invalidatorProvider)
        .invalidate(SourceRules.continueWatchingRemoved(item.sourceId)));
