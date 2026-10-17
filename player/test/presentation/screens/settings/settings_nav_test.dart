import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';

GoRouter _router(String initial) => GoRouter(
      initialLocation: initial,
      routes: [
        for (final path in [
          '/',
          '/settings/diagnostics',
          '/sources/manage',
          '/sources/manage/:id',
          '/sources/add',
          '/sources/add/:kind',
          '/s/:sourceId',
        ])
          GoRoute(path: path, builder: (_, state) => Text('at ${state.uri}')),
      ],
    );

Future<GoRouter> _pump(WidgetTester tester, String initial) async {
  final router = _router(initial);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('router nav pushes the same locations the screens used to', (
    tester,
  ) async {
    final router = await _pump(tester, '/');
    final nav = RouterSettingsNav(router);

    nav.openInstance(const SourceId('m1'));
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage/m1'), findsOneWidget);

    nav.openDiagnostics();
    await tester.pumpAndSettle();
    expect(find.text('at /settings/diagnostics'), findsOneWidget);

    nav.addServer();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/add'), findsOneWidget);

    nav.reauth(SourceKind.plex, 'acct1');
    await tester.pumpAndSettle();
    expect(find.text('at /sources/add/plex?account=acct1'), findsOneWidget);
  });

  testWidgets('instanceRemoved returns to the list only from an instance page',
      (
    tester,
  ) async {
    final router = await _pump(tester, '/sources/manage/m1');
    RouterSettingsNav(router).instanceRemoved();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage'), findsOneWidget);

    router.go('/');
    await tester.pumpAndSettle();
    RouterSettingsNav(router).instanceRemoved();
    await tester.pumpAndSettle();
    expect(find.text('at /'), findsOneWidget);
  });

  testWidgets('of() falls back to the router without a scope', (tester) async {
    await _pump(tester, '/');
    final context = tester.element(find.text('at /'));
    expect(SettingsNavScope.of(context), isA<RouterSettingsNav>());
  });
}
