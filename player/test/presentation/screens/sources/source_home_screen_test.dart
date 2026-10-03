import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/sources/source_home_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'fake_media_source.dart';

Future<List<String>> pumpHome(WidgetTester tester, FakeMediaSource fake) async {
  final pushed = <String>[];
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (_, __) => const SourceHomeScreen(sourceId: fakeSourceId),
    ),
    GoRoute(
      path: '/s/:id/library/:lib',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
    GoRoute(
      path: '/s/:id/item/:kind/:item',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
  ]);
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(fake),
      // No artwork requests: a poster with a URL spins until the blocked
      // test HTTP client answers, which pumpAndSettle never outlasts.
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return pushed;
}

void main() {
  testWidgets('shows a row per library, newest first', (tester) async {
    final fake = FakeMediaSource();
    await pumpHome(tester, fake);
    expect(find.text('Films'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    expect(find.text('Invented Film 1'), findsOneWidget);
    expect(fake.browseCalls.map((c) => c.$1.sortId), contains('added'),
        reason: 'rows prefer the source\'s "Recently added" sort');
  });

  testWidgets('a library title opens the grid; a poster opens the item',
      (tester) async {
    final pushed = await pumpHome(tester, FakeMediaSource());
    await tester.tap(find.byKey(const Key('source-library-row-movies')));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/library/movies');
  });

  testWidgets('an unreachable source shows a retry state', (tester) async {
    final fake = FakeMediaSource(failWith: const SourceException.unreachable());
    await pumpHome(tester, fake);
    expect(find.byKey(const Key('source-error-retry')), findsOneWidget);
    fake.failWith = null;
    await tester.tap(find.byKey(const Key('source-error-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Films'), findsOneWidget);
  });
}
