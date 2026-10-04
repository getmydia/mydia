/// Routes for Plex and Jellyfin items that open on the shared detail screens.
library;

import 'package:go_router/go_router.dart';

import '../../domain/detail/detail_target.dart';
import '../../domain/sources/item.dart';
import '../../presentation/screens/detail/detail_links.dart';
import '../../presentation/screens/episode/episode_detail_screen.dart';
import '../../presentation/screens/movie/movie_detail_screen.dart';
import '../../presentation/screens/show/show_detail_screen.dart';
import '../../presentation/screens/sources/source_item_screen.dart';
import '../../presentation/screens/sources/source_season_route.dart';
import '../sources/source.dart';
import 'navigator_keys.dart';

ItemRef _refOf(GoRouterState state, ItemKind kind) => ItemRef(
      sourceId: SourceId(state.pathParameters['sourceId']!),
      kind: kind,
      externalId: state.pathParameters['itemId']!,
    );

ItemKind _kindParam(GoRouterState state) =>
    ItemKind.values.asNameMap()[state.pathParameters['kind']] ?? ItemKind.movie;

/// `/s/:sourceId/item/:kind/:itemId`. Movies, shows, seasons and episodes
/// redirect to their detail route; video and folder keep the generic screen.
GoRoute sourceItemRoute() => GoRoute(
      path: '/s/:sourceId/item/:kind/:itemId',
      name: 'source_item',
      redirect: (context, state) {
        final kind = _kindParam(state);
        if (detailKindOf(kind) == null) return null;
        return detailLocation(SourceTarget(_refOf(state, kind)));
      },
      builder: (context, state) =>
          SourceItemScreen(item: _refOf(state, _kindParam(state))),
    );

/// Full-window source detail routes, beside `/movie/:id`.
List<GoRoute> sourceDetailRoutes() => [
      GoRoute(
        path: '/s/:sourceId/movie/:itemId',
        name: 'source_movie_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => MovieDetailScreen.target(
          target: SourceTarget(_refOf(state, ItemKind.movie)),
        ),
      ),
      GoRoute(
        path: '/s/:sourceId/show/:itemId',
        name: 'source_show_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => ShowDetailScreen.target(
          target: SourceTarget(_refOf(state, ItemKind.show)),
        ),
      ),
      GoRoute(
        path: '/s/:sourceId/season/:itemId',
        name: 'source_season_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) =>
            SourceSeasonRoute(season: _refOf(state, ItemKind.season)),
      ),
      GoRoute(
        path: '/s/:sourceId/episode/:itemId',
        name: 'source_episode_detail',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => EpisodeDetailScreen.target(
          target: SourceTarget(_refOf(state, ItemKind.episode)),
        ),
      ),
    ];
