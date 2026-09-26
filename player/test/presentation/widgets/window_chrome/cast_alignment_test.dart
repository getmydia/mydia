// Regression guard for the cast-alignment bug this task fixes: once each
// browse header started drawing its own [WindowTitleRow] into the title-bar
// band instead of going through the shell's floating overlay, the cast
// button had to land at the same trailing offset on every screen, on every
// platform's window chrome. A screen that computed its own gutter (or forgot
// [WindowChromeInsets.removeBand]) would put the cast button somewhere else
// on macOS or Linux even though it lined up on a platform with no window
// chrome, which is exactly the kind of drift a single-screen test cannot
// catch.
//
// Each case below pumps the real widget under macOS, Linux and no-chrome
// insets and checks the cast button's trailing edge directly, rather than
// re-deriving the expected offset from [WindowTitleRow.endGutter] (which
// would only prove the test's own copy of the formula, not the screen's
// wiring to it).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/presentation/screens/collections/collection_detail_screen.dart';
import 'package:player/presentation/screens/downloads/downloads_screen.dart';
import 'package:player/presentation/screens/filter/filter_screen.dart';
import 'package:player/presentation/screens/home_screen.dart';
import 'package:player/presentation/screens/library/library_controller.dart'
    show LibraryType;
import 'package:player/presentation/screens/library/library_screen.dart';
import 'package:player/presentation/screens/library/library_sort.dart';
import 'package:player/presentation/screens/login_screen.dart';
import 'package:player/presentation/screens/settings/devices_screen.dart';
import 'package:player/presentation/screens/settings/diagnostics_screen.dart';
import 'package:player/presentation/screens/settings/settings_screen.dart';
import 'package:player/presentation/widgets/browse_scaffold.dart';
import 'package:player/presentation/widgets/detail_hero_app_bar.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

import '../../../helpers/cast_test_overrides.dart';
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

/// A desktop width, wide enough that every screen shows its desktop chrome
/// (search rows expanded, sidebar-covered leading reserve, etc). At this
/// width `Breakpoints.getHorizontalPadding` is 32, so
/// `WindowTitleRow.endGutter` is `32 - 8 = 24`, the constant every
/// expectation below is built from.
const double _kWidth = 1300;
const double _kEndGutter = 24;

/// The three chrome shapes a screen's title row has to line up under: macOS's
/// traffic lights, a Linux button group (sized for a 3-button decoration
/// layout, mirroring `window_title_row_test.dart`), and no window chrome at
/// all (Windows, web, TV, or a browser tab).
final _cases = <String, WindowChromeInsets>{
  'macOS': const WindowChromeInsets(height: 40, leading: 80, trailing: 0),
  'Linux': WindowChromeInsets(
    height: 36,
    leading: 0,
    trailing: linuxButtonGroupReserve(3),
  ),
  'none': WindowChromeInsets.zero,
};

/// Pumps [child] under [insets], the way `WindowChromeInset` publishes them
/// for real: a `MediaQuery` whose `padding.top` already carries the band (so
/// `WindowChromeInsets.removeBand` inside the screen has something to take
/// back out), and the resolved insets published via
/// [WindowChromeInsets.scope]. Mirrors `window_title_row_test.dart`'s `_pump`
/// helper, which this file cannot import (it is private there).
Future<void> pumpWithInsets(
  WidgetTester tester,
  WindowChromeInsets insets, {
  required double width,
  required Widget child,
  List<Override> extraOverrides = const [],
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [...castCapableOverrides(), ...extraOverrides],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 800),
            padding: EdgeInsets.only(top: insets.height),
          ),
          child: WindowChromeInsets.scope(insets: insets, child: child),
        ),
      ),
    ),
  );
}

/// `FreshnessHeader` renders nothing at all in offline mode, and the real
/// `AuthStateNotifier` reaches for secure storage on build, which a widget
/// test has no business doing. Mirrors `browse_scaffold_test.dart`'s stub.
class _StubAuthState extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);
}

