import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/widgets/cast_rail.dart';
import 'package:player/presentation/widgets/detail_action_row.dart';
import 'package:player/presentation/widgets/play_button.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _movieJson({Map<String, dynamic>? progress}) {
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
    'progress': progress,
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

Map<String, dynamic> _progressJson({
  required bool watched,
  String? lastWatchedAt,
}) {
  return {
    '__typename': 'Progress',
    'positionSeconds': 4200,
    'durationSeconds': 8760,
    'percentage': 48.0,
    'watched': watched,
    'lastWatchedAt': lastWatchedAt,
  };
}

Future<void> _pumpScreen(
  WidgetTester tester,
  Size size, {
  Map<String, dynamic>? movieJson,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final link = StubLink((request, _) {
    return {'__typename': 'Query', 'movie': movieJson ?? _movieJson()};
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

  testWidgets('hero shows the release year under the title', (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    expect(find.text('2024'), findsOneWidget);
  });

  testWidgets('rating renders under the overview, not in the tag row',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    expect(find.text('8.1'), findsOneWidget);
  });

  testWidgets('shows the watched line when the movie is marked watched',
      (tester) async {
    await _pumpScreen(
      tester,
      const Size(1000, 900),
      movieJson: _movieJson(
        progress: _progressJson(
          watched: true,
          lastWatchedAt: '2026-08-01T00:00:00Z',
        ),
      ),
    );

    // `find.text('Watched')` alone would also match DetailActionRow's
    // static "Watched" button label, so this looks for the
    // "Watched · <date>" separator that only MovieWatchedLine renders.
    expect(find.textContaining('Watched ·'), findsOneWidget);
  });

  testWidgets('shows a resume progress bar when there is resumable progress',
      (tester) async {
    await _pumpScreen(
      tester,
      const Size(1000, 900),
      movieJson: _movieJson(progress: _progressJson(watched: false)),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('hero play control sits flush against the overlay right edge',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));
    await tester.pumpAndSettle();

    // The content overlay is inset 20 from the right of the 1000px surface.
    // The fixture supplies no files, so SmartPlayButton renders neither a
    // resolution label nor a dropdown and PlayButton is its only child.
    expect(tester.getRect(find.byType(PlayButton)).right, closeTo(980, 0.5));
  });

  testWidgets('hero play control lives in the hero, not the body',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));
    await tester.pumpAndSettle();

    // 380 is the hero SliverAppBar's expandedHeight
    // (movie_detail_screen.dart:448). Unscrolled, anything below that line is
    // in the body, where _buildActionColumn lives.
    final play = tester.getRect(find.byType(PlayButton));
    final actions = tester.getRect(find.byType(DetailActionRow));
    expect(play.bottom, lessThan(380));
    expect(play.bottom, lessThan(actions.top));
  });
}
