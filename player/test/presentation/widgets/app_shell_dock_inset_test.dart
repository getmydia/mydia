// Regression guard for the mechanism every screen's dock clearance depends on.
//
// `AppShell`'s mobile branch uses `Scaffold(extendBody: true)` so content
// scrolls under the frosted dock. Flutter compensates by rewriting the body's
// `MediaQuery.padding.bottom` to the dock's measured height. `DockInsets`
// reads that value rather than measuring anything itself, so if Flutter ever
// changes this behaviour every screen regresses at once and silently. These
// tests fail instead.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';

/// An iPhone-style home indicator inset.
const double kHomeIndicator = 34;

void main() {
  testWidgets('extendBody publishes the dock height as padding.bottom',
      (tester) async {
    const dockContentHeight = 60.0;
    double? observedBottom;
    final navKey = GlobalKey();

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(400, 800),
          padding: EdgeInsets.only(bottom: kHomeIndicator),
          viewPadding: EdgeInsets.only(bottom: kHomeIndicator),
        ),
        child: MaterialApp(
          home: Scaffold(
            extendBody: true,
            bottomNavigationBar: SafeArea(
              key: navKey,
              child: const SizedBox(height: dockContentHeight),
            ),
            body: Builder(
              builder: (context) {
                observedBottom = MediaQuery.paddingOf(context).bottom;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );

    final navHeight = tester.getSize(find.byKey(navKey)).height;
    // The nav's own SafeArea absorbs the home indicator, so its measured
    // height already includes it.
    expect(navHeight, dockContentHeight + kHomeIndicator);
    // ...and the body sees exactly that, which is what DockInsets reads.
    expect(observedBottom, navHeight);
  });

  testWidgets('the inset survives the nested Scaffold every screen uses',
      (tester) async {
    const dockContentHeight = 60.0;
    double? innerBottom;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(400, 800),
          padding: EdgeInsets.only(bottom: kHomeIndicator),
          viewPadding: EdgeInsets.only(bottom: kHomeIndicator),
        ),
        child: MaterialApp(
          // Outer: AppShell's mobile Scaffold.
          home: Scaffold(
            extendBody: true,
            bottomNavigationBar: const SafeArea(
              child: SizedBox(height: dockContentHeight),
            ),
            body: AppShell.contentGutter(
              child: Column(
                children: [
                  Expanded(
                    // Inner: the per-screen Scaffold, as library and downloads
                    // build it.
                    child: Scaffold(
                      backgroundColor: Colors.transparent,
                      extendBodyBehindAppBar: true,
                      appBar: AppBar(title: const Text('screen')),
                      body: Builder(
                        builder: (context) {
                          innerBottom = MediaQuery.paddingOf(context).bottom;
                          return const SizedBox.expand();
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(innerBottom, dockContentHeight + kHomeIndicator);
  });

  group('the real BottomNav', () {
    testWidgets('is taller than the 100.0 the screens used to hardcode',
        (tester) async {
      final navKey = GlobalKey();

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            padding: EdgeInsets.only(bottom: kHomeIndicator),
            viewPadding: EdgeInsets.only(bottom: kHomeIndicator),
          ),
          child: ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                extendBody: true,
                bottomNavigationBar: KeyedSubtree(
                  key: navKey,
                  child: BottomNav(location: '/', onNavigate: (_) {}),
                ),
                body: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      // Measured 117.0. This is the number the old hardcoded 100.0 was short
      // of, and the reason content sat behind the dock on any phone with a
      // home indicator.
      expect(tester.getSize(find.byKey(navKey)).height, greaterThan(100));
    });

    testWidgets('still needs clearance with no system inset', (tester) async {
      final navKey = GlobalKey();

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                extendBody: true,
                bottomNavigationBar: KeyedSubtree(
                  key: navKey,
                  child: BottomNav(location: '/', onNavigate: (_) {}),
                ),
                body: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      // Measured 83.0. Screens reserving 0, 16 or 32 were behind the dock on
      // every device, not only phones with a home indicator.
      expect(tester.getSize(find.byKey(navKey)).height, greaterThan(80));
    });
  });
}
