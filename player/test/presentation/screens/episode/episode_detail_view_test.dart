import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/episode/episode_detail_screen.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _episodeJson({bool withFile = false}) {
  return {
    '__typename': 'Episode',
    'id': 'e-1',
    'seasonNumber': 1,
    'episodeNumber': 3,
    'title': 'Copper Weather',
    'overview': 'The crew waits out a storm of metal dust.',
    'airDate': '2024-03-02',
    'runtime': 47,
    'monitored': true,
    'thumbnailUrl': null,
    'hasFile': true,
    'progress': null,
    'files': withFile
        ? [
            {'__typename': 'MediaFile', 'id': 'f-1', 'resolution': '1080p'},
          ]
        : <dynamic>[],
    'show': {
      '__typename': 'Show',
      'id': 's-1',
      'title': 'Invented Series',
      'artwork': {
        '__typename': 'Artwork',
        'posterUrl': null,
        'backdropUrl': null,
        'thumbnailUrl': null,
      },
    },
  };
}

Future<void> _pumpScreen(WidgetTester tester, {bool withFile = false}) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final link = StubLink((request, _) {
    return {
      '__typename': 'Query',
      'episode': _episodeJson(withFile: withFile),
    };
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
            initialLocation: '/episode/e-1',
            routes: [
              GoRoute(
                path: '/episode/:id',
                builder: (context, state) =>
                    EpisodeDetailScreen(id: state.pathParameters['id']!),
              ),
              GoRoute(
                path: '/show/:id',
                builder: (context, state) => const Text('show page'),
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
  testWidgets('the show link opens the show', (tester) async {
    await _pumpScreen(tester);
    await tester.tap(find.text('Invented Series'));
    await tester.pumpAndSettle();
    expect(find.text('show page'), findsOneWidget);
  });

  // The download branch (shown disabled for a file-less Mydia episode) needs
  // `isDownloadSupported`, which is false on the test platform, so it cannot
  // be exercised here. Media info is the file-dependent control we can check.
  testWidgets('media info shows only for an episode with files',
      (tester) async {
    await _pumpScreen(tester, withFile: true);
    expect(find.byKey(const Key('episode-media-info')), findsOneWidget);
  });

  testWidgets('media info is absent for a file-less episode', (tester) async {
    await _pumpScreen(tester);
    expect(find.byKey(const Key('episode-media-info')), findsNothing);
  });

  testWidgets('shows the episode code and title', (tester) async {
    await _pumpScreen(tester);
    expect(find.text('S01E03'), findsOneWidget);
    expect(find.text('Copper Weather'), findsOneWidget);
  });
}
