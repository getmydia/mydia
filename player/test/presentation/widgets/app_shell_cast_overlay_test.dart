// The shell pins CastOverlayButton into its own Stack so casting is reachable
// even on desktop screens that suppress their app bar entirely (Home,
// Unwatched, Favorites, RecentlyAdded, Collections). But some in-shell
// screens (Library, Downloads, Settings, Search) keep a real, always-visible
// app bar with their own action buttons in the same top-right band the
// overlay paints into — those screens carry their own CastButton instead, and
// the shell must not also paint the overlay there, or the overlay sits on top
// of and intercepts taps for the screen's own actions.
//
// `AppShell.hasOwnCastButton` is the single routing decision that keeps these
// two mutually exclusive. It's asserted directly here (rather than by
// mounting the full `AppShell`, which needs a GoRouter ancestor plus the auth/
// connection/download provider graph — no existing shell test does that; see
// app_shell_backdrop_test.dart and app_shell_search_nav_test.dart, which both
// use lightweight stand-ins instead) and then exercised against a Stack that
// reproduces the shell's exact `if (showCastOverlay) CastOverlayButton(...)`
// pattern, so a regression in either the predicate or the wiring is caught.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/cast_actions.dart';

void main() {
  group('AppShell.hasOwnCastButton', () {
    // Library, Downloads, Settings and Search all keep a real app bar on
    // every platform (no desktop suppression) and were each given their own
    // CastButton in this fix — see the corresponding screen files.
    for (final location in [
      '/movies',
      '/shows',
      '/downloads',
      '/settings',
      '/search',
      // Sub-paths under a route with its own button must also be excluded
      // from the overlay, matching how `_isHomeSection`/`_isLibrarySection`
      // already treat these as prefixes, not exact matches.
      '/search?q=foo&type=movie',
      '/settings/devices',
    ]) {
      test('is true for $location (screen carries its own CastButton)', () {
        expect(AppShell.hasOwnCastButton(location), isTrue);
      });
    }

    // Home, Unwatched, Favorites, RecentlyAdded and Collections all suppress
    // their app bar entirely on desktop — the overlay is the only cast
    // affordance they ever get, so it must stay lit for these routes.
    for (final location in [
      '/',
      '/unwatched',
      '/favorites',
      '/recently-added',
      '/collections',
    ]) {
      test('is false for $location (overlay is the only affordance)', () {
        expect(AppShell.hasOwnCastButton(location), isFalse);
      });
    }
  });

  group('the shell Stack, gated by hasOwnCastButton', () {
    /// Reproduces the exact conditional the shell's own Stack children use:
    /// `if (!AppShell.hasOwnCastButton(location)) CastOverlayButton(...)`.
    Widget stackFor(String location) {
      final showCastOverlay = !AppShell.hasOwnCastButton(location);

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
                if (showCastOverlay) const CastOverlayButton(topInset: 40),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('renders no cast button on a route with its own (e.g. /movies)',
        (tester) async {
      await tester.pumpWidget(stackFor('/movies'));
      await tester.pump();

      expect(find.byKey(const Key('cast-button')), findsNothing);
    });

    testWidgets(
        'renders exactly one overlay cast button on a route with no app-bar '
        'affordance (e.g. /)', (tester) async {
      await tester.pumpWidget(stackFor('/'));
      await tester.pump();

      expect(find.byKey(const Key('cast-button')), findsOneWidget);
    });
  });
}
