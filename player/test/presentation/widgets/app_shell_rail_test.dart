// The shell shows the floating rail at 600px and wider and the bottom bar
// below. The shell itself needs the authenticated provider graph, so this
// file composes the same pieces the shell does: `Breakpoints.showsRail`
// choosing between `FloatingRail` and `BottomNav`, and the two focus regions
// wired with the real `SidebarFocusBoundary`, which is what the shell's TV
// tier does with them. `app_toast_layer_mounting_test.dart` pumps the whole
// app and covers the shell mounting at 1400.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/region_traversal_policy.dart';
import 'package:player/core/focus/sidebar_focus_boundary.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';
import 'package:player/presentation/widgets/nav/floating_rail.dart';

import '../screens/sources/fake_capable_source.dart';
import '../screens/sources/fake_media_source.dart';

class _MydiaLike extends FakeCapableSource {
  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.continueWatching};
}

const _railKey = Key('floating-rail');

double _railWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(_railKey)).width;

List<Override> _overrides() => [
      sidebarLayoutStoreProvider
          .overrideWithValue(InMemorySidebarLayoutStore()),
      thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
      hasMydiaProvider.overrideWithValue(true),
      mediaSourceProvider(fakeSourceId).overrideWithValue(_MydiaLike()),
    ];

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Mirrors the shell's choice between the rail and the phone bottom bar.
Widget _switchingHost() => ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            bottomNavigationBar: Breakpoints.showsRail(context)
                ? null
                : BottomNav(
                    location: '/',
                    onNavigate: (_) {},
                    entries: const [],
                    isOffline: false,
                  ),
            body: Breakpoints.showsRail(context)
                ? Stack(
                    children: [
                      FloatingRail(
                        location: '/',
                        onNavigate: (_) {},
                        isOffline: false,
                      ),
                    ],
                  )
                : const SizedBox.expand(),
          ),
        ),
      ),
    );

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('renders the rail, not the bottom bar, at $width',
        (tester) async {
      _setSize(tester, Size(width, 800));
      await tester.pumpWidget(_switchingHost());
      await tester.pumpAndSettle();

      expect(find.byKey(_railKey), findsOneWidget);
      expect(find.byType(BottomNav), findsNothing);
    });
  }

  testWidgets('renders the bottom bar, not the rail, at 599', (tester) async {
    _setSize(tester, const Size(599, 800));
    await tester.pumpWidget(_switchingHost());
    await tester.pumpAndSettle();

    expect(find.byKey(_railKey), findsNothing);
    expect(find.byType(BottomNav), findsOneWidget);
  });

  group('rail focus regions (as the shell wires them)', () {
    late FocusNode railRow;
    late FocusNode contentNode;
    late FocusScopeNode railScope;
    late FocusScopeNode contentScope;
    late SidebarFocusBoundary boundary;

    Future<void> pumpShell(WidgetTester tester) async {
      _setSize(tester, const Size(1280, 800));
      railRow = FocusNode(debugLabel: 'sidebar-selected');
      contentNode = FocusNode(debugLabel: 'content');
      railScope = FocusScopeNode(debugLabel: 'sidebar-region');
      contentScope = FocusScopeNode(debugLabel: 'content-region');
      addTearDown(railRow.dispose);
      addTearDown(contentNode.dispose);
      addTearDown(railScope.dispose);
      addTearDown(contentScope.dispose);
      boundary = SidebarFocusBoundary(
        sidebarNode: railRow,
        contentScope: contentScope,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(),
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: Breakpoints.railContentInset(pinned: false),
                      ),
                      child: FocusTraversalGroup(
                        policy: RegionTraversalPolicy(
                          onExit: (direction) =>
                              direction == TraversalDirection.left
                                  ? boundary.focusSidebar()
                                  : false,
                        ),
                        child: FocusScope(
                          node: contentScope,
                          child: Focus(
                            focusNode: contentNode,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: FocusTraversalGroup(
                      policy: RegionTraversalPolicy(
                        onExit: (direction) =>
                            direction == TraversalDirection.right
                                ? boundary.focusContent()
                                : false,
                      ),
                      child: FocusScope(
                        node: railScope,
                        child: FloatingRail(
                          location: '/',
                          onNavigate: (_) {},
                          isOffline: false,
                          selectedRowFocusNode: railRow,
                          onExitRequested: boundary.focusContent,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      contentNode.requestFocus();
      await tester.pumpAndSettle();
    }

    testWidgets('Left at the content edge opens the rail on the selected row',
        (tester) async {
      await pumpShell(tester);
      expect(_railWidth(tester), 72);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      expect(railRow.hasPrimaryFocus, isTrue);
      expect(_railWidth(tester), 272);
    });

    testWidgets('Right returns to the original content node and collapses',
        (tester) async {
      await pumpShell(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(railRow.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(contentNode.hasPrimaryFocus, isTrue);
      expect(_railWidth(tester), 72);
    });

    testWidgets('Up and Down keep focus inside the rail at its ends',
        (tester) async {
      await pumpShell(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      for (var i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      expect(railScope.hasFocus, isTrue);
      expect(contentScope.hasFocus, isFalse);

      for (var i = 0; i < 60; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(railScope.hasFocus, isTrue);
      expect(contentScope.hasFocus, isFalse);
    });
  });
}
