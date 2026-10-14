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
import 'package:player/core/focus/sidebar_focus_boundary.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/cast_bar/dock_extents.dart';
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
              // The shell's own layer builder, so a miswired region, swapped
              // direction or dropped `onExitRequested` fails here.
              body: AppShell.railLayers(
                regionsEnabled: true,
                contentLeft: Breakpoints.railContentInset(pinned: false),
                railScope: railScope,
                contentScope: contentScope,
                boundary: boundary,
                content: Focus(
                  focusNode: contentNode,
                  child: const SizedBox.expand(),
                ),
                railBuilder: (onExitRequested) => FloatingRail(
                  location: '/',
                  onNavigate: (_) {},
                  isOffline: false,
                  selectedRowFocusNode: railRow,
                  onExitRequested: onExitRequested,
                ),
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

      final stops = railScope.traversalDescendants
          .where((n) => n.canRequestFocus && n.context != null)
          .toList()
        ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
      expect(stops.length, greaterThan(1));
      // Captured now: the list scrolls as focus moves, which shifts rects.
      final firstTop = stops.first.rect.top;
      final lastTop = stops.last.rect.top;
      final firstRow = stops.where((n) => n.rect.top == firstTop).toList();
      final lastRow = stops.where((n) => n.rect.top == lastTop).toList();

      for (var i = 0; i < stops.length + 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      // A row can nest more than one focus node, so "is that row" means the
      // focused node is, or is nested with, one of the stops at that end.
      bool onRow(Iterable<FocusNode> row) {
        final primary = FocusManager.instance.primaryFocus!;
        return row.any((n) =>
            n == primary ||
            primary.ancestors.contains(n) ||
            n.ancestors.contains(primary));
      }

      expect(onRow(firstRow), isTrue);
      expect(contentScope.hasFocus, isFalse);

      for (var i = 0; i < stops.length + 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(onRow(lastRow), isTrue);
      expect(contentScope.hasFocus, isFalse);
    });
  });

  testWidgets('the rail and content column clear the safe area',
      (tester) async {
    _setSize(tester, const Size(1280, 800));
    final reported = <double>[];
    final railScope = FocusScopeNode();
    final contentScope = FocusScopeNode();
    final railRow = FocusNode();
    addTearDown(railScope.dispose);
    addTearDown(contentScope.dispose);
    addTearDown(railRow.dispose);
    const contentKey = Key('safe-area-content');

    Future<void> pumpWith(EdgeInsets padding) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(),
          child: MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: const Size(1280, 800),
                  padding: padding,
                ),
                child: DockExtents(
                  dock: 0,
                  castBar: 0,
                  sidebar: 0,
                  drawerOpen: false,
                  onDock: (_) {},
                  onSidebar: reported.add,
                  onCastBar: (_) {},
                  onDrawer: (_) {},
                  child: AppShell.railLayers(
                    regionsEnabled: true,
                    contentLeft: Breakpoints.railContentInset(pinned: false),
                    railScope: railScope,
                    contentScope: contentScope,
                    boundary: SidebarFocusBoundary(
                      sidebarNode: railRow,
                      contentScope: contentScope,
                    ),
                    content: const SizedBox.expand(key: contentKey),
                    railBuilder: (onExitRequested) => FloatingRail(
                      location: '/',
                      onNavigate: (_) {},
                      isOffline: false,
                      selectedRowFocusNode: railRow,
                      onExitRequested: onExitRequested,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpWith(EdgeInsets.zero);
    final baseContentLeft = tester.getTopLeft(find.byKey(contentKey)).dx;
    expect(tester.getTopLeft(find.byKey(_railKey)).dx, 16);
    expect(tester.getBottomLeft(find.byKey(_railKey)).dy, 800 - 16);
    expect(reported.last, Breakpoints.railContentInset(pinned: false));

    await pumpWith(const EdgeInsets.only(left: 44, bottom: 21));
    expect(tester.getTopLeft(find.byKey(_railKey)).dx, 16 + 44);
    expect(tester.getBottomLeft(find.byKey(_railKey)).dy, 800 - 21 - 16);
    expect(tester.getTopLeft(find.byKey(contentKey)).dx, baseContentLeft + 44);
    expect(reported.last, Breakpoints.railContentInset(pinned: false) + 44);
  });

  testWidgets('sidebarChrome reports the pinned rail footprint (312)',
      (tester) async {
    final reported = <double>[];
    await tester.pumpWidget(
      DockExtents(
        dock: 0,
        castBar: 0,
        sidebar: 0,
        drawerOpen: false,
        onDock: (_) {},
        onSidebar: reported.add,
        onCastBar: (_) {},
        onDrawer: (_) {},
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: AppShell.sidebarChrome(
              child: SizedBox(
                width: Breakpoints.railContentInset(pinned: true),
                height: 100,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(reported.last, 312);
  });
}
