import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/sources/source_item_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_media_source.dart';

Future<List<String>> pumpItem(
    WidgetTester tester, FakeMediaSource fake, ItemRef item) async {
  final pushed = <String>[];
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => SourceItemScreen(item: item)),
    for (final path in ['/s/:id/player/:item', '/s/:id/item/:kind/:item'])
      GoRoute(
        path: path,
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
      // No artwork requests: a URL keeps a spinner running and pumpAndSettle never settles.
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  await tester.pumpAndSettle();
  return pushed;
}

class _NoWatchedSource extends FakeMediaSource {
  @override
  Set<SourceCapability> get capabilities => const {};

  @override
  T? as<T extends Object>() => null;
}

class _FailingWatchedSource extends FakeMediaSource {
  @override
  Future<void> setWatched(ItemRef ref, bool watched) async =>
      throw const SourceException.unreachable();
}

void main() {
  testWidgets('no watched toggle without WatchedState', (tester) async {
    await pumpItem(
        tester,
        _NoWatchedSource(),
        const ItemRef(
            sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm3'));
    expect(find.byKey(const Key('source-item-play')), findsOneWidget);
    expect(find.byKey(const Key('source-item-watched')), findsNothing);
  });

  testWidgets('a failing setWatched shows a toast', (tester) async {
    await pumpItem(
        tester,
        _FailingWatchedSource(),
        const ItemRef(
            sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm3'));
    await tester.tap(find.byKey(const Key('source-item-watched')));
    await tester.pumpAndSettle();
    expect(find.text(const SourceException.unreachable().viewerMessage),
        findsOneWidget);
  });

  const movie =
      ItemRef(sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm3');

  testWidgets('a movie offers resume, focused, and opens the player',
      (tester) async {
    final pushed = await pumpItem(tester, FakeMediaSource(), movie);
    expect(find.text('Invented Film 3'), findsOneWidget);
    expect(find.text('Invented overview.'), findsOneWidget);
    final play = find.byKey(const Key('source-item-play'));
    expect(find.descendant(of: play, matching: find.text('Resume')),
        findsOneWidget);
    expect(
        Focus.of(tester.element(
                find.descendant(of: play, matching: find.text('Resume'))))
            .hasFocus,
        isTrue,
        reason: 'on a TV the play button is where the remote starts');

    await tester.tap(play);
    await tester.pumpAndSettle();
    final opened = Uri.parse(pushed.single);
    expect(opened.path, '/s/acc1:owner:aa11/player/m3');
    expect(opened.queryParameters,
        {'kind': 'movie', 'fileId': 'part-1', 'title': 'Invented Film 3'});
  });

  testWidgets('marks watched through the source', (tester) async {
    final fake = FakeMediaSource();
    await pumpItem(tester, fake, movie);
    await tester.tap(find.byKey(const Key('source-item-watched')));
    await tester.pumpAndSettle();
    expect(fake.watchedCalls.single, (movie, true));
  });

  testWidgets('a show lists seasons, a season lists episodes', (tester) async {
    final pushed = await pumpItem(
        tester,
        FakeMediaSource(),
        const ItemRef(
            sourceId: fakeSourceId, kind: ItemKind.show, externalId: 's1'));
    expect(find.text('Season 1'), findsOneWidget);
    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
    expect(pushed.single, '/s/acc1:owner:aa11/item/season/se1');
  });

  testWidgets('a season lists its episodes', (tester) async {
    await pumpItem(
        tester,
        FakeMediaSource(),
        const ItemRef(
            sourceId: fakeSourceId, kind: ItemKind.season, externalId: 'se1'));
    expect(find.text('Invented Episode 1'), findsOneWidget);
    expect(find.text('Invented Episode 2'), findsOneWidget);
  });
}
