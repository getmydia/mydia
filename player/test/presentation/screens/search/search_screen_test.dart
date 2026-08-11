import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/search_result.dart';
import 'package:player/presentation/screens/search/search_controller.dart';
import 'package:player/presentation/screens/search/search_screen.dart';
import 'package:player/presentation/screens/search/widgets/episode_result_row.dart';
import 'package:player/presentation/screens/search/widgets/search_result_card.dart';
import 'package:player/presentation/screens/search/widgets/search_section_header.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';
import 'package:player/presentation/widgets/browse_scaffold.dart';

import '../../../test_utils/mock_network_images.dart';
import 'search_screen_test.mocks.dart';

@GenerateNiceMocks([MockSpec<GraphQLClient>()])
const _twoSections = {
  'totalCount': 2,
  'sections': [
    {
      'type': 'MOVIE',
      'totalCount': 12,
      'results': [
        {'id': 'm1', 'type': 'MOVIE', 'title': 'Alien', 'year': 1979},
      ],
    },
    {
      'type': 'EPISODE',
      'totalCount': 31,
      'results': [
        {
          'id': 'e1',
          'type': 'EPISODE',
          'title': 'Fountain of Youth',
          'subtitle': 'Alien Nation',
          'seasonNumber': 1,
          'episodeNumber': 3,
          'parentId': 'show-1',
        },
      ],
    },
  ],
};

