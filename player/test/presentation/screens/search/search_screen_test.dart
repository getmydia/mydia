import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/search_result.dart';
import 'package:player/presentation/screens/search/search_controller.dart';
import 'package:player/presentation/screens/search/search_screen.dart';
import 'package:player/presentation/screens/search/widgets/episode_result_row.dart';
import 'package:player/presentation/screens/search/widgets/search_result_card.dart';
import 'package:player/presentation/screens/search/widgets/search_section_header.dart';

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

  testWidgets('renders four filter chips', (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
    });

    for (final label in ['Movies', 'TV Shows', 'Episodes', 'Collections']) {
      expect(find.text(label), findsOneWidget);
    }
  });
}
