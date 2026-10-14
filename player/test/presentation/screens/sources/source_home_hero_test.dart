import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/sources/source_home_hero.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';

import 'fake_media_source.dart';

ItemSummary _movie({String? showTitle}) => ItemSummary(
      ref: const ItemRef(
        sourceId: fakeSourceId,
        kind: ItemKind.movie,
        externalId: 'night-ferry',
      ),
      title: 'Night Ferry',
      showTitle: showTitle,
      year: 2011,
      overview: 'A ferry crosses the saltmarsh after dark. ' * 8,
      poster: const ArtworkRef('/art/night-ferry'),
      backdrop: const ArtworkRef('/backdrop/night-ferry'),
    );

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Size size, {
  ItemSummary? item,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [
    mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
  ]);
  addTearDown(container.dispose);
  // The controller is auto-dispose; keep it alive to read what was published.
  container.listen(ambientBackdropControllerProvider, (_, __) {});
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SourceHomeHero(
            sourceId: fakeSourceId,
            item: item ?? _movie(),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  const posterKey = Key('source-home-hero-poster');
  const playKey = Key('source-home-hero-play');
  const moreKey = Key('source-home-hero-more');

  testWidgets('wide: a 248x360 poster with the title to its right',
      (tester) async {
    await _pump(tester, const Size(1280, 800));

    expect(tester.getSize(find.byKey(posterKey)), const Size(248, 360));
    expect(
      tester.getTopLeft(find.text('Night Ferry')).dx,
      greaterThan(tester.getTopRight(find.byKey(posterKey)).dx),
    );
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byKey(playKey), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(moreKey),
        matching: find.text('More info'),
      ),
      findsOneWidget,
    );
    final overview =
        tester.widget<Text>(find.textContaining('A ferry crosses'));
    expect(overview.maxLines, 2);
  });

  testWidgets('an episode offers All episodes and names its series',
      (tester) async {
    await _pump(tester, const Size(1280, 800),
        item: _movie(showTitle: 'Saltmarsh'));

    expect(find.text('All episodes'), findsOneWidget);
    expect(find.text('Saltmarsh'), findsOneWidget);
  });

  testWidgets('narrow: a centred 60% poster over full-width buttons',
      (tester) async {
    await _pump(tester, const Size(400, 800));

    final poster = find.byKey(posterKey);
    expect(tester.getSize(poster).width, 240);
    expect(tester.getCenter(poster).dx, 200);
    final play = tester.getSize(find.byKey(playKey));
    final more = tester.getSize(find.byKey(moreKey));
    final left = tester.getTopLeft(find.byKey(playKey)).dx;
    // The content width: the view minus the padding on both sides.
    expect(play.width, 400 - 2 * left);
    expect(more.width, play.width);
  });

  testWidgets('publishes the credentialed artwork as the ambient backdrop',
      (tester) async {
    final container = await _pump(tester, const Size(1280, 800));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    final source = container.read(ambientBackdropControllerProvider);
    expect(source.id, 'night-ferry');
    expect(source.imageUrl, contains('/backdrop/night-ferry'));
    expect(source.headers, {'X-Plex-Token': 'tok'});
    expect(source.cacheKey, isNotNull);
  });
}