/// A single-movie library page. Every object needs `__typename`, the root
/// included: `gql()` injects a `__typename` selection into every selection
/// set, and the normalized cache refuses to write data that lacks a matching
/// one. Mirrors `library_screen_layout_test.dart`/`filter_screen_test.dart`.
Map<String, dynamic> _moviesPage(List<String> ids) => {
      '__typename': 'Query',
      'movies': {
        '__typename': 'MovieConnection',
        'edges': [
          for (final id in ids)
            {
              '__typename': 'MovieEdge',
              'cursor': 'c-$id',
              'node': {
                '__typename': 'Movie',
                'id': id,
                'title': 'Movie $id',
                'year': 2026,
                'overview': null,
                'runtime': null,
                'genres': <String>[],
                'contentRating': null,
                'rating': null,
                'artwork': {
                  '__typename': 'Artwork',
                  'posterUrl': null,
                  'backdropUrl': null,
                  'thumbnailUrl': null,
                },
                'progress': null,
                'isFavorite': false,
              },
            }
        ],
        'pageInfo': {
          '__typename': 'PageInfo',
          'hasNextPage': false,
          'hasPreviousPage': false,
          'startCursor': 'c-${ids.first}',
          'endCursor': 'c-${ids.last}',
        },
        'totalCount': ids.length,
      },
    };

const _testFilter = FilterDestination(
  id: 'f_alignment',
  label: 'Alignment Filter',
  filter: MediaFilter(
    kind: MediaKind.movies,
    category: null,
    watch: WatchScope.all,
    sort: LibrarySort.defaultSort,
  ),
);

