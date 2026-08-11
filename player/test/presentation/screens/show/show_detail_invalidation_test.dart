import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// `gql` is a transitive dependency reached through graphql_flutter (via
// graphql -> gql_exec/gql_link). It is not exported by graphql_flutter, so
// OperationDefinitionNode needs a direct import; the same pattern is already
// used throughout core/graphql/watch/*.dart.
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart' show OperationDefinitionNode;
// `DocumentNode` has no `toString()` override (it prints as `Instance of
// 'DocumentNode'`), so getting the request's query text back out requires
// the AST printer. Same pattern as `lib/core/graphql/p2p_link.dart` and
// `lib/core/downloads/p2p_download_job_service.dart`.
// ignore: depend_on_referenced_packages
import 'package:gql/language.dart' show printNode;
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

/// The shape the server actually returns: one `toggleFavorite` mutation over
/// media item ids, for shows and movies alike. An earlier version of this stub
/// answered a `toggleShowFavorite` field returning a `TvShow`, which the schema
/// has never defined — the reason the real mutation failed on every tap while
/// this test stayed green.
Map<String, dynamic> _toggleFavoriteMutationData() => {
      '__typename': 'Mutation',
      'toggleFavorite': {
        '__typename': 'ToggleFavoriteResult',
        'isFavorite': true,
        'mediaItemId': 's1',
      },
    };

/// A [Link] whose response to the `ToggleFavorite` mutation only arrives
/// once [gate] completes, while every other request (the initial detail
/// query, and any self-refetch it triggers) answers immediately. Used to
/// simulate a user navigating away while a mutation is still in flight.
class _GatedMutationLink extends Link {
  _GatedMutationLink(this.gate);

  final Future<void> gate;
  final List<Request> requests = [];

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    requests.add(request);

    if (_operationName(request) == 'ToggleFavorite') {
      await gate;
      yield Response(
        data: _toggleFavoriteMutationData(),
        response: const <String, dynamic>{},
      );
      return;
    }

    yield Response(
      data: _show(isFavorite: false),
      response: const <String, dynamic>{},
    );
  }
}

void main() {
  test(
      'toggling a favorite makes dormant home and favorites cold, and '
      'converges its own detail on the server value', () async {
    final log = InMemoryFetchLog({
      QueryKeys.home: DateTime.now(),
      QueryKeys.favorites: DateTime.now(),
      QueryKeys.tvShowsList: DateTime.now(),
    });

    // Tracks whether the mutation has landed, so the detail query's response
    // behaves like a real server: pre-mutation it reports `isFavorite:
    // false`, post-mutation it reports `true`. This is what makes the test
    // meaningful — a stub that always answers `false` cannot distinguish "the
    // self-refetch never happened" from "the self-refetch happened and
    // silently reverted the optimistic write with stale data" (the exact
    // failure `favoriteToggled`'s `id:` argument exists to close).
    var favorited = false;

    final container = ProviderContainer(
      overrides: [
        fetchLogProvider.overrideWithValue(log),
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(StubLink((request, _) {
            if (_operationName(request) == 'ToggleFavorite') {
              favorited = true;
              return _toggleFavoriteMutationData();
            }
            return _show(isFavorite: favorited);
          })),
        ),
      ],
    );
    addTearDown(container.dispose);

    final provider = showDetailControllerProvider('s1');

    // A persistent listener, held open for the rest of the test: this
    // controller is auto-dispose, and `waitForValue` below closes its own
    // subscription as soon as its predicate is satisfied. Without something
    // else keeping a listener attached, the provider is eligible for
    // disposal the moment that subscription closes, and a later
    // `container.read(provider)` would silently rebuild it from scratch
    // (fresh `AsyncLoading`, `.value == null`) instead of reflecting the
    // state actually produced by the refetch this test means to observe.
    final subscription = container.listen<AsyncValue<dynamic>>(
      provider,
      (previous, next) {},
    );
    addTearDown(subscription.close);

    await waitForValue(container, provider, (value) => value.id == 's1');

    await container.read(provider.notifier).toggleFavorite();

    // No watcher is alive for these keys in this test, so the dormant branch
    // applies: their fetch-log entries are cleared and the next mount is cold.
    expect(log.lastFetchedAt(QueryKeys.home), isNull);
    expect(log.lastFetchedAt(QueryKeys.favorites), isNull);
    expect(log.lastFetchedAt(QueryKeys.tvShowsList), isNull);

    // `showDetail('s1')` is this very controller's own watcher, so it is
    // live and takes the refetch branch instead. Its refetch push arrives
    // via a normal Dart stream subscription, one microtask hop after
    // `ObservableQuery.refetch()`'s awaited future resolves — the same gap
    // `invalidation_test.dart`'s "a live watcher is refetched" case settles
    // with a short delay.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(provider).value?.isFavorite, isTrue);
  });

  test(
      'invalidation survives the controller being disposed while the '
      'mutation is still in flight', () async {
    final log = InMemoryFetchLog({
      QueryKeys.home: DateTime.now(),
      QueryKeys.favorites: DateTime.now(),
      QueryKeys.tvShowsList: DateTime.now(),
    });

    final gate = Completer<void>();
    final link = _GatedMutationLink(gate.future);

    final container = ProviderContainer(
      overrides: [
        fetchLogProvider.overrideWithValue(log),
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(link),
        ),
      ],
    );

    final provider = showDetailControllerProvider('s1');
    await waitForValue(container, provider, (value) => value.id == 's1');

    // Start the toggle, but its mutation response is gated behind `gate` and
    // won't arrive until it completes below.
    final toggleFuture = container.read(provider.notifier).toggleFavorite();

    // Simulate the user navigating away before the server responds:
    // `ShowDetailController` is auto-dispose, so this tears down its `ref`.
    container.dispose();

    // Let the mutation's network response land, now that the controller is
    // gone.
    gate.complete();
    await toggleFuture;

    // The invalidation must still have run: the `Invalidator` captured at
    // the top of `toggleFavorite()`, before the optimistic update, does not
    // depend on `ref` and so is unaffected by the controller's disposal.
    // Before that capture was hoisted, this `ref.read(invalidatorProvider)`
    // ran after the awaited mutation and would throw
    // `UnmountedRefException` here, silently dropping the invalidation into
    // the revert-on-error catch block.
    expect(log.lastFetchedAt(QueryKeys.home), isNull);
    expect(log.lastFetchedAt(QueryKeys.favorites), isNull);
    expect(log.lastFetchedAt(QueryKeys.tvShowsList), isNull);
  });

  group('ShowDetailController new hero fields', () {
    test('requests cast, trailerUrl, and similar', () async {
      final link = StubLink((request, _) => _show(isFavorite: false));

      final container = ProviderContainer(
        overrides: [
          asyncGraphqlClientProvider.overrideWith(
            (ref) async => stubClient(link),
          ),
        ],
      );
      addTearDown(container.dispose);

      final provider = showDetailControllerProvider('s1');
      await waitForValue(container, provider, (v) => v.id == 's1');

      final queryText = printNode(link.requests.first.operation.document);
      expect(queryText, contains('cast'));
      expect(queryText, contains('trailerUrl'));
      expect(queryText, contains('similar'));
    });
  });
}
