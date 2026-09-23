import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

/// A read-only view of the persisted GraphQL cache for [QueryWatcher]'s
/// early emit. Same Hive box every client reads (`GraphQLCache(store:
/// HiveStore())` in `client.dart`), so it holds exactly what the client
/// would answer from cache. Null when the box could not be opened at startup.
final earlyGraphqlCacheProvider = Provider<GraphQLCache?>((ref) {
  try {
    return GraphQLCache(store: HiveStore());
  } catch (e) {
    debugPrint('[earlyGraphqlCache] Hive cache unavailable: $e');
    return null;
  }
});
