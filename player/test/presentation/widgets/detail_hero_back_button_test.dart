import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/detail_hero_app_bar.dart';

GoRouter _router(String initialLocation) => GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Text('home')),
        GoRoute(path: '/shelf', builder: (_, __) => const Text('shelf')),
        GoRoute(
          path: '/detail',
          builder: (_, __) =>
              const Scaffold(body: Center(child: DetailHeroBackButton())),
        ),
      ],
    );

Widget _app(GoRouter router) => MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );

void main() {
  testWidgets('pops back to where the detail screen was pushed from',
      (tester) async {
    final router = _router('/shelf');
    await tester.pumpWidget(_app(router));
    // Completes when the route pops, which the test never waits for.
    unawaited(router.push<void>('/detail'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DetailHeroBackButton));
    await tester.pumpAndSettle();

    expect(find.text('shelf'), findsOneWidget);
  });

  testWidgets('goes home when there is nothing to pop', (tester) async {
    final router = _router('/detail');
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DetailHeroBackButton));
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('is a flat icon button with a Back tooltip', (tester) async {
    await tester.pumpWidget(_app(_router('/detail')));
    await tester.pumpAndSettle();

    final button = tester.widget<IconButton>(find.descendant(
      of: find.byType(DetailHeroBackButton),
      matching: find.byType(IconButton),
    ));
    expect(button.tooltip, 'Back');
    expect(button.style?.backgroundColor, isNull);
  });
}
