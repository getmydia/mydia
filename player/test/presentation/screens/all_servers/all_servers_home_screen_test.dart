import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/all_servers/all_servers_home_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/toast_harness.dart';

Future<List<String>> pump(
    WidgetTester tester, List<MediaSource> sources) async {
  final pushed = <String>[];
  final router = GoRouter(routes: [
    GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: AllServersHomeScreen())),
    GoRoute(
      path: '/s/:id/:kind/:item',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
  ]);
  await tester.binding.setSurfaceSize(const Size(1280, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      allServersSourcesProvider.overrideWithValue(sources),
      sourcesProvider.overrideWithValue([for (final s in sources) s.source]),
      allServersNeedSignInProvider.overrideWithValue(const []),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  await tester.pumpAndSettle();
  return pushed;
}

FakeMergedSource serverWith(String id) {
  final s = fakeServer(id);
  return FakeMergedSource(
    s,
    resuming: [
      item(s, '${id}1', lastPlayedAt: DateTime.utc(2024, 1, id == 'b' ? 2 : 1)),
    ],
    recent: [
      item(s, '${id}2', addedAt: DateTime.utc(2024, 1, 1)),
      item(s, '${id}3', kind: ItemKind.show, addedAt: DateTime.utc(2024, 1, 1)),
    ],
    favs: [item(s, '${id}4')],
  );
}

void main() {
  testWidgets('shows both rows, newest first, captioned by server', (t) async {
    final a = serverWith('a'), b = serverWith('b');
    await pump(t, [a, b]);
    expect(find.byKey(const Key('all-servers-home')), findsOneWidget);
    expect(find.byKey(const Key('all-continue-watching')), findsOneWidget);
    expect(find.byKey(const Key('all-recent-movies')), findsOneWidget);
    final first =
        t.getTopLeft(find.byKey(ValueKey('all-poster-${b.id.value}-b1')));
    final second =
        t.getTopLeft(find.byKey(ValueKey('all-poster-${a.id.value}-a1')));
    expect(first.dx, lessThan(second.dx));
    expect(find.textContaining('Server b'), findsWidgets);
  });

  testWidgets('hero, then the four rails in order', (t) async {
    await pump(t, [serverWith('a'), serverWith('b')]);
    for (final k in [
      'all-home-hero',
      'all-continue-watching',
      'all-recent-movies',
      'all-recent-shows',
      'all-favorites',
    ]) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    double y(String k) => t.getTopLeft(find.byKey(Key(k))).dy;
    expect(y('all-continue-watching'), lessThan(y('all-recent-movies')));
    expect(y('all-recent-movies'), lessThan(y('all-recent-shows')));
    expect(y('all-recent-shows'), lessThan(y('all-favorites')));
  });

  testWidgets('an empty rail is hidden', (t) async {
    final s = fakeServer('a');
    await pump(t, [
      FakeMergedSource(s, recent: [item(s, 'm', addedAt: DateTime.utc(2024))]),
      FakeMergedSource(fakeServer('b')),
    ]);
    expect(find.byKey(const Key('all-recent-movies')), findsOneWidget);
    expect(find.byKey(const Key('all-recent-shows')), findsNothing);
    expect(find.byKey(const Key('all-favorites')), findsNothing);
  });

  testWidgets('a failed server shows the banner; retry reloads', (t) async {
    final a = serverWith('a');
    final down = FakeMergedSource(fakeServer('d'))
      ..failWith = const SourceException.unreachable();
    await pump(t, [a, down]);
    expect(find.byKey(const Key('all-unavailable-banner')), findsOneWidget);
    expect(find.textContaining('Server d'), findsOneWidget);
    down.failWith = null;
    await t.tap(find.byKey(const Key('all-unavailable-retry')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('all-unavailable-banner')), findsNothing);
  });

  testWidgets('tapping a card opens its detail route', (t) async {
    final a = serverWith('a'), b = serverWith('b');
    final pushed = await pump(t, [a, b]);
    await t.tap(find.byKey(ValueKey('all-poster-${a.id.value}-a1')));
    await t.pumpAndSettle();
    expect(pushed.last, startsWith('/s/${a.id.value}/'));
  });

  testWidgets('every server failing shows the error view', (t) async {
    final a = FakeMergedSource(fakeServer('a'))
      ..failWith = const SourceException.unreachable();
    final b = FakeMergedSource(fakeServer('b'))
      ..failWith = const SourceException.unreachable();
    await pump(t, [a, b]);
    expect(find.byKey(const Key('source-error-retry')), findsOneWidget);
  });

  testWidgets('no included servers is empty, not an error', (t) async {
    await pump(t, []);
    expect(find.byKey(const Key('source-error-retry')), findsNothing);
    expect(find.text('Nothing to show yet.'), findsOneWidget);
  });
}
