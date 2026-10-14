// The shell's pages inset themselves, mounted through the real `MyApp`,
// `appRouter`, `ShellRoute` and `AppShell`. Widget tests that compose
// `railLayers` by hand never mount go_router's shell Navigator, whose Overlay
// clips every page at its own bounds: a shell that padded that navigator put
// the detail art and Home's hero backdrop at the column's edge in the browser
// while those tests stayed green. Here the Overlay is real.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/app.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/detail/detail_hero.dart';
import 'package:player/presentation/screens/sources/source_search_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'presentation/screens/sources/fake_media_source.dart';

final _id = fakeSourceId.value;

Future<(ProviderContainer, GoRouter)> _pumpApp(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    sourcesLoadingProvider.overrideWithValue(false),
    hasMydiaProvider.overrideWithValue(false),
    thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
    mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
    sourceArtworkProvider.overrideWith((ref, key) async => null),
    castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MyApp(),
  ));
  // A frame first: navigating before the router has built its first page
  // never returns.
  await tester.pump(const Duration(milliseconds: 50));
  final router = container.read(appRouterProvider);
  return (container, router);
}

/// Not pumpAndSettle: the shell's loading indicators never settle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final inset = Breakpoints.railContentInset(pinned: false);

  testWidgets('a page opened over another never moves it, on any frame',
      (tester) async {
    final (_, router) = await _pumpApp(tester);
    router.go('/s/$_id/search');
    await _settle(tester);

    final page = find.byType(SourceSearchScreen, skipOffstage: false);
    expect(page, findsOneWidget);
    final home = tester.getTopLeft(page).dx;
    expect(home, inset, reason: 'an ordinary page is inset by the rail');

    Future<void> everyFrame() async {
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(page).dx, home, reason: 'frame $i');
      }
    }

    unawaited(router.push<void>('/s/$_id/movie/m1'));
    await everyFrame();
    await _settle(tester);

    router.pop();
    await everyFrame();
    await _settle(tester);
    expect(tester.getTopLeft(page).dx, home);
  });

  testWidgets(
      'a detail page paints its art to x=0, its back button beside '
      'the rail', (tester) async {
    final (_, router) = await _pumpApp(tester);
    router.go('/s/$_id/search');
    await _settle(tester);
    unawaited(router.push<void>('/s/$_id/movie/m1'));
    await _settle(tester);

    final art = find.byType(DetailHeroBackground);
    expect(art, findsOneWidget);
    expect(tester.getTopLeft(art).dx, 0, reason: 'under the rail');
    expect(tester.getTopLeft(art).dy, 0);

    final back = tester.getRect(find.byTooltip('Back'));
    expect(back.left, greaterThanOrEqualTo(inset),
        reason: 'never under the rail');
    // The title row's own gutter, not a second rail inset.
    expect(back.left, lessThan(inset + 40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('below 600 there is no rail and nothing is inset',
      (tester) async {
    // The test font overflows the bottom bar's labels; that is not under test.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.toString().contains('overflowed')) onError?.call(details);
    };
    addTearDown(() => FlutterError.onError = onError);
    final (_, router) = await _pumpApp(tester, size: const Size(400, 800));
    router.go('/s/$_id/search');
    await _settle(tester);
    expect(tester.getTopLeft(find.byType(SourceSearchScreen)).dx, 0);

    unawaited(router.push<void>('/s/$_id/movie/m1'));
    await _settle(tester);
    expect(tester.getTopLeft(find.byType(DetailHeroBackground)).dx, 0);
    expect(tester.getRect(find.byTooltip('Back')).left, lessThan(24));
  });
}
