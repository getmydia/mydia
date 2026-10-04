import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/detail/detail_art.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/widgets/artwork_image.dart';
import 'package:player/presentation/widgets/detail_art_image.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../test_utils/mock_network_images.dart';
import '../screens/sources/fake_media_source.dart';

Future<void> _pump(
  WidgetTester tester,
  DetailArt? art, {
  WidgetBuilder? fallback,
}) async {
  await mockNetworkImages(() async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: DetailArtImage(
            art: art,
            slot: ArtSlot.backdrop,
            placeholder: (_) => const Text('placeholder'),
            fallback: fallback,
          ),
        ),
      ),
    ));
  });
}

void main() {
  testWidgets('a URL art loads through ArtworkImage', (tester) async {
    await _pump(tester, const UrlArt('https://img.test/b.jpg'));
    final image = tester.widget<ArtworkImage>(find.byType(ArtworkImage));
    expect(image.imageUrl, 'https://img.test/b.jpg');
    expect(image.headers, isNull);
  });

  testWidgets('no art shows the placeholder', (tester) async {
    await _pump(tester, null);
    expect(find.byType(ArtworkImage), findsNothing);
    expect(find.text('placeholder'), findsOneWidget);
  });

  testWidgets('no art shows the fallback, not the loading placeholder',
      (tester) async {
    await _pump(tester, null, fallback: (_) => const Text('fallback'));
    expect(find.text('fallback'), findsOneWidget);
    expect(find.text('placeholder'), findsNothing);
  });

  testWidgets('the loading placeholder goes to ArtworkImage', (tester) async {
    await _pump(
      tester,
      const UrlArt('https://img.test/b.jpg'),
      fallback: (_) => const Text('fallback'),
    );
    final image = tester.widget<ArtworkImage>(find.byType(ArtworkImage));
    final built = image.placeholder!(tester.element(find.byType(ArtworkImage)));
    expect((built as Text).data, 'placeholder');
  });

  group('source art', () {
    Future<void> pumpSource(
      WidgetTester tester,
      DetailArt? art,
    ) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            mediaSourceProvider(fakeSourceId)
                .overrideWithValue(FakeMediaSource()),
          ],
          child: MaterialApp(
            home: SizedBox(
              width: 200,
              height: 100,
              child: DetailArtImage(
                art: art,
                slot: ArtSlot.poster,
                placeholder: (_) => const Text('placeholder'),
                fallback: (_) => const Text('fallback'),
                errorWidget: (_) => const Text('error'),
              ),
            ),
          ),
        ));
        await tester.pump();
        await tester.pump();
      });
    }

    testWidgets('resolves through the source with its headers and cache key',
        (tester) async {
      await pumpSource(
          tester, const SourceArt(fakeSourceId, ArtworkRef('/art/m1')));
      final image = tester.widget<ArtworkImage>(find.byType(ArtworkImage));
      expect(image.headers, {'X-Plex-Token': 'tok'});
      expect(image.cacheKey, '$fakeSourceId|/art/m1|400');
      expect(image.imageUrl, contains('/art/m1'));
    });

    testWidgets('shows the placeholder while the request resolves',
        (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            mediaSourceProvider(fakeSourceId)
                .overrideWithValue(FakeMediaSource()),
          ],
          child: MaterialApp(
            home: DetailArtImage(
              art: const SourceArt(fakeSourceId, ArtworkRef('/art/m1')),
              slot: ArtSlot.poster,
              placeholder: (_) => const Text('placeholder'),
              fallback: (_) => const Text('fallback'),
            ),
          ),
        ));
      });
      expect(find.text('placeholder'), findsOneWidget);
      expect(find.text('fallback'), findsNothing);
    });

    testWidgets('a null request shows the fallback', (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            sourceArtworkProvider.overrideWith((ref, key) async => null),
          ],
          child: MaterialApp(
            home: DetailArtImage(
              art: const SourceArt(fakeSourceId, ArtworkRef('/art/m1')),
              slot: ArtSlot.poster,
              placeholder: (_) => const Text('placeholder'),
              fallback: (_) => const Text('fallback'),
            ),
          ),
        ));
        await tester.pump();
        await tester.pump();
      });
      expect(find.text('fallback'), findsOneWidget);
      expect(find.byType(ArtworkImage), findsNothing);
    });
  });
}
