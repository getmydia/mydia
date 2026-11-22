/// Insetting the shell's pages by the floating rail, once, for all of them.
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../presentation/widgets/shell_rail_inset.dart';

/// Shell routes that paint full-bleed themselves and so are not wrapped in a
/// `ShellPageInset`: the Home screens (the hero's backdrop runs under the
/// rail) and the movie and show pages, which seasons and episodes open (art
/// and ground run under it). They read `ShellRailInset` and inset their own
/// text, controls and rows.
const Set<String> fullBleedShellRoutes = {
  'source_root',
  'all_servers',
  'source_movie_detail',
  'source_show_detail',
  'source_season_detail',
  'source_episode_detail',
};

/// [routes] for a `ShellRoute`: the destinations the rail and tab bar switch
/// between.
///
/// Each page is inset by the rail's footprint (`ShellRailInset`) inside its own
/// route; the shell's navigator spans the whole window and does not pad, so a
/// page pushed over another never moves it. Routes named in
/// [fullBleedShellRoutes] are not inset.
///
/// A destination pushed over another page (a detail page, a search) opens with
/// the theme's transition. One that replaces the page below it, which is what
/// a rail or tab switch does, appears at once: the theme's fade would run the
/// old page out before the new one in, leaving the background bare for a
/// moment on every switch.
List<RouteBase> shellPages(List<RouteBase> routes) => [
  for (final route in routes)
    if (route is GoRoute)
      _destination(route, inset: !fullBleedShellRoutes.contains(route.name))
    else
      route,
];

GoRoute _destination(GoRoute route, {required bool inset}) {
  final builder = route.builder;
  // A route with only a `redirect` still needs no page; keep it as it is.
  if (builder == null || route.pageBuilder != null) return route;
  return GoRoute(
    path: route.path,
    name: route.name,
    redirect: route.redirect,
    metadata: route.metadata,
    parentNavigatorKey: route.parentNavigatorKey,
    onExit: route.onExit,
    caseSensitive: route.caseSensitive,
    routes: route.routes,
    pageBuilder: (context, state) {
      final page = builder(context, state);
      return CustomTransitionPage<void>(
        key: state.pageKey,
        name: state.name,
        restorationId: state.pageKey.value,
        // app_theme.dart gives every platform FadeForwards.
        transitionDuration: _fadeForwards.transitionDuration,
        reverseTransitionDuration: _fadeForwards.reverseTransitionDuration,
        transitionsBuilder: _destinationTransition,
        child: inset ? ShellPageInset(child: page) : page,
      );
    },
  );
}

const _fadeForwards = FadeForwardsPageTransitionsBuilder();

/// The theme's page transition, except that a destination at the bottom of
/// the shell's stack has already arrived: it replaced the page below it, so
/// its own entrance is skipped. It still plays the theme's exit when a page
/// is pushed over it.
Widget _destinationTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final route = ModalRoute.of(context)! as PageRoute<void>;
  return Theme.of(context).pageTransitionsTheme.buildTransitions(
    route,
    context,
    route.isFirst ? kAlwaysCompleteAnimation : animation,
    secondaryAnimation,
    child,
  );
}
