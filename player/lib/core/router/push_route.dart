/// Opening a route from code that does not know what is on screen.
library;

import 'package:go_router/go_router.dart';

import 'detail_location.dart';
import 'navigator_keys.dart';

/// Whether a page sits on the root navigator above the shell: the player,
/// settings sub-pages, `/sources/*`, `/unlock`.
bool rootRouteIsOnTop() => rootNavigatorKey.currentState?.canPop() ?? false;

/// Opens [path] for a caller that can run at any time: a remote `LoadContent`
/// or a cast session brought back to this device.
///
/// Detail pages live on the shell's navigator. go_router cannot push a shell
/// route while a root-navigator page is above the shell (an assertion in the
/// navigator, then a null check when the page pops, which leaves a blank
/// screen). So a detail page first closes whatever sits above the shell, then
/// is pushed: the viewer lands on the detail page beside the rail, and Back
/// returns to the page the shell was showing. Everything else is pushed as is.
void pushRouteSafely(GoRouter router, String path) {
  if (isDetailLocation(path) && rootRouteIsOnTop()) {
    rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
  }
  router.push(path);
}
