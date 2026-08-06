import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart' show OperationDefinitionNode;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/show/show_detail_screen.dart';
import 'package:player/presentation/widgets/cast_rail.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

String? _operationName(Request request) {
  final operations = request.operation.document.definitions
      .whereType<OperationDefinitionNode>();
  return operations.isEmpty ? null : operations.first.name?.value;
}

Map<String, dynamic> _episodeJson(int number, {bool watched = false}) {
  return {
    '__typename': 'Episode',
    'id': 'ep-$number',
    'seasonNumber': 1,
    'episodeNumber': number,
    'title': 'Episode $number',
    'overview': 'Overview for episode $number.',
    'airDate': null,
    'runtime': 43,
    'monitored': true,
    'thumbnailUrl': null,
    'hasFile': true,
    'progress': watched
        ? {
            '__typename': 'Progress',
            'positionSeconds': 0,
            'durationSeconds': 2580,
            'percentage': 100.0,
            'watched': true,
            'lastWatchedAt': null,
          }
        : null,
    'files': <dynamic>[],
  };
}

Map<String, dynamic> _showJson() {
  return {
    '__typename': 'TvShow',
    'id': 'sh-1',
    'title': 'Harbor Lights',
    'originalTitle': null,
    'year': 2022,
    'overview': 'A coastal mystery series.',
    'status': 'Continuing',
    'genres': ['Mystery', 'Drama'],
    'contentRating': 'TV-14',
    'rating': 7.9,
    'tmdbId': null,
    'imdbId': null,
    'category': null,
    'monitored': true,
    'addedAt': null,
    'seasonCount': 1,
    'episodeCount': 3,
    'artwork': {
      '__typename': 'Artwork',
      'posterUrl': null,
      'backdropUrl': null,
      'thumbnailUrl': null,
    },
    'seasons': [
      {
        '__typename': 'Season',
        'seasonNumber': 1,
        'episodeCount': 3,
        'airedEpisodeCount': 3,
        'hasFiles': true,
      },
    ],
    'nextEpisode': null,
    'nextUp': {
      '__typename': 'ShowNextUp',
      'progressState': 'next',
      'episode': _episodeJson(2),
    },
    'isFavorite': false,
    'cast': [
      {
        '__typename': 'CastMember',
        'name': 'Del Osei',
        'character': 'Det. Osei',
        'profileUrl': null,
      },
    ],
    'trailerUrl': null,
    'similar': <dynamic>[],
  };
}

Future<void> _pumpScreen(WidgetTester tester) async {
  final link = StubLink((request, _) {
    final operation = _operationName(request);
    if (operation == 'SeasonEpisodes') {
      return {
        '__typename': 'Query',
        'seasonEpisodes': [
          _episodeJson(1, watched: true),
          _episodeJson(2),
          _episodeJson(3),
        ],
      };
    }
    return {'__typename': 'Query', 'tvShow': _showJson()};
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
            initialLocation: '/show/sh-1',
            routes: [
              GoRoute(
                path: '/show/:id',
                builder: (context, state) =>
                    ShowDetailScreen(id: state.pathParameters['id']!),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  });
}

void main() {
  testWidgets('hero defaults to the next-unwatched episode', (tester) async {
    await _pumpScreen(tester);

    expect(find.textContaining('E2'), findsWidgets);
    expect(find.byType(CastRail), findsOneWidget);
  });

  testWidgets('tapping a different episode re-targets the hero',
      (tester) async {
    await _pumpScreen(tester);

    // The episode rail sits below the redesigned hero/cast/similar sections,
    // past the default test viewport — scroll it into view before tapping.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ep-3')),
      200,
      // The screen has multiple Scrollables (cast rail, season chips, episode
      // rail are all horizontal ListViews); the first one found in the tree
      // is the outer vertical CustomScrollView, which is what needs to move.
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('ep-3')));
    await tester.pumpAndSettle();

    expect(find.textContaining('E3'), findsWidgets);
  });
}
