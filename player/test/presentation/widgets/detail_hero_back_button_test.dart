import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

void main() {
  testWidgets('pops back to where the detail screen was pushed from',
      (tester) async {
    final router = _router('/shelf');
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.push('/detail');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DetailHeroBackButton));
    await tester.pumpAndSettle();

    expect(find.text('shelf'), findsOneWidget);
  });

  testWidgets('goes home when there is nothing to pop', (tester) async {
    final router = _router('/detail');
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DetailHeroBackButton));
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('is a flat icon button with a Back tooltip', (tester) async {
    await tester
        .pumpWidget(MaterialApp.router(routerConfig: _router('/detail')));
    await tester.pumpAndSettle();

    final button = tester.widget<IconButton>(find.descendant(
      of: find.byType(DetailHeroBackButton),
      matching: find.byType(IconButton),
    ));
    expect(button.tooltip, 'Back');
    expect(button.style?.backgroundColor, isNull);
  });
}
