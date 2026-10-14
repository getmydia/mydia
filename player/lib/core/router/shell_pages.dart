/// Insetting the shell's pages by the floating rail, once, for all of them.
library;

import 'package:go_router/go_router.dart';

import '../../presentation/widgets/shell_rail_inset.dart';

/// Shell routes that paint full-bleed themselves and so are not wrapped in a
/// `ShellPageInset`: the Home screens (the hero's backdrop runs under the
/// rail) and the movie, show, season and episode pages (art and ground run
/// under it). They read `ShellRailInset` and inset their own text, controls
/// and rows.
const Set<String> fullBleedShellRoutes = {
  'source_root',
  'all_servers',
  'source_movie_detail',
  'source_show_detail',
  'source_season_detail',
  'source_episode_detail',
};

/// [routes] for a `ShellRoute`, each page inset by the rail's footprint
/// (`ShellRailInset`) inside its own route. The shell's navigator spans the
/// whole window and does not pad, so a page pushed over another never moves
/// it. Routes named in [fullBleedShellRoutes] are returned as they are.
List<RouteBase> shellPages(List<RouteBase> routes) => [
      for (final route in routes)
        if (route is GoRoute && !fullBleedShellRoutes.contains(route.name))
          _inset(route)
        else
          route,
    ];

GoRoute _inset(GoRoute route) {
  final builder = route.builder;
  // A route with only a `redirect` still needs its builder; keep both.
  return GoRoute(
    path: route.path,
    name: route.name,
    redirect: route.redirect,
    metadata: route.metadata,
    parentNavigatorKey: route.parentNavigatorKey,
    onExit: route.onExit,
    caseSensitive: route.caseSensitive,
    routes: route.routes,
    builder: builder == null
        ? null
        : (context, state) => ShellPageInset(child: builder(context, state)),
    pageBuilder: route.pageBuilder,
  );
}
