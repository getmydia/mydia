import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// `gql` is a transitive dependency reached through graphql_flutter (via
// graphql -> gql_exec/gql_link). It is not exported by graphql_flutter, so
// OperationDefinitionNode needs a direct import; the same pattern is already
// used throughout core/graphql/watch/*.dart.
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart' show OperationDefinitionNode;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/presentation/screens/show/show_detail_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

/// The operation's name, read off the request's own document.
///
/// `Operation.operationName` is a caller-supplied field that nothing in this
/// codebase ever sets, so it is always null in practice. Every generated
/// document carries exactly one `OperationDefinitionNode` with the
/// operation's real name, which is what the stub link below dispatches on.
String? _operationName(Request request) {
  final operations = request.operation.document.definitions
      .whereType<OperationDefinitionNode>();
  return operations.isEmpty ? null : operations.first.name?.value;
}

Map<String, dynamic> _show({required bool isFavorite}) => {
      '__typename': 'Query',
      'tvShow': {
        '__typename': 'TvShow',
        'id': 's1',
        'title': 'Show One',
        'originalTitle': null,
        'year': 2026,
        'overview': null,
        'status': null,
        'genres': <String>[],
        'contentRating': null,
        'rating': null,
        'tmdbId': null,
        'imdbId': null,
        'category': null,
        'monitored': true,
        'addedAt': null,
        'seasonCount': 1,
        'episodeCount': 1,
        'artwork': {
          '__typename': 'Artwork',
          'posterUrl': null,
          'backdropUrl': null,
          'thumbnailUrl': null,
        },
        'seasons': <dynamic>[],
        'nextEpisode': null,
        'isFavorite': isFavorite,
      },
    };

void main() {
  test('toggling a favorite makes dormant home and favorites cold', () async {
    final log = InMemoryFetchLog({
      QueryKeys.home: DateTime.now(),
      QueryKeys.favorites: DateTime.now(),
      QueryKeys.tvShowsList: DateTime.now(),
    });

    final container = ProviderContainer(
      overrides: [
        fetchLogProvider.overrideWithValue(log),
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(StubLink((request, _) {
            // `Operation.operationName` is a caller-supplied field that
            // nothing in this codebase sets, so it is always null. Read the
            // real name off the request's own document instead, with the
            // `_operationName` helper from
            // season_episodes_controller_test.dart.
            if (_operationName(request) == 'ToggleShowFavorite') {
              return {
                '__typename': 'Mutation',
                'toggleShowFavorite': {
                  '__typename': 'TvShow',
                  'id': 's1',
                  'isFavorite': true,
                },
              };
            }
            return _show(isFavorite: false);
          })),
        ),
      ],
    );
    addTearDown(container.dispose);

    final provider = showDetailControllerProvider('s1');
    await waitForValue(container, provider, (value) => value.id == 's1');

    await container.read(provider.notifier).toggleFavorite();

    // No watcher is alive for these keys in this test, so the dormant branch
    // applies: their fetch-log entries are cleared and the next mount is cold.
    expect(log.lastFetchedAt(QueryKeys.home), isNull);
    expect(log.lastFetchedAt(QueryKeys.favorites), isNull);
    expect(log.lastFetchedAt(QueryKeys.tvShowsList), isNull);
  });
}
