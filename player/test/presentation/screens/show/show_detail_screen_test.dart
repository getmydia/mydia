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
import 'package:player/presentation/widgets/detail_action_row.dart';
import 'package:player/presentation/widgets/episode_rail_card.dart';
import 'package:player/presentation/widgets/play_button.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

String? _operationName(Request request) {
  final operations = request.operation.document.definitions
      .whereType<OperationDefinitionNode>();
  return operations.isEmpty ? null : operations.first.name?.value;
}

Map<String, dynamic> _fileJson(String id) {
  return {
    '__typename': 'MediaFile',
    'id': id,
    'resolution': '1080p',
    'codec': 'h264',
    'audioCodec': 'aac',
    'hdrFormat': null,
    'size': 1200000000,
    'bitrate': 4000000,
    'directPlaySupported': true,
    'streamUrl': null,
    'directPlayUrl': null,
  };
}

Map<String, dynamic> _episodeJson(
  int number, {
  int season = 1,
  bool watched = false,
  int? positionSeconds,
  List<Map<String, dynamic>> files = const [],
}) {
  Map<String, dynamic>? progress;
  if (watched) {
    progress = {
      '__typename': 'Progress',
      'positionSeconds': 0,
      'durationSeconds': 2580,
      'percentage': 100.0,
      'watched': true,
      'lastWatchedAt': null,
    };
  } else if (positionSeconds != null) {
    progress = {
      '__typename': 'Progress',
      'positionSeconds': positionSeconds,
      'durationSeconds': 2580,
      'percentage': positionSeconds / 2580 * 100,
      'watched': false,
      'lastWatchedAt': null,
    };
  }

  return {
    '__typename': 'Episode',
    'id': 'ep-$season-$number',
    'seasonNumber': season,
    'episodeNumber': number,
    'title': 'Episode $number',
    'overview': 'Overview for episode $number.',
    'airDate': null,
    'runtime': 43,
    'monitored': true,
    'thumbnailUrl': null,
    'hasFile': true,
    'progress': progress,
    'files': files,
  };
}

