import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/widgets/cast_rail.dart';
import 'package:player/presentation/widgets/detail_action_row.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _movieJson() {
  return {
    '__typename': 'Movie',
    'id': 'm-1',
    'title': 'Meridian Drift',
    'originalTitle': null,
    'year': 2024,
    'overview': 'A drifting research platform runs out of air.',
    'runtime': 146,
    'genres': ['Sci-Fi', 'Adventure'],
    'contentRating': 'PG-13',
    'rating': 8.1,
    'tmdbId': null,
    'imdbId': null,
    'category': null,
    'monitored': true,
    'addedAt': null,
    'artwork': {
      '__typename': 'Artwork',
      'posterUrl': null,
      'backdropUrl': null,
      'thumbnailUrl': null,
    },
    'progress': null,
    'files': <dynamic>[],
    'isFavorite': false,
    'cast': [
      {
        '__typename': 'CastMember',
        'name': 'Ana Bergström',
        'character': 'Kira Solt',
        'profileUrl': null,
      },
    ],
    'trailerUrl': null,
    'similar': <dynamic>[],
  };
}

Future<void> _pumpScreen(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final link = StubLink((request, _) {
    return {'__typename': 'Query', 'movie': _movieJson()};
  });

  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          asyncGraphqlClientProvider
              .overrideWith((ref) async => stubClient(link)),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/movie/m-1',
            routes: [
              GoRoute(
                path: '/movie/:id',
                builder: (context, state) =>
                    MovieDetailScreen(id: state.pathParameters['id']!),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  });
}

void main() {
  testWidgets('wide layout shows the action column beside the tag column',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(DetailActionRow), findsOneWidget);
    expect(find.byType(CastRail), findsOneWidget);
  });

  testWidgets('narrow layout still renders the action column and tags',
      (tester) async {
    await _pumpScreen(tester, const Size(400, 900));

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(DetailActionRow), findsOneWidget);
  });

  testWidgets('rating renders under the overview, not in the tag row',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    expect(find.text('8.1'), findsOneWidget);
  });
}
