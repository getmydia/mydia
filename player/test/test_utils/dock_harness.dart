// Mounts a screen the way AppShell actually mounts it, so dock clearance can
// be asserted against the REAL BottomNav height rather than a guess.
//
// This matters: the existing screen tests mount screens directly under
// MaterialApp, where `MediaQuery.padding.bottom` is the raw view inset. Only
// inside a `Scaffold(extendBody: true)` carrying a real bottomNavigationBar
// does that value become the dock height, which is what DockInsets reads.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';

/// Key on the harness's dock, so tests can measure it.
const Key kDockKey = Key('dock-harness-nav');

/// Wraps [child] in the same shape `AppShell`'s mobile branch builds:
/// `Scaffold(extendBody: true)` with a real `BottomNav`, and the shell's
/// content gutter around the body.
///
/// Callers must supply their own `ProviderScope`; `BottomNav` needs one
/// because `SettingsNavItem` reads a provider for its badge.
Widget shellHarness({required Widget child}) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        bottomNavigationBar: KeyedSubtree(
          key: kDockKey,
          child: BottomNav(location: '/', onNavigate: (_) {}),
        ),
        body: AppShell.contentGutter(child: child),
      ),
    );

/// The measured height of the harness's dock, safe-area inset included.
double dockHeightOf(WidgetTester tester) =>
    tester.getSize(find.byKey(kDockKey)).height;

/// Asserts [lastItem]'s bottom edge sits clear of the dock.
///
/// "Clear" means above the dock's top edge, which is where the last item must
/// land once the user has scrolled all the way down. If content can never be
/// brought past the dock, this fails.
void expectClearsDock(WidgetTester tester, Finder lastItem) {
  final viewportBottom = tester.getSize(find.byType(MaterialApp)).height;
  final dockTop = viewportBottom - dockHeightOf(tester);
  final itemBottom = tester.getRect(lastItem).bottom;

  expect(
    itemBottom,
    lessThanOrEqualTo(dockTop),
    reason: 'last item bottom ($itemBottom) is under the dock, whose top edge '
        'is at $dockTop. The screen is not reserving DockInsets.bottomOf.',
  );
}
