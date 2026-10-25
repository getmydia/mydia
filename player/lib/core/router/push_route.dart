/// Opening a route from code that does not know what is on screen.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'detail_location.dart';
import 'navigator_keys.dart';

/// The route on top of the root navigator, popups included.
Route<dynamic>? _rootTopRoute() {
  Route<dynamic>? top;
  // A predicate that accepts the first route it is shown pops nothing.
  rootNavigatorKey.currentState?.popUntil((route) {
    top = route;
    return true;
  });
  return top;
}

/// Whether a page (not a dialog or sheet) sits on the root navigator above the
/// shell: the player, settings sub-pages, `/sources/*`, `/unlock`.
bool rootRouteIsOnTop() {
  final top = _rootTopRoute();
  return top is PageRoute && !top.isFirst;
}

/// Route names whose page must not be navigated away from: the players, which
/// would stop playback, and the forms, which would lose unsaved input.
bool _isPlayer(String? name) =>
    name == 'source_player' || name == 'queue_player' || name == 'player';
bool _isForm(String? name) =>
    name == 'unlock' || (name?.startsWith('add_source') ?? false);

/// What [pushRouteSafely] did.
enum PushOutcome {
  /// Pushed as asked, over whatever was there.
  pushed,

  /// Closed root pages above the shell, then pushed.
  pushedAfterClosingPages,

  /// Left the screen alone: a player is open.
  blockedByPlayer,

  /// Left the screen alone: a form with possible unsaved input is open.
  blockedByForm,
}

/// Opens [path] for a caller that can run at any time: a remote `LoadContent`
/// or a cast session brought back to this device.
///
/// Detail pages live on the shell's navigator. go_router cannot push a shell
/// route while a root-navigator page is above the shell (an assertion in the
/// navigator, then a null check when the page pops, which leaves a blank
/// screen). Dialogs and sheets do not trigger that, so they are left alone.
/// For a detail location with a root page on top:
///
/// - a player is never closed (it would end playback): nothing opens
///   ([PushOutcome.blockedByPlayer]); the caller tells the viewer;
/// - nor is a sign-in or unlock form ([PushOutcome.blockedByForm]);
/// - any other root page is popped, then the detail page is pushed, so Back
///   returns to what the shell was showing. If a dialog or sheet sits above
///   that page it cannot be reached without closing it, so nothing opens
///   ([PushOutcome.blockedByForm]).
///
/// Everything else is pushed as is.
PushOutcome pushRouteSafely(GoRouter router, String path) {
  if (!isDetailLocation(path)) {
    router.push(path);
    return PushOutcome.pushed;
  }
  final navigator = rootNavigatorKey.currentState;
  var top = _rootTopRoute();
  if (navigator == null || top == null || top.isFirst) {
    router.push(path);
    return PushOutcome.pushed;
  }
  // Only a dialog or sheet above the shell: not what breaks the push.
  if (top is! PageRoute && !_pageBelowPopups(router)) {
    router.push(path);
    return PushOutcome.pushed;
  }
  if (top is! PageRoute) return PushOutcome.blockedByForm;

  var closed = false;
  while (top is PageRoute && !top.isFirst) {
    final name = top.settings.name;
    if (_isPlayer(name)) return PushOutcome.blockedByPlayer;
    if (_isForm(name)) return PushOutcome.blockedByForm;
    navigator.pop();
    closed = true;
    top = _rootTopRoute();
  }
  router.push(path);
  return closed ? PushOutcome.pushedAfterClosingPages : PushOutcome.pushed;
}

/// Whether the router's top page is a root-navigator page, seen through any
/// popups above it.
bool _pageBelowPopups(GoRouter router) =>
    router.state.topRoute?.parentNavigatorKey == rootNavigatorKey;
