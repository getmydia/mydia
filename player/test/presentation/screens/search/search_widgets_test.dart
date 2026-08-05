import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/search_result.dart';
import 'package:player/presentation/screens/search/widgets/episode_result_row.dart';
import 'package:player/presentation/screens/search/widgets/search_filter_chip.dart';
import 'package:player/presentation/screens/search/widgets/search_result_card.dart';
import 'package:player/presentation/screens/search/widgets/search_section_header.dart';

import '../../../test_utils/hover_affordance.dart';
import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/poster_contract.dart';

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: Center(child: SizedBox(width: 400, child: child))),
      ),
    );

void main() {
  runPosterDepthContract(
    description: 'SearchResultCard',
    build: () => SearchResultCard(
      result: const SearchResult(
        id: 'm1',
        type: SearchResultType.movie,
        title: 'Alien',
        year: 1979,
      ),
      onTap: () {},
    ),
    size: const Size(180, 320),
  );

  group('SearchSectionHeader', () {
    testWidgets('shows the title and the honest count', (tester) async {
      await tester.pumpWidget(
        _host(const SearchSectionHeader(title: 'Episodes', count: 31)),
      );

      expect(find.text('Episodes'), findsOneWidget);
      expect(find.text('31'), findsOneWidget);
    });

    testWidgets('shows Show all only when a callback is supplied',
        (tester) async {
      await tester.pumpWidget(
        _host(const SearchSectionHeader(title: 'Movies', count: 2)),
      );
      expect(find.text('Show all'), findsNothing);

      var tapped = 0;
      await tester.pumpWidget(
        _host(
          SearchSectionHeader(
            title: 'Movies',
            count: 12,
            onShowAll: () => tapped++,
          ),
        ),
      );

      expect(find.text('Show all'), findsOneWidget);
      await tester.tap(find.text('Show all'));
      expect(tapped, 1);
    });
  });

  group('EpisodeResultRow', () {
    testWidgets('renders show name, episode code, and title', (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(
            EpisodeResultRow(
              result: const SearchResult(
                id: 'ep-1',
                type: SearchResultType.episode,
                title: 'Fountain of Youth',
                subtitle: 'Alien Nation',
                seasonNumber: 1,
                episodeNumber: 3,
                parentId: 'show-1',
              ),
              onTap: () {},
            ),
          ),
        );
      });

      expect(find.textContaining('Alien Nation'), findsOneWidget);
      expect(find.textContaining('S01E03'), findsOneWidget);
      expect(find.text('Fountain of Youth'), findsOneWidget);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      var tapped = 0;

      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(
            EpisodeResultRow(
              result: const SearchResult(
                id: 'ep-1',
                type: SearchResultType.episode,
                title: 'Fountain of Youth',
                subtitle: 'Alien Nation',
                seasonNumber: 1,
                episodeNumber: 3,
              ),
              onTap: () => tapped++,
            ),
          ),
        );
        await tester.tap(find.byType(EpisodeResultRow));
      });

      expect(tapped, 1);
    });
  });

  group('SearchResultCard', () {
    testWidgets('renders the title, year, and type badge', (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(
            SizedBox(
              height: 320,
              child: SearchResultCard(
                result: const SearchResult(
                  id: 'm1',
                  type: SearchResultType.movie,
                  title: 'Alien',
                  year: 1979,
                ),
                onTap: () {},
              ),
            ),
          ),
        );
      });

      expect(find.text('Alien'), findsOneWidget);
      expect(find.text('1979'), findsOneWidget);
      expect(find.text('Movie'), findsOneWidget);
    });

    testWidgets('shows the collection subtitle instead of a year',
        (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(
            SizedBox(
              height: 320,
              child: SearchResultCard(
                result: const SearchResult(
                  id: 'c1',
                  type: SearchResultType.collection,
                  title: 'Alien Anthology',
                  subtitle: '4 items',
                ),
                onTap: () {},
              ),
            ),
          ),
        );
      });

      expect(find.text('4 items'), findsOneWidget);
    });

    testWidgets(
        'offers no play affordance at rest or on hover, because tapping a '
        'result opens the title rather than playing it', (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(
            SizedBox(
              height: 320,
              child: SearchResultCard(
                result: const SearchResult(
                  id: 'm1',
                  type: SearchResultType.movie,
                  title: 'Alien',
                  year: 1979,
                ),
                onTap: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(findPlayGlyph(), findsNothing);

        await hoverOver(tester, find.byType(SearchResultCard));

        expect(findPlayGlyph(), findsNothing);
        expect(
          hoverCursor(tester, of: find.byType(SearchResultCard)),
          SystemMouseCursors.click,
        );
      });
    });
  });

  group('SearchFilterChip', () {
    testWidgets('reports taps', (tester) async {
      var tapped = 0;

      await tester.pumpWidget(
        _host(
          SearchFilterChip(
            label: 'Episodes',
            icon: Icons.playlist_play_rounded,
            isSelected: false,
            onTap: () => tapped++,
          ),
        ),
      );

      await tester.tap(find.text('Episodes'));
      expect(tapped, 1);
    });
  });
}