void main() {
  setUp(() {
    // LibraryScreen awaits LibrarySortController, which reads
    // flutter_secure_storage before the screen can query at all.
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('BrowseScaffold cast alignment', () {
    for (final MapEntry(key: name, value: insets) in _cases.entries) {
      testWidgets('aligns on $name', (tester) async {
        await pumpWithInsets(
          tester,
          insets,
          width: _kWidth,
          extraOverrides: [authStateProvider.overrideWith(_StubAuthState.new)],
          child: BrowseScaffold(
            icon: Icons.star,
            title: 'Starlit Shelf',
            queryKeys: const [],
            body: (_, __) => const SizedBox.shrink(),
          ),
        );

        expect(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
          _kWidth - insets.trailing - _kEndGutter,
        );
      });
    }

    testWidgets('the row draws into the band on macOS, not below it',
        (tester) async {
      await pumpWithInsets(
        tester,
        _cases['macOS']!,
        width: _kWidth,
        extraOverrides: [authStateProvider.overrideWith(_StubAuthState.new)],
        child: BrowseScaffold(
          icon: Icons.star,
          title: 'Starlit Shelf',
          queryKeys: const [],
          body: (_, __) => const SizedBox.shrink(),
        ),
      );

      expect(tester.getRect(find.byType(WindowTitleRow)).top, 0);
    });
  });

  group('LibraryScreen cast alignment', () {
    for (final MapEntry(key: name, value: insets) in _cases.entries) {
      testWidgets('aligns on $name', (tester) async {
        await mockNetworkImages(() async {
          await pumpWithInsets(
            tester,
            insets,
            width: _kWidth,
            extraOverrides: [
              asyncGraphqlClientProvider.overrideWith(
                (ref) async => stubClient(StubLink.responses([
                  _moviesPage(['1'])
                ])),
              ),
            ],
            child: const LibraryScreen(libraryType: LibraryType.movies),
          );
          await tester.pumpAndSettle();
        });

        expect(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
          _kWidth - insets.trailing - _kEndGutter,
        );
      });
    }
  });

  group('FilterScreen cast alignment', () {
    for (final MapEntry(key: name, value: insets) in _cases.entries) {
      testWidgets('aligns on $name', (tester) async {
        final store = InMemorySidebarLayoutStore();
        await store.save(SidebarLayout.defaults.withFilter(_testFilter));

        await mockNetworkImages(() async {
          await pumpWithInsets(
            tester,
            insets,
            width: _kWidth,
            extraOverrides: [
              asyncGraphqlClientProvider.overrideWith(
                (ref) async => stubClient(StubLink.responses([
                  _moviesPage(['1'])
                ])),
              ),
              sidebarLayoutStoreProvider.overrideWithValue(store),
            ],
            child: const FilterScreen(filterId: 'f_alignment'),
          );
          await tester.pumpAndSettle();
        });

        expect(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
          _kWidth - insets.trailing - _kEndGutter,
        );
      });
    }
  });

  group('DownloadsScreen cast alignment', () {
    // DownloadsScreen.build stands up the download queue, storage-quota and
    // downloaded-media providers together, which is expensive to satisfy
    // just to check where the cast button lands (Hive boxes, a download
    // manager, ...). `DownloadsScreen.header` is the exact widget `build`
    // puts in `Scaffold.appBar`, extracted as a `@visibleForTesting static`
    // seam for exactly this: it reads only `downloadQueueProvider`.
    for (final MapEntry(key: name, value: insets) in _cases.entries) {
      testWidgets('aligns on $name', (tester) async {
        await pumpWithInsets(
          tester,
          insets,
          width: _kWidth,
          extraOverrides: [
            downloadQueueProvider.overrideWith(
              (ref) => Stream.value(<DownloadTask>[]),
            ),
          ],
          child: Consumer(
            builder: (context, ref, _) => DownloadsScreen.header(context, ref),
          ),
        );

        expect(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
          _kWidth - insets.trailing - _kEndGutter,
        );
      });
    }
  });

  group('HomeScreen cast alignment', () {
    // HomeScreen.build wires up homeControllerProvider, a GraphQL-backed
    // stream. `HomeScreen.header` is the exact widget `build` puts in
    // `Scaffold.appBar`, extracted as a `@visibleForTesting static` seam that
    // needs no providers at all: the cast button is `WindowTitleRow`'s own.
    for (final MapEntry(key: name, value: insets) in _cases.entries) {
      testWidgets('aligns on $name', (tester) async {
        await pumpWithInsets(
          tester,
          insets,
          width: _kWidth,
          child: Builder(
            builder: (context) => HomeScreen.header(
              context,
              isDesktop: true,
              barHeight: WindowTitleRow.heightOf(context),
            ),
          ),
        );

        expect(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
          _kWidth - insets.trailing - _kEndGutter,
        );
      });
    }

    testWidgets(
        'on mobile, the search action is present and the cast button is '
        'the last control', (tester) async {
      // Title row includes the DEV pill beside the wordmark in debug builds.
      const width = 480.0;
      await pumpWithInsets(
        tester,
        WindowChromeInsets.zero,
        width: width,
        child: Builder(
          builder: (context) => Scaffold(
            appBar: HomeScreen.header(
              context,
              isDesktop: false,
              barHeight: WindowTitleRow.heightOf(context),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.byTooltip('Search'), findsOneWidget);
      expect(
        tester.getRect(find.byTooltip('Search')).right,
        lessThanOrEqualTo(
            tester.getRect(find.byKey(WindowTitleRow.castKey)).left),
      );
      expect(
        tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
        width - 8,
      );
    });
  });

  group('SettingsScreen cast alignment', () {
    // SettingsScreen.build wires up settingsControllerProvider,
    // connectionProvider, p2pStatusNotifierProvider (a real native P2P node)
    // and updateProvider. `SettingsScreen.header` is the exact widget `build`
    // puts in `Scaffold.appBar`, extracted as a `@visibleForTesting static`
    // seam that needs no providers at all: the cast button is
    // `WindowTitleRow`'s own.
    for (final MapEntry(key: name, value: insets) in _cases.entries) {
      testWidgets('aligns on $name', (tester) async {
        await pumpWithInsets(
          tester,
          insets,
          width: _kWidth,
          child: const Builder(builder: SettingsScreen.header),
        );

        expect(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
          _kWidth - insets.trailing - _kEndGutter,
        );
      });
    }
  });

  group('CollectionDetailScreen cast alignment', () {
    // CollectionDetailScreen.build watches
    // collectionDetailControllerProvider(id), a GraphQL-backed stream.
    // `CollectionDetailScreen.header` is the exact widget `build` puts in
    // `Scaffold.appBar`, extracted as a `@visibleForTesting static` seam that
    // takes the already-resolved items rather than watching the provider
    // itself. The cast button is new on this screen (it never had one
    // before), which is exactly what this loop guards.
    for (final MapEntry(key: name, value: insets) in _cases.entries) {
      testWidgets('aligns on $name', (tester) async {
        await pumpWithInsets(
          tester,
          insets,
          width: _kWidth,
          child: Builder(
            builder: (context) => CollectionDetailScreen.header(
              context,
              id: 'c1',
              itemsData: const AsyncValue.data(<RecentlyAddedItem>[]),
            ),
          ),
        );

        expect(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
          _kWidth - insets.trailing - _kEndGutter,
        );
      });
    }
  });

  group('detailHeroAppBar cast alignment', () {
    // The movie, show and episode detail screens all build their hero via
    // `detailHeroAppBar` rather than a `Scaffold.appBar` seam, so there is no
    // per-screen `.header` to pump here. `detailHeroAppBar` itself is the
    // seam: it needs no provider graph, and it is the exact sliver each of
    // those three screens puts first in its `CustomScrollView`. Those
    // screens own `WindowChromeInsets.removeBand` themselves (they are
    // full-window routes), so this test reproduces that wrapping rather than
    // relying on `pumpWithInsets`, which -- unlike the browse screens above
    // -- never adds it for a bare sliver.
    for (final MapEntry(key: name, value: insets) in _cases.entries) {
      testWidgets('aligns on $name', (tester) async {
        await pumpWithInsets(
          tester,
          insets,
          width: _kWidth,
          child: WindowChromeInsets.removeBand(
            child: Builder(
              builder: (context) => Scaffold(
                body: CustomScrollView(
                  slivers: [
                    detailHeroAppBar(
                      context: context,
                      expandedHeight: 380,
                      back: const SizedBox.shrink(),
                      background: const ColoredBox(color: Colors.blue),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        expect(
          tester.getRect(find.byKey(WindowTitleRow.castKey)).right,
          _kWidth - insets.trailing - _kEndGutter,
        );
      });
    }
  });

  group('DevicesScreen title row', () {
    // Devices is a full-window route (pushed outside the shell), so it owns
    // `Scaffold.appBar` itself rather than going through a seam: nothing here
    // reads a GraphQL stream during the build that constructs the row.
    testWidgets(
        'draws into the band on macOS, with no cast button (there never was '
        'one)', (tester) async {
      await pumpWithInsets(
        tester,
        _cases['macOS']!,
        width: _kWidth,
        child: const DevicesScreen(),
      );

      expect(find.byKey(WindowTitleRow.castKey), findsNothing);
      expect(tester.getRect(find.byType(WindowTitleRow)).top, 0);
    });
  });

  group('DiagnosticsScreen title row', () {
    // Diagnostics is a full-window route (pushed outside the shell), so it
    // owns `Scaffold.appBar` itself rather than going through a seam: nothing
    // here reads a GraphQL stream during the build that constructs the row.
    testWidgets(
        'draws into the band on macOS, with no cast button (there never was '
        'one)', (tester) async {
      await pumpWithInsets(
        tester,
        _cases['macOS']!,
        width: _kWidth,
        child: const DiagnosticsScreen(),
      );

      expect(find.byKey(WindowTitleRow.castKey), findsNothing);
      expect(tester.getRect(find.byType(WindowTitleRow)).top, 0);
    });
  });

  group('LoginScreen title row', () {
    // LoginScreen has no `Scaffold.appBar` slot to put a row in (the card
    // layout has nowhere to host one), so it overlays a bare `WindowTitleRow`
    // instead, just to keep the window draggable and the corners clear.
    // There is no signed-in device yet to cast to, hence no cast button.
    testWidgets('draws a bare row on macOS with no cast button',
        (tester) async {
      await pumpWithInsets(
        tester,
        _cases['macOS']!,
        width: _kWidth,
        extraOverrides: [
          authServiceProvider
              .overrideWithValue(AuthService(storage: MockAuthStorage())),
        ],
        child: const LoginScreen(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(WindowTitleRow), findsOneWidget);
      expect(find.byKey(WindowTitleRow.castKey), findsNothing);
    });
  });
}
