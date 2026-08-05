import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/recently_added_item.dart';

part 'recently_added_controller.g.dart';

const String recentlyAddedFullQuery = r'''
query RecentlyAddedFull($first: Int) {
  recentlyAdded(first: $first) {
    id
    type
    title
    year
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    addedAt
    newEpisodeCount
    latestSeasonNumber
    latestEpisodeNumber
  }
}
''';

/// The pre-episode-context shape, for a server older than this build.
const String recentlyAddedFullQueryLegacy = r'''
query RecentlyAddedFull($first: Int) {
  recentlyAdded(first: $first) {
    id
    type
    title
    year
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    addedAt
  }
}
''';

List<RecentlyAddedItem> _parseItems(Map<String, dynamic> data, String field) {
  return (data[field] as List<dynamic>?)
          ?.map((e) => RecentlyAddedItem.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [];
}

@riverpod
class RecentlyAddedController extends _$RecentlyAddedController {
  late QueryWatcher<List<RecentlyAddedItem>> _watcher;

  @override
  Stream<List<RecentlyAddedItem>> build() {
    _watcher = createWatcher<List<RecentlyAddedItem>>(
      ref,
      key: QueryKeys.recentlyAdded,
      document: gql(recentlyAddedFullQuery),
      fallbackDocument: gql(recentlyAddedFullQueryLegacy),
      variables: const {'first': 50},
      parse: (data) => _parseItems(data, 'recentlyAdded'),
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