Map<String, dynamic> _showJson({
  Map<String, dynamic>? nextUpEpisode,
  bool includeNextUp = true,
  List<Map<String, dynamic>>? seasons,
}) {
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
    'seasons': seasons ??
        [
          {
            '__typename': 'Season',
            'seasonNumber': 1,
            'episodeCount': 3,
            'airedEpisodeCount': 3,
            'hasFiles': true,
          },
        ],
    'nextEpisode': null,
    'nextUp': includeNextUp
        ? {
            '__typename': 'ShowNextUp',
            'progressState': 'next',
            'episode': nextUpEpisode ?? _episodeJson(2),
          }
        : null,
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

Map<int, List<Map<String, dynamic>>> _defaultEpisodes() => {
      1: [
        _episodeJson(1, watched: true),
        _episodeJson(2),
        _episodeJson(3),
      ],
    };

Future<void> _pumpScreen(
  WidgetTester tester, {
  Map<String, dynamic>? showJson,
  Map<int, List<Map<String, dynamic>>>? episodesBySeason,
  List<String>? pushedRoutes,
  Size? size,
}) async {
  if (size != null) {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  final episodes = episodesBySeason ?? _defaultEpisodes();

  final link = StubLink((request, _) {
    final operation = _operationName(request);
    if (operation == 'SeasonEpisodes') {
      final seasonNumber = request.variables['seasonNumber'] as int;
      return {
        '__typename': 'Query',
        'seasonEpisodes': episodes[seasonNumber] ?? <dynamic>[],
      };
    }
    return {'__typename': 'Query', 'tvShow': showJson ?? _showJson()};
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
              GoRoute(
                path: '/player/episode/:id',
                builder: (context, state) {
                  pushedRoutes?.add(state.uri.toString());
                  return const Scaffold(body: SizedBox.shrink());
                },
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
      find.byKey(const ValueKey('ep-1-3')),
      200,
      // The screen has multiple Scrollables (cast rail, season chips, episode
      // rail are all horizontal ListViews); the first one found in the tree
      // is the outer vertical CustomScrollView, which is what needs to move.
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible stops as soon as the tile exists in the tree, which
    // the sliver cache extent makes true while it is still below the viewport
    // — ensureVisible actually brings it on screen so the tap lands.
    await tester.ensureVisible(find.byKey(const ValueKey('ep-1-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ep-1-3')));
    await tester.pumpAndSettle();

    expect(find.textContaining('E3'), findsWidgets);
  });

  testWidgets('fully-watched show (no nextUp) still renders the hero',
      (tester) async {
    // `resolve_next_up/3` returns nil once every episode is watched, so the
    // hero's default-selection seed never fires and `selectedEpisodeId` stays
    // null. The hero must fall back to the season's first episode rather than
    // spinning forever.
    await _pumpScreen(
      tester,
      showJson: _showJson(includeNextUp: false),
      episodesBySeason: {
        1: [
          _episodeJson(1, watched: true),
          _episodeJson(2, watched: true),
          _episodeJson(3, watched: true),
        ],
      },
    );

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(DetailActionRow), findsOneWidget);
    expect(find.text('S1 · E1'), findsOneWidget);
  });

  testWidgets('switching seasons re-targets the hero at the new season',
      (tester) async {
    // The selected episode id still points at a season 1 episode after the
    // switch, so it matches nothing in season 2's list — the hero has to fall
    // back to season 2's first episode instead of spinning forever.
    await _pumpScreen(
      tester,
      // A tall viewport keeps the hero and the season chips on screen at the
      // same time, so the assertion sees the hero the tap re-targeted rather
      // than an unbuilt sliver scrolled out of view.
      size: const Size(1000, 2200),
      showJson: _showJson(seasons: [
        {
          '__typename': 'Season',
          'seasonNumber': 1,
          'episodeCount': 3,
          'airedEpisodeCount': 3,
          'hasFiles': true,
        },
        {
          '__typename': 'Season',
          'seasonNumber': 2,
          'episodeCount': 2,
          'airedEpisodeCount': 2,
          'hasFiles': true,
        },
      ]),
      episodesBySeason: {
        1: [
          _episodeJson(1, watched: true),
          _episodeJson(2),
          _episodeJson(3),
        ],
        2: [
          _episodeJson(1, season: 2),
          _episodeJson(2, season: 2),
        ],
      },
    );

    await tester.tap(find.text('Season 2'));
    await tester.pumpAndSettle();

    expect(find.byType(DetailActionRow), findsOneWidget);
    expect(find.text('S2 · E1'), findsOneWidget);
  });

  testWidgets('hero shows the release year under the title', (tester) async {
    await _pumpScreen(tester);

    expect(find.text('2022'), findsOneWidget);
  });

  testWidgets('content rating and genres render once, in the hero tag row',
      (tester) async {
    // The tall viewport builds the lower metadata section too, so a
    // reintroduced duplicate down there would be found, not silently
    // scrolled out of the tree.
    await _pumpScreen(tester, size: const Size(1000, 2200));

    expect(find.text('TV-14'), findsOneWidget);
    expect(find.text('Mystery'), findsOneWidget);
    expect(find.text('Drama'), findsOneWidget);
  });

  testWidgets('Play passes a resume position for a part-watched episode',
      (tester) async {
    final pushed = <String>[];
    final partWatched = _episodeJson(
      2,
      positionSeconds: 900,
      files: [_fileJson('file-1')],
    );

    await _pumpScreen(
      tester,
      size: const Size(1000, 1200),
      showJson: _showJson(nextUpEpisode: partWatched),
      episodesBySeason: {
        1: [
          _episodeJson(1, watched: true),
          partWatched,
          _episodeJson(3),
        ],
      },
      pushedRoutes: pushed,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlayButton));
    await tester.pumpAndSettle();

    expect(pushed, hasLength(1));
    expect(pushed.single, contains('/player/episode/ep-1-2'));
    expect(pushed.single, contains('resume=900'));
  });

  testWidgets('Play omits resume for an already-watched episode',
      (tester) async {
    final pushed = <String>[];
    final watched = _episodeJson(
      2,
      watched: true,
      files: [_fileJson('file-1')],
    );

    await _pumpScreen(
      tester,
      size: const Size(1000, 1200),
      showJson: _showJson(nextUpEpisode: watched),
      episodesBySeason: {
        1: [
          _episodeJson(1, watched: true),
          watched,
          _episodeJson(3),
        ],
      },
      pushedRoutes: pushed,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlayButton));
    await tester.pumpAndSettle();

    expect(pushed, hasLength(1));
    expect(pushed.single, isNot(contains('resume=')));
  });

  testWidgets('hero play control sits flush against the overlay right edge',
      (tester) async {
    final playable = _episodeJson(2, files: [_fileJson('file-1')]);

    await _pumpScreen(
      tester,
      size: const Size(1000, 1200),
      showJson: _showJson(nextUpEpisode: playable),
      episodesBySeason: {
        1: [_episodeJson(1, watched: true), playable, _episodeJson(3)],
      },
    );
    await tester.pumpAndSettle();

    // The content overlay is inset 20 from the right of the 1000px surface.
    // The fixture supplies a single file, so SmartPlayButton renders no
    // quality dropdown and PlayButton is the control's last child.
    expect(tester.getRect(find.byType(PlayButton)).right, closeTo(980, 0.5));
  });

  testWidgets('hero play control lives in the hero, not the body',
      (tester) async {
    final playable = _episodeJson(2, files: [_fileJson('file-1')]);

    await _pumpScreen(
      tester,
      size: const Size(1000, 1200),
      showJson: _showJson(nextUpEpisode: playable),
      episodesBySeason: {
        1: [_episodeJson(1, watched: true), playable, _episodeJson(3)],
      },
    );
    await tester.pumpAndSettle();

    // 380 is the hero SliverAppBar's expandedHeight, set in
    // _buildHeroSection. Unscrolled, anything below that line is in the
    // body, where _buildActionColumn lives. This is what distinguishes
    // "moved to the title row" from "merely re-aligned in the action column".
    final play = tester.getRect(find.byType(PlayButton));
    final actions = tester.getRect(find.byType(DetailActionRow));
    expect(play.bottom, lessThan(380));
    expect(play.bottom, lessThan(actions.top));
  });

  testWidgets('hero overlay does not overflow at phone width', (tester) async {
    // The show hero is the wider of the two detail heroes — it carries the
    // episode context pill alongside the title and Play control — so it is
    // the most likely to overflow a narrow viewport, and until now it was
    // the untested one (the movie hero already has phone-width coverage at
    // Size(400, 900)). A layout overflow surfaces as a FlutterError, which
    // fails the test even without an explicit assertion for it.
    final playable = _episodeJson(2, files: [_fileJson('file-1')]);

    await _pumpScreen(
      tester,
      size: const Size(400, 1200),
      showJson: _showJson(nextUpEpisode: playable),
      episodesBySeason: {
        1: [_episodeJson(1, watched: true), playable, _episodeJson(3)],
      },
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets(
      'tapping a rail card selects the episode without starting playback',
      (tester) async {
    final pushed = <String>[];
    final playable = _episodeJson(3, files: [_fileJson('file-3')]);

    await _pumpScreen(
      tester,
      size: const Size(1000, 2200),
      episodesBySeason: {
        1: [_episodeJson(1, watched: true), _episodeJson(2), playable],
      },
      pushedRoutes: pushed,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byType(EpisodeRailCard).last,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    // The rail picks; the hero plays. Nothing here reaches the player.
    expect(pushed, isEmpty);
    // And the pick landed: the hero now describes the episode that was tapped.
    expect(find.textContaining('E3'), findsWidgets);
  });
}
