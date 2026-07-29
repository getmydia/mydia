import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/recently_added_item.dart';

part 'favorites_controller.g.dart';

const String favoritesQuery = r'''
query Favorites($first: Int) {
  favorites(first: $first) {
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
class FavoritesController extends _$FavoritesController {
  late QueryWatcher<List<RecentlyAddedItem>> _watcher;

  @override
  Stream<List<RecentlyAddedItem>> build() {
    _watcher = createWatcher<List<RecentlyAddedItem>>(
      ref,
      key: QueryKeys.favorites,
      document: gql(favoritesQuery),
      variables: const {'first': 50},
      parse: (data) => _parseItems(data, 'favorites'),
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
