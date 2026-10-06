import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/domain/models/media_stream.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/sources/collection.dart';
import 'package:player/domain/sources/hub.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import 'fake_media_source.dart';

/// A source with every read capability of a Mydia instance. Each method
/// answers a public field and appends its name and arguments to [calls], so
/// a test sets what the server says and asserts what was asked.
class FakeCapableSource extends FakeMediaSource
    implements
        Collections,
        Calendar,
        SavedFilters,
        UnwatchedListing,
        FavoritesListing,
        MediaInfo,
        HomeHubs,
        RecentlyAdded {
  FakeCapableSource({super.id});

  /// `method(arg, ...)` for every capability call, in order.
  final calls = <String>[];

  List<SourceCollection> collectionsResult = const [];

  /// Indexed by page: page 0 answers a null cursor, page n the cursor `n`.
  /// A page that is not the last carries `Cursor('<n + 1>')`.
  List<Page<ItemSummary>> collectionItemPages = const [Page(items: [])];
  List<ItemSummary> calendarResult = const [];
  SavedFilterQuery? filterQueryResult;
  List<Page<ItemSummary>> unwatchedPages = const [Page(items: [])];
  List<Page<ItemSummary>> favoritePages = const [Page(items: [])];
  List<MediaFileInfo> mediaInfoResult = const [];
  List<Hub> hubsResult = const [];
  List<ItemSummary> recentlyAddedResult = const [];

  @override
  Set<SourceCapability> get capabilities => {
        ...super.capabilities,
        SourceCapability.collections,
        SourceCapability.calendar,
        SourceCapability.savedFilters,
        SourceCapability.unwatchedListing,
        SourceCapability.favoritesListing,
        SourceCapability.mediaInfo,
        SourceCapability.hubs,
        SourceCapability.recentlyAdded,
      };

  Page<ItemSummary> _page(List<Page<ItemSummary>> pages, Cursor? cursor) {
    final index = int.tryParse(cursor?.value ?? '') ?? 0;
    return pages[index];
  }

  @override
  Future<List<SourceCollection>> collections() async {
    calls.add('collections()');
    return collectionsResult;
  }

  @override
  Future<Page<ItemSummary>> collectionItems(
    String collectionId, {
    Cursor? cursor,
  }) async {
    calls.add('collectionItems($collectionId, ${cursor?.value})');
    return _page(collectionItemPages, cursor);
  }

  @override
  Future<List<ItemSummary>> calendar(DateTime start, DateTime end) async {
    calls.add('calendar($start, $end)');
    return calendarResult;
  }

  @override
  SavedFilterQuery? filterQuery(MediaFilter filter) {
    calls.add('filterQuery($filter)');
    return filterQueryResult;
  }

  @override
  Future<Page<ItemSummary>> unwatched({Cursor? cursor}) async {
    calls.add('unwatched(${cursor?.value})');
    return _page(unwatchedPages, cursor);
  }

  @override
  Future<Page<ItemSummary>> favorites({Cursor? cursor}) async {
    calls.add('favorites(${cursor?.value})');
    return _page(favoritePages, cursor);
  }

  @override
  Future<List<MediaFileInfo>> mediaInfo(ItemRef ref) async {
    calls.add('mediaInfo(${ref.externalId})');
    return mediaInfoResult;
  }

  @override
  Future<List<Hub>> hubs() async {
    calls.add('hubs()');
    return hubsResult;
  }

  @override
  Future<List<ItemSummary>> recentlyAdded() async {
    calls.add('recentlyAdded()');
    return recentlyAddedResult;
  }
}
