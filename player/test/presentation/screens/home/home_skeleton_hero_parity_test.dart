// The skeleton hero exists so nothing moves when the real hero replaces it, so
// its height has to match the loaded hero's in both layouts.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/home/home_loading_skeleton.dart';
import 'package:player/presentation/screens/sources/source_home_hero.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../sources/fake_media_source.dart';

// A one-line title and an overview long enough to fill both of its lines.
const _item = ItemSummary(
  ref: ItemRef(
    sourceId: fakeSourceId,
    kind: ItemKind.movie,
    externalId: 'night-ferry',
  ),
  title: 'Night Ferry',
  year: 2011,
  overview: 'A ferry crosses the saltmarsh after dark, and the passengers '
      'trade stories until the far shore appears out of the fog, long '
      'after the lanterns have burned low and the tide has turned twice.',
  poster: ArtworkRef('/art/night-ferry'),
);

void main() {
  for (final size in const [Size(400, 800), Size(1280, 800)]) {
    testWidgets('skeleton hero is as tall as the loaded hero at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: _Skeleton())),
      ));
      await tester.pump();
      final skeleton = tester.getSize(find.byKey(HomeLoadingSkeleton.heroKey));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          mediaSourceProvider(fakeSourceId)
              .overrideWithValue(FakeMediaSource()),
          sourceArtworkProvider.overrideWith((ref, key) async => null),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SourceHomeHero(sourceId: fakeSourceId, item: _item),
            ),
          ),
        ),
      ));
      await tester.pump();
      final loaded = tester.getSize(find.byType(SourceHomeHero));

      expect(skeleton.height, closeTo(loaded.height, 1));
    });
  }

  testWidgets('the stacked poster is capped at 320 below the wide breakpoint',
      (tester) async {
    tester.view.physicalSize = const Size(899, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: _Skeleton())),
    ));
    await tester.pump();

    expect(
      tester.getSize(find.byKey(HomeLoadingSkeleton.heroPosterKey)).width,
      320,
    );
  });
}

/// Only the hero: the full skeleton is a ListView, which wants a bounded
/// height the scroll view here does not give.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 1200, child: HomeLoadingSkeleton());
}
