import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/presentation/screens/filter/filter_screen.dart';
import 'package:player/presentation/screens/library/library_sort.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

const _animeFilter = FilterDestination(
  id: 'f_anime',
  label: 'Anime Movies',
  filter: MediaFilter(
    kind: MediaKind.movies,
    category: MediaCategoryFilter.animeMovie,
    watch: WatchScope.all,
    sort: LibrarySort.defaultSort,
  ),
);

Map<String, dynamic> _moviesPage(List<String> ids) => {
      '__typename': 'Query',
      'movies': {
        '__typename': 'MovieConnection',
        'edges': [
          for (final id in ids)
            {
              '__typename': 'MovieEdge',
              'cursor': 'c-$id',
              'node': {
                '__typename': 'Movie',
                'id': id,
                'title': 'Movie $id',
                'year': 2026,
                'overview': null,
                'runtime': null,
                'genres': <String>[],
                'contentRating': null,
                'rating': null,
                'artwork': {
                  '__typename': 'Artwork',
                  'posterUrl': null,
                  'backdropUrl': null,
                  'thumbnailUrl': null,
                },
                'progress': null,
                'isFavorite': false,
              },
            }
        ],
        'pageInfo': {
          '__typename': 'PageInfo',
          'hasNextPage': false,
          'hasPreviousPage': false,
          'startCursor': 'c-${ids.first}',
          'endCursor': 'c-${ids.last}',
        },
        'totalCount': ids.length,
      },
    };

Future<void> pumpFilterScreen(
  WidgetTester tester, {
  required String filterId,
  required StubLink link,
  SidebarLayout? layout,
  GoRouter? router,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final store = InMemorySidebarLayoutStore();
  await store.save(layout ?? SidebarLayout.defaults.withFilter(_animeFilter));

  final child = router == null
      ? MaterialApp(home: FilterScreen(filterId: filterId))
      : MaterialApp.router(routerConfig: router);

  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          asyncGraphqlClientProvider.overrideWith(
            (ref) async => stubClient(link),
          ),
          sidebarLayoutStoreProvider.overrideWithValue(store),
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
        ],
        child: child,
      ),
    );
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('renders the filter label as the title', (tester) async {
    await pumpFilterScreen(
      tester,
      filterId: 'f_anime',
      link: StubLink.responses([
        _moviesPage(['1'])
      ]),
    );

    expect(find.text('Anime Movies'), findsOneWidget);
  });

  testWidgets('renders items returned for the filter', (tester) async {
    await pumpFilterScreen(
      tester,
      filterId: 'f_anime',
      link: StubLink.responses([
        _moviesPage(['42'])
      ]),
    );

    expect(find.text('Movie 42'), findsOneWidget);
    expect(find.byType(MediaPoster), findsOneWidget);
  });

  testWidgets('shows a not-found state for an unknown filter id',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/filter/missing',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Text('home destination')),
        ),
        GoRoute(
          path: '/filter/:id',
          builder: (context, state) =>
              FilterScreen(filterId: state.pathParameters['id']!),
        ),
      ],
    );

    await pumpFilterScreen(
      tester,
      filterId: 'missing',
      link: StubLink.responses([
        _moviesPage(['1'])
      ]),
      layout: SidebarLayout.defaults,
      router: router,
    );

    expect(find.text('This filter no longer exists.'), findsOneWidget);
    expect(find.text('Go home'), findsOneWidget);

    await tester.tap(find.text('Go home'));
    await tester.pumpAndSettle();

    expect(find.text('home destination'), findsOneWidget);
  });
}
