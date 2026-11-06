// A screen mounted inside the shell's television-tier focus regions, for the
// screen-level focus memory tests (`*_focus_tv_test.dart`).
//
// AppShell itself needs the authenticated provider graph, so this mounts what
// it mounts around a page instead: go_router's `ShellRoute` (whose navigator
// keeps Home mounted under a pushed detail page, as the app's own shell does)
// building `AppShell.railLayers`, the exact call the shell's `build` makes.
// The content region therefore carries the real `RegionTraversalPolicy` with
// `FocusMemory.requestFocus`, and LEFT/RIGHT across the region edge goes
// through the real `SidebarFocusBoundary`. The rail is a single focusable
// stand-in: what is under test is the content side of the boundary.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/focus/sidebar_focus_boundary.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/widgets/app_shell.dart';

import 'toast_harness.dart';

/// `skip:` for a television-tier group: false under
/// `--dart-define=MYDIA_FORCE_TV=true`, a reason otherwise.
final Object tvSkipReason = InputCapabilities.directionalPrimary
    ? false
    : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
        'InputCapabilities.directionalPrimary; CI runs it in the '
        '"Run television-tier tests" step.';

/// The key on the stand-in page [TvShell] pushes for any detail location.
const tvDetailStandInKey = Key('tv-detail-stand-in');

class TvShell {
  /// Must be constructed inside a test body: it registers its own teardown.
  TvShell() {
    addTearDown(sidebarRow.dispose);
    addTearDown(railScope.dispose);
    addTearDown(contentScope.dispose);
  }

  final sidebarRow = FocusNode(debugLabel: 'sidebar-row');
  final railScope = FocusScopeNode(debugLabel: 'sidebar-region');
  final contentScope = FocusScopeNode(debugLabel: 'content-region');
  late final boundary = SidebarFocusBoundary(
    sidebarNode: sidebarRow,
    contentScope: contentScope,
  );

  late final GoRouter router;
  late final ProviderContainer container;

  /// Mounts [screen] at `/` in the shell at television size, with every
  /// `/s/:id/:kind/:item` location opening a stand-in detail page in the same
  /// shell navigator, the way the app's detail routes do.
  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);

    router = GoRouter(routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell.railLayers(
          regionsEnabled: true,
          contentLeft: Breakpoints.railContentInset(pinned: false),
          railScope: railScope,
          contentScope: contentScope,
          boundary: boundary,
          content: child,
          railBuilder: (_) => Align(
            alignment: Alignment.centerLeft,
            child: Focus(
              focusNode: sidebarRow,
              child: const SizedBox(width: 48, height: 48),
            ),
          ),
        ),
        routes: [
          GoRoute(path: '/', builder: (_, __) => screen),
          GoRoute(
            path: '/s/:id/:kind/:item',
            builder: (_, __) => Scaffold(
              body: Center(
                child: TextButton(
                  key: tvDetailStandInKey,
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('Detail'),
                ),
              ),
            ),
          ),
        ],
      ),
    ]);
    addTearDown(router.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: toastLayerBuilder,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await tester.pumpAndSettle();
  }
}

/// Sends [key] and lets any scroll it started finish.
Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// The first focusable node inside the widget keyed [key].
FocusNode nodeIn(WidgetTester tester, Key key) {
  final element = tester.element(find.byKey(key, skipOffstage: false));
  return FocusManager.instance.rootScope.traversalDescendants.firstWhere(
    (node) => _isWithin(node.context, element),
    orElse: () => throw StateError('nothing focusable inside $key'),
  );
}

/// Focuses the widget keyed [key] directly, the way a viewer would have by
/// navigating there earlier.
Future<void> focusIn(WidgetTester tester, Key key) async {
  nodeIn(tester, key).requestFocus();
  await tester.pumpAndSettle();
  expectFocusIn(key);
}

/// Asserts the primary focus sits inside the widget keyed [key].
void expectFocusIn(Key key) {
  final focus = FocusManager.instance.primaryFocus;
  final element = find.byKey(key, skipOffstage: false).evaluate().firstOrNull;
  expect(
    element != null && _isWithin(focus?.context, element),
    isTrue,
    reason: 'expected focus inside $key, but it is on ${describeFocus()}',
  );
}

/// The two nearest value-keyed widgets around the primary focus, for failure
/// messages.
String describeFocus() {
  final focus = FocusManager.instance.primaryFocus;
  final context = focus?.context;
  if (context == null) return 'nothing';
  final keys = <Key>[];
  if (context.widget.key case final ValueKey<Object?> key) keys.add(key);
  context.visitAncestorElements((e) {
    if (e.widget.key case final ValueKey<Object?> key) keys.add(key);
    return keys.length < 2;
  });
  return '${keys.join(' in ')} ($focus)';
}

bool _isWithin(BuildContext? context, Element ancestor) {
  if (context == null) return false;
  if (identical(context, ancestor)) return true;
  var found = false;
  context.visitAncestorElements((e) {
    found = identical(e, ancestor);
    return !found;
  });
  return found;
}
