// Movie, show, season and episode pages render inside the shell's routed
// child, so the rail (or the phone bottom bar) stays beside them. The real
// `AppShell` needs the authenticated provider graph, so the behaviour tests
// mount the real `sourceDetailRoutes()` in a `ShellRoute` shaped like
// `appRouter`'s, with a marker standing in for the shell chrome. The
// structural test reads the real `appRouter` so the two cannot drift.

import 'dart:async';

import 'package:flutter/material.dart' hide Page;
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/router/detail_location.dart';
import 'package:player/core/router/navigator_keys.dart';
import 'package:player/core/router/push_route.dart';
import 'package:player/core/router/shell_pages.dart';
import 'package:player/core/router/source_detail_routes.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/sources/library.dart' show Page;
import 'package:player/presentation/screens/collections/collection_detail_screen.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/screens/show/show_detail_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../presentation/screens/sources/fake_capable_source.dart';
import '../../presentation/screens/sources/fake_media_source.dart';
import '../../test_utils/mock_auth_storage.dart';
import '../../test_utils/toast_harness.dart';

final _id = fakeSourceId.value;

const _shellKey = Key('test-shell');
const _homeKey = Key('test-home');
const _playerKey = Key('test-player');
const _rootPageKey = Key('test-root-page');
const _formKey = Key('test-form');
const _dialogKey = Key('test-dialog');

final _detailNames = {
  'source_movie_detail',
  'source_show_detail',
  'source_season_detail',
  'source_episode_detail',
};

/// The location the shell builder saw on its last build, which is what the
/// real `AppShell` is given as `location`.
String? _shellLocation;

/// The location of the page on top, as `AppShell` reads it to decide whether
/// the page runs under the rail.
String? _topLocation;

/// Reads the top page's location the way `AppShell` does: it listens to the
/// router delegate, because a push does not rebuild the shell route's builder.
class _TopProbe extends StatefulWidget {
  const _TopProbe({required this.child});
  final Widget child;

  @override
  State<_TopProbe> createState() => _TopProbeState();
}

class _TopProbeState extends State<_TopProbe> {
  GoRouter? _router;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _router?.routerDelegate.removeListener(_changed);
    _router = GoRouter.of(context)..routerDelegate.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _topLocation = _router?.state.uri.toString();
    return widget.child;
  }
}

Future<GoRouter> _pumpShellRouter(
  WidgetTester tester, {
  String initialLocation = '/',
  FakeMediaSource? source,
}) async {
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          _shellLocation = state.matchedLocation;
          return _TopProbe(
            child: Column(
              key: _shellKey,
              children: [Expanded(child: child)],
            ),
          );
        },
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const SizedBox(key: _homeKey),
          ),
          // The real route definitions, as `appRouter` registers them.
          sourceCollectionRoute(),
          ...sourceDetailRoutes(),
        ],
      ),
      GoRoute(
        path: '/root-page',
        name: 'root_page',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) =>
            const Scaffold(body: SizedBox(key: _rootPageKey)),
      ),
      // Named as in `appRouter`, which is what `pushRouteSafely` goes by.
      GoRoute(
        path: '/sources/add',
        name: 'add_source',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) =>
            const Scaffold(body: SizedBox(key: _formKey)),
      ),
      GoRoute(
        path: '/s/:sourceId/player/:itemId',
        name: 'source_player',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) =>
            const Scaffold(body: SizedBox(key: _playerKey)),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId)
          .overrideWithValue(source ?? FakeMediaSource()),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      builder: toastLayerBuilder,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  ));
  await tester.pumpAndSettle();
  return router;
}

Finder _inShell(Finder f) =>
    find.descendant(of: find.byKey(_shellKey), matching: f);

Set<String> _names(List<RouteBase> routes) => {
      for (final r in routes)
        if (r is GoRoute && r.name != null) r.name!,
    };

