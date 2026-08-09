import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/downloads/download_service.dart'
    show isDownloadSupported;
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
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
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
            height: 1400,
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

  test('reorder preserves hidden middle ids in stored order', () async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    final container = ProviderContainer(
      overrides: [sidebarLayoutStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await container.read(sidebarLayoutProvider.future);

    final layoutBefore = store.get()!;
    final middleBefore = layoutBefore.order
        .where(
          (id) => id != 'search' && id != 'downloads' && id != 'settings',
        )
        .toList();
    final collectionsIndexBefore = middleBefore.indexOf('collections');
    expect(collectionsIndexBefore, greaterThan(0));
    final neighborBefore = middleBefore[collectionsIndexBefore - 1];

    final visibleMiddle =
        (await container.read(sidebarDestinationsProvider.future))
            .where((d) => !d.isAnchored)
            .map((d) => d.id)
            .toList();
    final moviesIndex = visibleMiddle.indexOf('movies');

    final newOrder = SidebarContent.orderAfterMiddleReorder(
      layout: layoutBefore,
      visibleMiddleIds: visibleMiddle,
      oldIndex: moviesIndex,
      newIndex: 0,
      downloadSupported: isDownloadSupported,
    );

    await container.read(sidebarLayoutControllerProvider).reorder(newOrder);

    final layoutAfterReorder = store.get()!;
    expect(layoutAfterReorder.order, contains('collections'));
    expect(layoutAfterReorder.hidden, contains('collections'));

    final middleAfterReorder = layoutAfterReorder.order
        .where(
          (id) => id != 'search' && id != 'downloads' && id != 'settings',
        )
        .toList();
    expect(
      middleAfterReorder.indexOf('collections'),
      collectionsIndexBefore,
    );
    expect(middleAfterReorder[collectionsIndexBefore - 1], neighborBefore);

    await container.read(sidebarLayoutControllerProvider).unhide('collections');

    final destinations =
        await container.read(sidebarDestinationsProvider.future);
    expect(destinations.map((d) => d.id), contains('collections'));

    final middleAfterUnhide = store
        .get()!
        .order
        .where(
          (id) => id != 'search' && id != 'downloads' && id != 'settings',
        )
        .toList();
    expect(
      middleAfterUnhide.indexOf('collections'),
      collectionsIndexBefore,
    );
    expect(middleAfterUnhide[collectionsIndexBefore - 1], neighborBefore);
  });
}
