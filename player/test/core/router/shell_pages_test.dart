import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/router/shell_pages.dart';
import 'package:player/presentation/widgets/shell_rail_inset.dart';

Future<void> _pump(WidgetTester tester, String location) async {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      ...shellPages([
        GoRoute(
          path: '/plain',
          name: 'favorites',
          builder: (_, __) => const SizedBox(key: Key('plain')),
        ),
        GoRoute(
          path: '/home',
          name: 'source_root',
          builder: (_, __) => const SizedBox(key: Key('home')),
        ),
        GoRoute(
          path: '/movie',
          name: 'source_movie_detail',
          builder: (_, __) => const SizedBox(key: Key('movie')),
        ),
        GoRoute(
          path: '/moved',
          name: 'moved',
          redirect: (_, __) => '/plain',
        ),
      ]),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ShellRailInset(
      left: 112,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an ordinary page is inset by the rail', (tester) async {
    await _pump(tester, '/plain');
    expect(tester.getTopLeft(find.byKey(const Key('plain'))).dx, 112);
    expect(
      find.ancestor(
        of: find.byKey(const Key('plain')),
        matching: find.byType(ShellPageInset),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Home and the detail pages are left to inset themselves',
      (tester) async {
    for (final (location, key) in const [
      ('/home', 'home'),
      ('/movie', 'movie'),
    ]) {
      await _pump(tester, location);
      expect(find.byKey(Key(key)), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(Key(key)),
          matching: find.byType(ShellPageInset),
        ),
        findsNothing,
        reason: location,
      );
      expect(tester.getTopLeft(find.byKey(Key(key))).dx, 0, reason: location);
    }
  });

  testWidgets('a redirect-only route still redirects', (tester) async {
    await _pump(tester, '/moved');
    expect(find.byKey(const Key('plain')), findsOneWidget);
  });
}