void main() {
  test('the real router registers the detail routes inside its ShellRoute', () {
    final container = ProviderContainer(overrides: [
      sidebarLayoutStoreProvider
          .overrideWithValue(InMemorySidebarLayoutStore()),
      sourceStoreProvider.overrideWith((ref) async => InMemorySourceStore()),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
      authServiceProvider
          .overrideWithValue(AuthService(storage: MockAuthStorage())),
    ]);
    addTearDown(container.dispose);
    final router = container.read(appRouterProvider);

    final top = router.configuration.routes;
    final shell = top.whereType<ShellRoute>().single;

    // Every full-bleed name is a route the shell really has, so a rename
    // cannot silently inset a page that paints under the rail.
    expect(_names(shell.routes).containsAll(fullBleedShellRoutes), isTrue);
    // The collection page opens items by push, so it shares their navigator.
    final shellPages = {..._detailNames, 'source_collection'};
    expect(_names(shell.routes).containsAll(shellPages), isTrue);
    expect(_names(top).intersection(shellPages), isEmpty);
    expect(_names(top).intersection(_detailNames), isEmpty);
    // The player stays immersive, above the shell.
    expect(_names(top), contains('source_player'));
    expect(_names(shell.routes), isNot(contains('source_player')));
    for (final route in shell.routes.whereType<GoRoute>()) {
      if (_detailNames.contains(route.name)) {
        expect(route.parentNavigatorKey, isNull, reason: route.name);
      }
    }
  });

  testWidgets('a detail location renders inside the shell', (tester) async {
    await _pumpShellRouter(tester, initialLocation: '/s/$_id/movie/m1');
    expect(_inShell(find.byType(MovieDetailScreen)), findsOneWidget);
    expect(_shellLocation, '/s/$_id/movie/m1');
  });

  testWidgets('a show detail location renders inside the shell',
      (tester) async {
    await _pumpShellRouter(tester, initialLocation: '/s/$_id/show/s1');
    expect(_inShell(find.byType(ShowDetailScreen)), findsOneWidget);
  });

  testWidgets('a season detail location renders its show inside the shell',
      (tester) async {
    await _pumpShellRouter(tester, initialLocation: '/s/$_id/season/se1');
    expect(_inShell(find.byType(ShowDetailScreen)), findsOneWidget);
  });

  testWidgets('a detail page pushed from home keeps the shell and Back returns',
      (tester) async {
    final router = await _pumpShellRouter(tester);
    expect(_inShell(find.byKey(_homeKey)), findsOneWidget);

    final target = '/s/$_id/movie/m1';
    unawaited(router.push<void>(target));
    await tester.pumpAndSettle();

    expect(_inShell(find.byType(MovieDetailScreen)), findsOneWidget);
    expect(router.state.uri.path, target);
    // A pushed page leaves the shell on the location it was opened from, so
    // the rail keeps that row selected without any help. (A `go` or a deep
    // link names the detail location instead; `shellNavLocation` covers it.)
    expect(_shellLocation, '/');
    // The shell still learns which page is on top, which is how it lets a
    // detail page run its art under the rail.
    expect(isDetailLocation(_topLocation!), isTrue);

    // The in-page back button pops, it does not go home.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(MovieDetailScreen), findsNothing);
    expect(_inShell(find.byKey(_homeKey)), findsOneWidget);
    expect(router.state.uri.path, '/');
    expect(_shellLocation, '/');
    expect(isDetailLocation(_topLocation!), isFalse);
  });

  testWidgets('Back works through the navigator for browser and Android back',
      (tester) async {
    final router = await _pumpShellRouter(tester);
    unawaited(router.push<void>('/s/$_id/show/s1'));
    await tester.pumpAndSettle();
    expect(_inShell(find.byType(ShowDetailScreen)), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(ShowDetailScreen), findsNothing);
    expect(_inShell(find.byKey(_homeKey)), findsOneWidget);
  });

  testWidgets('the player opened from a detail page sits above the shell',
      (tester) async {
    final router = await _pumpShellRouter(tester);
    unawaited(router.push<void>('/s/$_id/movie/m1'));
    await tester.pumpAndSettle();
    unawaited(router.push<void>(sourcePlayerLocation(fakeMovie(1).ref)));
    await tester.pumpAndSettle();

    expect(find.byKey(_playerKey), findsOneWidget);
    expect(_inShell(find.byKey(_playerKey)), findsNothing);

    // Popping the player lands back on the detail page, still in the shell.
    router.pop();
    await tester.pumpAndSettle();
    expect(_inShell(find.byType(MovieDetailScreen)), findsOneWidget);
  });

  testWidgets('a collection page opens an item in the shell and Back returns',
      (tester) async {
    // The real collection route and screen: it opens the item with `push`.
    final source = FakeCapableSource()
      ..collectionItemPages = [
        Page(items: [fakeMovie(1)])
      ];
    final router = await _pumpShellRouter(tester, source: source);
    router.go('/s/$_id/collection/c1');
    await tester.pumpAndSettle();
    expect(_inShell(find.byType(CollectionDetailScreen)), findsOneWidget);

    await tester.tap(find.text('Invented Film 1'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_inShell(find.byType(MovieDetailScreen)), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_inShell(find.byType(CollectionDetailScreen)), findsOneWidget);
    expect(router.state.uri.path, '/s/$_id/collection/c1');
  });

  group('pushRouteSafely with a root page above the shell', () {
    final detail = '/s/$_id/movie/m1';

    testWidgets('closes a plain root page, shows the detail page, Back returns',
        (tester) async {
      final router = await _pumpShellRouter(tester);
      unawaited(router.push<void>('/root-page'));
      await tester.pumpAndSettle();
      expect(find.byKey(_rootPageKey), findsOneWidget);
      expect(rootRouteIsOnTop(), isTrue);

      expect(
          pushRouteSafely(router, detail), PushOutcome.pushedAfterClosingPages);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(_rootPageKey), findsNothing);
      expect(_inShell(find.byType(MovieDetailScreen)), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(MovieDetailScreen), findsNothing);
      expect(_inShell(find.byKey(_homeKey)), findsOneWidget);
    });

    testWidgets('pushes plainly when nothing is above the shell',
        (tester) async {
      final router = await _pumpShellRouter(tester);
      expect(rootRouteIsOnTop(), isFalse);

      pushRouteSafely(router, '/s/$_id/movie/m1');
      await tester.pumpAndSettle();
      expect(_inShell(find.byType(MovieDetailScreen)), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(_inShell(find.byKey(_homeKey)), findsOneWidget);
    });

    testWidgets('a dialog is left open: it does not stop the push',
        (tester) async {
      final router = await _pumpShellRouter(tester);
      final context = rootNavigatorKey.currentContext!;
      unawaited(showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(key: _dialogKey),
      ));
      await tester.pumpAndSettle();
      expect(rootRouteIsOnTop(), isFalse, reason: 'a dialog is not a page');

      expect(pushRouteSafely(router, detail), PushOutcome.pushed);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(_dialogKey), findsOneWidget);
      expect(_inShell(find.byType(MovieDetailScreen)), findsOneWidget);
    });

    testWidgets('a dialog over a root page: nothing opens, both stay',
        (tester) async {
      final router = await _pumpShellRouter(tester);
      unawaited(router.push<void>('/root-page'));
      await tester.pumpAndSettle();
      unawaited(showDialog<void>(
        context: rootNavigatorKey.currentContext!,
        builder: (_) => const AlertDialog(key: _dialogKey),
      ));
      await tester.pumpAndSettle();

      expect(pushRouteSafely(router, detail), PushOutcome.blockedByForm);
      await tester.pumpAndSettle();
      expect(find.byKey(_dialogKey), findsOneWidget);
      expect(find.byKey(_rootPageKey), findsOneWidget);
      expect(find.byType(MovieDetailScreen), findsNothing);
    });

    testWidgets('the player is never closed: nothing opens, with a message',
        (tester) async {
      final router = await _pumpShellRouter(tester);
      unawaited(router.push<void>(sourcePlayerLocation(fakeMovie(1).ref)));
      await tester.pumpAndSettle();
      expect(find.byKey(_playerKey), findsOneWidget);

      final outcome = pushRouteSafely(router, detail);
      await tester.pumpAndSettle();

      expect(outcome, PushOutcome.blockedByPlayer);
      expect(AppLocalizationsEn().pushOutcomeMessage(outcome), isNotNull);
      expect(find.byKey(_playerKey), findsOneWidget);
      expect(find.byType(MovieDetailScreen), findsNothing);
    });

    testWidgets('a form is never closed: nothing opens, with a message',
        (tester) async {
      final router = await _pumpShellRouter(tester);
      unawaited(router.push<void>('/sources/add'));
      await tester.pumpAndSettle();
      expect(find.byKey(_formKey), findsOneWidget);

      final outcome = pushRouteSafely(router, detail);
      await tester.pumpAndSettle();

      expect(outcome, PushOutcome.blockedByForm);
      expect(AppLocalizationsEn().pushOutcomeMessage(outcome), isNotNull);
      expect(find.byKey(_formKey), findsOneWidget);
      expect(find.byType(MovieDetailScreen), findsNothing);
    });

    testWidgets('a player path is still pushed over the root page',
        (tester) async {
      final router = await _pumpShellRouter(tester);
      unawaited(router.push<void>('/root-page'));
      await tester.pumpAndSettle();

      pushRouteSafely(router, sourcePlayerLocation(fakeMovie(1).ref));
      await tester.pumpAndSettle();
      expect(find.byKey(_playerKey), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(_rootPageKey), findsOneWidget);
    });
  });
}
