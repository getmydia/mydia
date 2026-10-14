import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/domain/navigation/source_nav.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';

import '../../screens/sources/fake_capable_source.dart';
import '../../screens/sources/fake_media_source.dart';

Future<List<String>> _pump(
  WidgetTester tester, {
  bool withMovies = true,
  bool downloadSupported = true,
  bool isOffline = false,
  bool showBackToMydia = false,
}) async {
  final source = FakeCapableSource();
  final libraries = [
    for (final l in await source.libraries())
      if (withMovies || l.kind != LibraryKind.movies) l,
  ];
  final layout = SidebarLayout.defaults.reconcile(downloadSupported: true);
  final entries = bottomNavEntries(
    resolveSourceNav(
      layout: layout,
      source: fakeSourceId,
      capabilities: source.capabilities,
      libraries: libraries,
    ),
    downloadSupported: downloadSupported,
  );
  final navigations = <String>[];
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        bottomNavigationBar: BottomNav(
          location: '/s/${fakeSourceId.value}',
          onNavigate: navigations.add,
          entries: entries,
          isOffline: isOffline,
          showBackToMydia: showBackToMydia,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return navigations;
}

const _home = SourceNavEntry(
  id: 'home',
  label: 'Home',
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
  route: '/s/x',
);
const _movies = SourceNavEntry(
  id: 'movies',
  label: 'Movies',
  icon: Icons.movie_outlined,
  selectedIcon: Icons.movie,
  route: '/s/x/library/movies',
);
const _lib4k = SourceNavEntry(
  id: 'lib-4k',
  label: 'Movies 4K',
  icon: Icons.movie_outlined,
  selectedIcon: Icons.movie,
  route: '/s/x/library/4k',
);
const _kids = SourceNavEntry(
  id: 'lib-kids',
  label: 'Kids',
  icon: Icons.child_care,
  selectedIcon: Icons.child_care,
  route: '/s/x/library/kids',
);
const _docs = SourceNavEntry(
  id: 'lib-docs',
  label: 'Documentaries',
  icon: Icons.theaters_outlined,
  selectedIcon: Icons.theaters,
  route: '/s/x/library/docs',
);

Future<List<String>> _pumpBar(
  WidgetTester tester, {
  List<SourceNavEntry> libraryEntries = const [],
  EdgeInsets padding = EdgeInsets.zero,
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final navigations = <String>[];
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(padding: padding),
        child: child!,
      ),
      home: Scaffold(
        bottomNavigationBar: BottomNav(
          location: '/s/x',
          onNavigate: navigations.add,
          entries: const [_home, _movies],
          libraryEntries: libraryEntries,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return navigations;
}

void main() {
  testWidgets('the bar is a 24 px glass pill floating 12 px off the edges',
      (tester) async {
    await _pumpBar(tester, padding: const EdgeInsets.only(bottom: 34));
    final glass = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(glass.borderRadius, BorderRadius.circular(AppTheme.radiusBottomBar));
    final rect = tester.getRect(find.byType(GlassSurface));
    expect(rect.bottom, 800 - 34 - 12);
    expect(rect.left, 12);
    expect(rect.right, 400 - 12);
  });

  testWidgets('long-press on Home lists the libraries; tapping one navigates',
      (tester) async {
    final navigations =
        await _pumpBar(tester, libraryEntries: const [_lib4k, _kids, _docs]);
    await tester.longPress(find.text('Home'));
    await tester.pumpAndSettle();
    for (final label in ['Movies 4K', 'Kids', 'Documentaries']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.byKey(const ValueKey('library-sheet-lib-kids')));
    await tester.pumpAndSettle();
    expect(navigations, ['/s/x/library/kids']);
    expect(find.text('Documentaries'), findsNothing);
  });

  testWidgets('long-press on Home does nothing without library entries',
      (tester) async {
    await _pumpBar(tester);
    await tester.longPress(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Libraries'), findsNothing);
  });

  testWidgets('a long library list scrolls inside a short landscape sheet',
      (tester) async {
    final many = [
      for (var i = 0; i < 15; i++)
        SourceNavEntry(
          id: 'lib-$i',
          label: 'Library $i',
          icon: Icons.folder_outlined,
          selectedIcon: Icons.folder,
          route: '/s/x/library/$i',
        ),
    ];
    final navigations = await _pumpBar(
      tester,
      libraryEntries: many,
      size: const Size(800, 400),
    );
    await tester.longPress(find.text('Home'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final last = find.byKey(const ValueKey('library-sheet-lib-14'));
    await tester.scrollUntilVisible(last, 100,
        scrollable: find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        ));
    // scrollUntilVisible stops once the row's edge shows; bring all of it in.
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(navigations, ['/s/x/library/14']);
  });

  test('libraryNavEntries drops anchored entries and the bar ids', () {
    const anchored = SourceNavEntry(
      id: 'search',
      label: 'Search',
      icon: Icons.search,
      selectedIcon: Icons.search,
      route: '/s/x/search',
      anchored: true,
    );
    expect(
      libraryNavEntries([_home, _movies, anchored, _lib4k, _kids]),
      [_lib4k, _kids],
    );
  });

  testWidgets('shows Home, Movies, Shows, Downloads and Settings',
      (tester) async {
    final navigations = await _pump(tester);
    for (final label in ['Home', 'Movies', 'Shows', 'Downloads', 'Settings']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Movies'));
    expect(navigations, ['/s/${fakeSourceId.value}/library/movies']);
  });

  testWidgets('a source without a movies library has no Movies item',
      (tester) async {
    await _pump(tester, withMovies: false);
    expect(find.text('Movies'), findsNothing);
    expect(find.text('Shows'), findsOneWidget);
  });

  testWidgets(
      'Favorites takes the Downloads slot where downloads are '
      'unsupported', (tester) async {
    await _pump(tester, downloadSupported: false);
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('Favorites'), findsOneWidget);
  });

  group('narrow phones', () {
    for (final width in [320.0, 360.0, 400.0, 599.0]) {
      for (final back in [true, false]) {
        testWidgets('fits every item at $width px, back to Mydia $back',
            (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await _pump(tester, showBackToMydia: back);

          expect(tester.takeException(), isNull);
          final bar = tester.getRect(find.byType(GlassSurface).first);
          final items = find.byType(NavItem);
          expect(items, findsNWidgets(back ? 6 : 5));
          for (final element in items.evaluate()) {
            final rect = tester.getRect(find.byWidget(element.widget));
            expect(rect.left, greaterThanOrEqualTo(bar.left));
            expect(rect.right, lessThanOrEqualTo(bar.right));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
          }
        });
      }
    }

    testWidgets('icon-only items keep their names as tooltips', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final navigations = await _pump(tester, showBackToMydia: true);

      expect(find.text('Settings'), findsNothing);
      for (final label in ['Mydia', 'Home', 'Movies', 'Settings']) {
        expect(find.byTooltip(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.byTooltip('Movies'));
      expect(navigations, ['/s/${fakeSourceId.value}/library/movies']);
    });

    testWidgets('labels stay where each item has room for one', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pump(tester, showBackToMydia: true);

      for (final label in ['Mydia', 'Home', 'Downloads', 'Settings']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });
  });
}
