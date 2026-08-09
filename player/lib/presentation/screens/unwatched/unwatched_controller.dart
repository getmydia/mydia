import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/recently_added_item.dart';
import '../library/library_sort.dart';

part 'unwatched_controller.g.dart';

const String unwatchedQuery = r'''
query Unwatched($first: Int, $sort: SortInput) {
  unwatched(first: $first, sort: $sort) {
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
class UnwatchedController extends _$UnwatchedController {
  late QueryWatcher<List<RecentlyAddedItem>> _watcher;

  @override
  Stream<List<RecentlyAddedItem>> build() {
    _watcher = createWatcher<List<RecentlyAddedItem>>(
      ref,
      key: QueryKeys.unwatched,
      document: gql(unwatchedQuery),
      variables: {
        'first': 50,
        'sort': LibrarySort.defaultSort.toVariables(),
      },
      parse: (data) => _parseItems(data, 'unwatched'),
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
