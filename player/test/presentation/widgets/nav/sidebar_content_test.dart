import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/presentation/widgets/nav/sidebar_content.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

class _StubConnectionNotifier extends ConnectionNotifier {
  @override
  ConnectionState build() => ConnectionState.direct();
}

Future<void> _pump(
  WidgetTester tester, {
  required String location,
  SidebarLayoutStore? store,
  void Function(String)? onNavigate,
  bool isOffline = false,
  double height = 1400,
}) async {
  tester.view.physicalSize = Size(1200, height + 200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(_StubConnectionNotifier.new),
        sidebarLayoutStoreProvider
            .overrideWithValue(store ?? InMemorySidebarLayoutStore()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: height,
            child: SidebarContent(
              location: location,
              onNavigate: onNavigate ?? (_) {},
              isOffline: isOffline,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the default destinations flat, with no expander',
      (tester) async {
    await _pump(tester, location: '/');

    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('TV Shows'), findsOneWidget);
    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // The old tree's chevron is gone, and so is the Library group header.
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    expect(find.text('Library'), findsNothing);
  });

  testWidgets('does not overflow on a short viewport', (tester) async {
    // The flat list renders every destination at once where the old tree kept
    // Library collapsed, so it is materially taller than what it replaced. A
    // laptop-height sidebar overflowed by ~100px and the render library threw,
    // which only the E2E job caught because every widget test here had been
    // pumping a 1400px column. The anchors stay pinned and the middle scrolls.
    await _pump(tester, location: '/', height: 500);

    expect(tester.takeException(), isNull);

    // Both bottom anchors stay on screen rather than scrolling away. Settings
    // in particular is the only route back from a hidden destination.
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
  });

  testWidgets('a hidden destination is not rendered', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);

    expect(find.text('Collections'), findsNothing);
    expect(find.text('Movies'), findsOneWidget);
  });

  testWidgets('the most specific destination wins the selection',
      (tester) async {
    await _pump(tester, location: '/favorites');

    final favorites = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Favorites'),
    );
    final home = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Home'),
    );

    expect(favorites.isSelected, isTrue);
    expect(home.isSelected, isFalse);
  });

  testWidgets('tapping a destination navigates', (tester) async {
    final routes = <String>[];
    await _pump(tester, location: '/', onNavigate: routes.add);

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();

    expect(routes, ['/movies']);
  });

  testWidgets('anchored rows offer no hide action', (tester) async {
    await _pump(tester, location: '/');

    final settings = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Settings'),
    );
    expect(settings.canCustomise, isFalse);

    final movies = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Movies'),
    );
    expect(movies.canCustomise, isTrue);
  });

  testWidgets('offline disables server-backed rows but not Downloads',
      (tester) async {
    await _pump(tester, location: '/', isOffline: true);

    final movies = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Movies'),
    );
    expect(movies.isDisabled, isTrue);

    final downloads = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Downloads'),
    );
    expect(downloads.isDisabled, isFalse);
  });

  testWidgets('the header offers an edit control', (tester) async {
    await _pump(tester, location: '/');

    expect(find.byTooltip('Edit sidebar'), findsOneWidget);
    expect(find.text('Editing'), findsNothing);
  });

  testWidgets('tapping edit reveals grips and hidden rows', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);
    expect(find.text('Collections'), findsNothing);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    expect(find.text('Editing'), findsOneWidget);
    expect(find.text('Collections'), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsWidgets);
  });

  testWidgets('a row tap does not navigate while editing', (tester) async {
    final routes = <String>[];
    await _pump(tester, location: '/', onNavigate: routes.add);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();

    expect(routes, isEmpty);
  });

  testWidgets('Done leaves edit mode', (tester) async {
    await _pump(tester, location: '/');

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();
    expect(find.text('Editing'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Editing'), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNothing);
  });

  testWidgets('the New filter row is hidden while editing', (tester) async {
    await _pump(tester, location: '/');
    expect(find.text('+ New filter'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    expect(find.text('+ New filter'), findsNothing);
  });

  testWidgets('restoring a hidden row unhides it', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Restore Collections'));
    await tester.pumpAndSettle();

    expect(store.get()!.hidden, isNot(contains('collections')));
  });

  testWidgets('edit mode offers no reset until it can confirm', (tester) async {
    await _pump(tester, location: '/');

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Reset sidebar'), findsNothing);
  });
}
