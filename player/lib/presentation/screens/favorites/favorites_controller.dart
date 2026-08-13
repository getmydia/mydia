import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/recently_added_item.dart';
import '../library/library_sort.dart';

part 'favorites_controller.g.dart';

const String favoritesQuery = r'''
query Favorites($first: Int, $sort: SortInput) {
  favorites(first: $first, sort: $sort) {
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
    watchStatus { watched percentage unwatchedEpisodeCount }
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
class FavoritesController extends _$FavoritesController {
  late QueryWatcher<List<RecentlyAddedItem>> _watcher;

  @override
  Stream<List<RecentlyAddedItem>> build() {
    _watcher = createWatcher<List<RecentlyAddedItem>>(
      ref,
      key: QueryKeys.favorites,
      document: gql(favoritesQuery),
      variables: {
        'first': 50,
        'sort': LibrarySort.defaultSort.toVariables(),
      },
      parse: (data) => _parseItems(data, 'favorites'),
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
