// The shell pins CastOverlayButton into its own Stack so casting is reachable
// on a screen that suppresses its app bar on desktop and therefore has no
// top-right band of its own. Home is the last such destination. Every other
// in-shell screen keeps a real, always-visible app bar with its own action
// buttons in exactly the band the overlay paints into, and carries its own
// CastButton there, so the shell must not also paint the overlay: doing so
// stacks two cast buttons in the same corner (which reads as a doubled
// header) and intercepts taps meant for the screen's own actions.
//
// `AppShell.needsCastOverlay` is the single routing decision that keeps these
// two mutually exclusive. It was once the opposite question, an allowlist of
// routes that carried their own button, and that list silently fell behind
// twice: `/calendar` and `/filter/:id` both grew a real bar with a CastButton
// and neither was added, so both showed the doubled button. The cases below
// pin the inverted form, where a route is only in the overlay's path if it is
// named here.
//
// The predicate is asserted directly (rather than by mounting the full
// `AppShell`, which needs a GoRouter ancestor plus the auth/connection/
// download provider graph, and no existing shell test does that; see
// app_shell_backdrop_test.dart and app_shell_search_nav_test.dart, which both
// use lightweight stand-ins instead), and the rendering is then driven
// through `AppShell.castOverlaySlot`, the same seam the shell's two branches
// drop into their own `Stack`.
//
// The slot matters: an earlier draft of this file rebuilt the shell's
// `if (showCastOverlay) ...` conditional inside the test instead, which
// CodeRabbit flagged on #645 as proving only that the test's own copy worked.
// The conditional now lives in the seam, so these cases fail if the shell's
// routing decision regresses rather than passing against a mirror.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/presentation/widgets/app_shell.dart';

void main() {
  group('AppShell.needsCastOverlay', () {
    // Every in-shell destination other than Home. Library, Downloads,
    // Settings and Search keep a real app bar on every platform and were each
    // given their own CastButton; the rest gained an always-visible glass bar
    // with a trailing CastButton when they moved onto `BrowseScaffold`.
    for (final location in [
      '/movies',
      '/shows',
      '/downloads',
      '/settings',
      '/search',
      '/unwatched',
      '/continue-watching',
      '/favorites',
      '/recently-added',
      '/collections',
      // The two the old allowlist missed. `/calendar` renders through
      // `BrowseScaffold`; `/filter/:id` builds its own bar with a CastButton
      // after the view-toggle and overflow menu. Both showed two cast buttons
      // stacked in the top-right corner until this predicate was inverted.
      '/calendar',
      '/filter/1',
      // Sub-paths and query strings resolve the same way as their parents.
      '/search?q=foo&type=movie',
      '/settings/devices',
    ]) {
      test('is false for $location (screen carries its own CastButton)', () {
        expect(AppShell.needsCastOverlay(location), isFalse);
      });
    }

    // Home is the last in-shell destination that still suppresses its app bar
    // on desktop, so the overlay remains its only cast affordance.
    test('is true for / (overlay is the only affordance)', () {
      expect(AppShell.needsCastOverlay('/'), isTrue);
    });
  });

  group('AppShell.castOverlaySlot', () {
    /// Mounts the real seam, in the `Stack` it is built for.
    Widget slotFor(String location, {bool isDesktop = true}) {
      return ProviderScope(
        overrides: [
          castCapabilitiesProvider.overrideWithValue(
            const CastCapabilities.full(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(),
                AppShell.castOverlaySlot(
                  location: location,
                  isDesktop: isDesktop,
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('renders no cast button on a route with its own (e.g. /movies)',
        (tester) async {
      await tester.pumpWidget(slotFor('/movies'));
      await tester.pump();

      expect(find.byKey(const Key('cast-button')), findsNothing);
    });

    testWidgets('renders no cast button on /calendar, which has its own',
        (tester) async {
      await tester.pumpWidget(slotFor('/calendar'));
      await tester.pump();

      expect(find.byKey(const Key('cast-button')), findsNothing);
    });

    testWidgets('renders no cast button on /filter/1, which has its own',
        (tester) async {
      await tester.pumpWidget(slotFor('/filter/1'));
      await tester.pump();

      expect(find.byKey(const Key('cast-button')), findsNothing);
    });

    testWidgets(
        'renders exactly one overlay cast button on a route with no app-bar '
        'affordance (e.g. /)', (tester) async {
      await tester.pumpWidget(slotFor('/'));
      await tester.pump();

      expect(find.byKey(const Key('cast-button')), findsOneWidget);
    });

    testWidgets('does the same on the mobile branch', (tester) async {
      await tester.pumpWidget(slotFor('/calendar', isDesktop: false));
      await tester.pump();
      expect(find.byKey(const Key('cast-button')), findsNothing);

      await tester.pumpWidget(slotFor('/', isDesktop: false));
      await tester.pump();
      expect(find.byKey(const Key('cast-button')), findsOneWidget);
    });
  });
}
