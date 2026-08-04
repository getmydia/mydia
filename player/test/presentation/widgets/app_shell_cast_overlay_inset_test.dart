// Regression guard for the double-inset defect: `CastOverlayButton` wraps
// its child in a `SafeArea` (see cast_actions.dart), which already consumes
// whatever `WindowChromeInset` injects into the ambient
// `MediaQuery.padding.top`. A call site that *also* folds that same ambient
// padding into `topInset` pushes the button down twice on macOS windowed.
//
// Mirrors the shell's exact Stack children (see app_shell_cast_overlay_test
// .dart for the sibling test covering the routing predicate) rather than
// mounting the full `AppShell`, which needs a Riverpod graph, router
// location and GraphQL client — no existing shell test does that.
//
// Keep the `topInset` expressions below in sync with
// `lib/presentation/widgets/app_shell.dart`'s two `CastOverlayButton` call
// sites: this test does not exercise that source file directly, so a future
// edit to either site needs its mirror updated here too.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/presentation/widgets/cast_actions.dart';

void main() {
  group('the shell cast overlay under the macOS title bar strip', () {
    Widget shellStackChild(Widget castOverlayButton) {
      return MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(top: kMacTitleBarOverlap),
        ),
        child: ProviderScope(
          overrides: [
            castCapabilitiesProvider.overrideWithValue(
              const CastCapabilities.full(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(children: [castOverlayButton]),
            ),
          ),
        ),
      );
    }

    testWidgets(
        'desktop: the button lands at the same y it did before the strip '
        'existed (12 below the safe area), not 12 below double the strip',
        (tester) async {
      await tester.pumpWidget(
        shellStackChild(
          const CastOverlayButton(topInset: 12),
        ),
      );
      await tester.pump();

      expect(
        tester.getRect(find.byKey(const Key('cast-button'))).top,
        kMacTitleBarOverlap + 12,
      );
    });

    testWidgets(
        'mobile: the button lands one strip below its pre-strip position '
        '(kToolbarHeight + 8 below the safe area), not double the strip',
        (tester) async {
      await tester.pumpWidget(
        shellStackChild(
          const CastOverlayButton(topInset: kToolbarHeight + 8),
        ),
      );
      await tester.pump();

      expect(
        tester.getRect(find.byKey(const Key('cast-button'))).top,
        kMacTitleBarOverlap + kToolbarHeight + 8,
      );
    });
  });
}