void main() {
  late MockGraphQLClient client;

  Widget host({String? initialQuery, SearchResultType? initialType}) {
    client = MockGraphQLClient();
    when(client.query(any)).thenAnswer(
      (_) async => QueryResult(
        options: QueryOptions(document: gql('query { x }')),
        source: QueryResultSource.network,
        data: const {'search': _twoSections},
      ),
    );

    return ProviderScope(
      overrides: [
        asyncGraphqlClientProvider.overrideWith((ref) async => client),
        castCapabilitiesProvider.overrideWithValue(
          const CastCapabilities.full(),
        ),
      ],
      child: MaterialApp(
        home: SearchScreen(
          initialQuery: initialQuery,
          initialType: initialType,
        ),
      ),
    );
  }

  // The filter chips carry the same labels as the section headers, so header
  // assertions must be scoped to SearchSectionHeader.
  Finder headerText(String label) => find.descendant(
        of: find.byType(SearchSectionHeader),
        matching: find.text(label),
      );

  testWidgets('renders one header per non-empty section', (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(host(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    expect(find.byType(SearchSectionHeader), findsNWidgets(2));
    expect(headerText('Movies'), findsOneWidget);
    expect(headerText('Episodes'), findsOneWidget);
    expect(headerText('TV Shows'), findsNothing);
    expect(headerText('Collections'), findsNothing);
  });

  testWidgets('shows the honest section totals, not the page length',
      (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(host(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    expect(headerText('12'), findsOneWidget);
    expect(headerText('31'), findsOneWidget);
  });

  testWidgets('renders posters for movies and rows for episodes',
      (tester) async {
    // The default 800x600 test surface is too short to keep the episode
    // section onstage below the movie section's tall poster grid, and
    // Sliver-lazy children that are scrolled past the fold aren't findable
    // by widget tests. Widen the surface so both sections paint without a
    // manual scroll.
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await mockNetworkImages(() async {
      await tester.pumpWidget(host(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    expect(find.byType(SearchResultCard), findsOneWidget);
    expect(find.byType(EpisodeResultRow), findsOneWidget);
  });

  testWidgets('the q parameter seeds the text field and runs the search',
      (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(host(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    expect(find.widgetWithText(TextField, 'alien'), findsOneWidget);
    verify(client.query(any)).called(1);
  });

  testWidgets('the type parameter pre-applies a section filter',
      (tester) async {
    late ProviderContainer container;

    await mockNetworkImages(() async {
      await tester.pumpWidget(
        host(initialQuery: 'alien', initialType: SearchResultType.episode),
      );
      await tester.pumpAndSettle();
      container = ProviderScope.containerOf(
        tester.element(find.byType(SearchScreen)),
      );
    });

    expect(
      container.read(searchControllerProvider).selectedTypes,
      {SearchResultType.episode},
    );
  });

  testWidgets(
      'a parameter change on an already-mounted screen re-seeds via '
      'didUpdateWidget', (tester) async {
    // Same client across both pumps, unlike host(), so every recorded
    // query() call — from either pump — lands on one mock we can inspect
    // together at the end.
    final sameClient = MockGraphQLClient();
    when(sameClient.query(any)).thenAnswer(
      (_) async => QueryResult(
        options: QueryOptions(document: gql('query { x }')),
        source: QueryResultSource.network,
        data: const {'search': _twoSections},
      ),
    );

    Widget rebuild({String? initialQuery, SearchResultType? initialType}) {
      return ProviderScope(
        overrides: [
          asyncGraphqlClientProvider.overrideWith((ref) async => sameClient),
        ],
        child: MaterialApp(
          home: SearchScreen(
            initialQuery: initialQuery,
            initialType: initialType,
          ),
        ),
      );
    }

    await mockNetworkImages(() async {
      await tester.pumpWidget(rebuild(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    expect(find.widgetWithText(TextField, 'alien'), findsOneWidget);

    // Re-pump the same widget type at the same position (ProviderScope ->
    // MaterialApp -> SearchScreen, no keys anywhere) with different route
    // parameters. Flutter's element diffing updates the existing element in
    // place rather than remounting it, which is exactly what a "Show all"
    // navigation to the same route does, and is what triggers
    // didUpdateWidget instead of a fresh initState.
    await mockNetworkImages(() async {
      await tester.pumpWidget(
        rebuild(
          initialQuery: 'predator',
          initialType: SearchResultType.episode,
        ),
      );
      await tester.pumpAndSettle();
    });

    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.widgetWithText(TextField, 'predator'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchScreen)),
    );
    expect(
      container.read(searchControllerProvider).selectedTypes,
      {SearchResultType.episode},
    );

    final captured =
        verify(sameClient.query(captureAny)).captured.cast<QueryOptions>();
    expect(captured, hasLength(2));
    expect(captured.last.variables['query'], 'predator');
    expect(captured.last.variables['types'], ['EPISODE']);
  });

  testWidgets(
      'navigating to /search with no q resets an already-filtered search',
      (tester) async {
    // Regression test: the sidebar's "Search" nav item always routes to bare
    // `/search`, even while a filtered search is showing. That re-mounts the
    // same route (didUpdateWidget, not initState) with initialQuery/Type both
    // null, and the fix must land on a consistent state rather than only
    // deselecting the filter chips while stale text/results linger.
    final sameClient = MockGraphQLClient();
    when(sameClient.query(any)).thenAnswer(
      (_) async => QueryResult(
        options: QueryOptions(document: gql('query { x }')),
        source: QueryResultSource.network,
        data: const {'search': _twoSections},
      ),
    );

    Widget rebuild({String? initialQuery, SearchResultType? initialType}) {
      return ProviderScope(
        overrides: [
          asyncGraphqlClientProvider.overrideWith((ref) async => sameClient),
        ],
        child: MaterialApp(
          home: SearchScreen(
            initialQuery: initialQuery,
            initialType: initialType,
          ),
        ),
      );
    }

    await mockNetworkImages(() async {
      await tester.pumpWidget(
        rebuild(initialQuery: 'alien', initialType: SearchResultType.movie),
      );
      await tester.pumpAndSettle();
    });

    expect(find.widgetWithText(TextField, 'alien'), findsOneWidget);

    await mockNetworkImages(() async {
      await tester.pumpWidget(rebuild());
      await tester.pumpAndSettle();
    });

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchScreen)),
    );
    final state = container.read(searchControllerProvider);

    expect(find.widgetWithText(TextField, 'alien'), findsNothing);
    expect(state.query, isEmpty);
    expect(state.selectedTypes, isEmpty);
    expect(state.results, isNull);
  });

  testWidgets('renders four filter chips', (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
    });

    for (final label in ['Movies', 'TV Shows', 'Episodes', 'Collections']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets(
      'carries its own cast button in the app bar '
      '(the shell overlay skips this route)', (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
    });

    expect(find.byKey(const Key('cast-button')), findsOneWidget);
  });

  testWidgets('resets the ambient backdrop to the static fallback',
      (tester) async {
    final backdropClient = MockGraphQLClient();
    when(backdropClient.query(any)).thenAnswer(
      (_) async => QueryResult(
        options: QueryOptions(document: gql('query { x }')),
        source: QueryResultSource.network,
        data: const {'search': _twoSections},
      ),
    );

    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith((ref) async => backdropClient),
        castCapabilitiesProvider.overrideWithValue(
          const CastCapabilities.full(),
        ),
      ],
    );
    addTearDown(container.dispose);
    // The shell always watches this provider; keep it alive here so the
    // autoDispose controller isn't scheduled for disposal between the seed
    // below and the final read (see ambient_backdrop_tint_test.dart).
    container.listen(ambientBackdropControllerProvider, (_, __) {});

    // Arrive from a focal screen that left its artwork on the backdrop.
    container.read(ambientBackdropControllerProvider.notifier).setDefault(
          const BackdropSource(
            imageUrl: 'https://example.test/hero.jpg',
            id: 'hero',
          ),
        );

    await mockNetworkImages(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SearchScreen()),
        ),
      );
      // publishBackdropSource defers to a post-frame callback.
      await tester.pump();
    });

    expect(
      container.read(ambientBackdropControllerProvider.notifier).defaultSource,
      BackdropSource.none,
    );
  });

  testWidgets('gives the search field real gutters instead of sitting flush',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await mockNetworkImages(() async {
      await tester.pumpWidget(host(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    final fieldLeft = tester.getTopLeft(find.byType(TextField)).dx;

    // Breakpoints.getHorizontalPadding returns 32 at or above 1200 wide. The
    // old bar used `titleSpacing: 0`, which put the field flush against the
    // leading icon with no margin at all.
    expect(fieldLeft, greaterThanOrEqualTo(32.0));
  });

  testWidgets('does not inherit the theme filled pill', (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(host(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    final field = tester.widget<TextField>(find.byType(TextField));

    // The app theme sets `filled: true` with a rounded fill.
    // `InputBorder.none` suppresses the stroke but not the fill, which is how
    // this field came to render as a pill nobody designed.
    expect(field.decoration?.filled, isFalse);
  });

  testWidgets('shows the screen title in its bar', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await mockNetworkImages(() async {
      await tester.pumpWidget(host(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    // Scoped to the bar: 'Search' would otherwise also match chip and section
    // labels elsewhere on the screen.
    expect(
      find.descendant(
        of: find.byType(BrowseScaffold),
        matching: find.text('Search'),
      ),
      findsWidgets,
    );
  });

  testWidgets('uses the app-wide poster geometry for result cards',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await mockNetworkImages(() async {
      await tester.pumpWidget(host(initialQuery: 'alien'));
      await tester.pumpAndSettle();
    });

    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;

    // Was SliverGridDelegateWithMaxCrossAxisExtent(180) at aspect 0.55,
    // the only grid in the app that did not match the library.
    expect(delegate.childAspectRatio, 0.58);
  });
}
