import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/collection.dart';

part 'collections_controller.g.dart';

const String collectionsQuery = r'''
query Collections($first: Int) {
  collections(first: $first) {
    id
    name
    description
    type
    visibility
    itemCount
    posterPaths
  }
}
''';

List<Collection> _parseCollections(Map<String, dynamic> data) {
  return (data['collections'] as List<dynamic>?)
          ?.map((e) => Collection.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [];
}

@riverpod
class CollectionsController extends _$CollectionsController {
  late QueryWatcher<List<Collection>> _watcher;

  @override
  Stream<List<Collection>> build() {
    _watcher = createWatcher<List<Collection>>(
      ref,
      key: QueryKeys.collections,
      document: gql(collectionsQuery),
      variables: const {'first': 50},
      parse: _parseCollections,
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
