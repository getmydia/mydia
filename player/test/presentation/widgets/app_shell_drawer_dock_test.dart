// The dock must not float over an open nav drawer.
//
// Flutter's Scaffold adds its drawer slot BEFORE bottomNavigationBar, and
// paint order follows that list, so a floating dock paints on top of both the
// drawer and its scrim and keeps intercepting taps. Rather than re-parenting
// the drawer (which would mean owning the drag gesture, scrim and animation),
// the shell fades the dock out while the drawer is open.
//
// These tests call the REAL `AppShell.dockChrome` seam, the same
// `@visibleForTesting` pattern `AppShell.castOverlay` and
// `AppShell.contentGutter` use. A hand-rolled mirror of the shell's shape
// would stay green if the shell dropped the fade entirely.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/app_shell.dart';

/// Marks the dock stand-in, so its mounted state and height can be measured.
const Key _dockKey = Key('dock');

/// Wraps the seam so finders can be scoped to it. `MaterialApp` and `Scaffold`
/// both plant `IgnorePointer`s of their own, so an unscoped
/// `find.byType(IgnorePointer)` matches several and `tester.widget` throws
/// `Bad state: Too many elements`.
const Key _rootKey = Key('dock-chrome-root');

Future<void> pumpChrome(
  WidgetTester tester, {
  required bool drawerOpen,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.bottomCenter,
        child: KeyedSubtree(
          key: _rootKey,
          child: AppShell.dockChrome(
            drawerOpen: drawerOpen,
            child: const SizedBox(key: _dockKey, height: 83),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double dockOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.descendant(
      of: find.byKey(_rootKey),
      matching: find.byType(AnimatedOpacity),
    ))
    .opacity;

bool dockIgnoring(WidgetTester tester) => tester
    .widget<IgnorePointer>(find.descendant(
      of: find.byKey(_rootKey),
      matching: find.byType(IgnorePointer),
    ))
    .ignoring;

void main() {
  group('AppShell.dockChrome', () {
    testWidgets('is opaque and interactive with the drawer closed',
        (tester) async {
      await pumpChrome(tester, drawerOpen: false);

      expect(dockOpacity(tester), 1);
      expect(dockIgnoring(tester), isFalse);
    });

    testWidgets('is transparent and inert with the drawer open',
        (tester) async {
      await pumpChrome(tester, drawerOpen: true);

      expect(dockOpacity(tester), 0);
      // Without this the user can tap "Home" straight through an open drawer.
      expect(dockIgnoring(tester), isTrue);
    });

    testWidgets('keeps the dock mounted at full height while faded',
        (tester) async {
      await pumpChrome(tester, drawerOpen: false);
      final closedHeight = tester.getSize(find.byKey(_dockKey)).height;

      await pumpChrome(tester, drawerOpen: true);

      // Mounted and unchanged: `MediaQuery.padding.bottom` stays put, so no
      // screen's content reflows behind the open drawer. Swapping the bar for
      // null would reflow every screen twice per drawer interaction.
      expect(find.byKey(_dockKey), findsOneWidget);
      expect(tester.getSize(find.byKey(_dockKey)).height, closedHeight);
    });
  });

  group('Scaffold.onDrawerChanged', () {
    testWidgets('reports open then closed, which is what drives the fade',
        (tester) async {
      final events = <bool>[];
      final scaffoldKey = GlobalKey<ScaffoldState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            key: scaffoldKey,
            onDrawerChanged: events.add,
            drawer: const Drawer(child: SizedBox.expand()),
            body: const SizedBox.expand(),
          ),
        ),
      );

      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      expect(events, [true]);

      scaffoldKey.currentState!.closeDrawer();
      await tester.pumpAndSettle();
      expect(events, [true, false]);
    });
  });
}
