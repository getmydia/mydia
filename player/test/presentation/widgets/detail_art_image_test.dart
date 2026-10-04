import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_art.dart';
import 'package:player/presentation/widgets/artwork_image.dart';
import 'package:player/presentation/widgets/detail_art_image.dart';

import '../../test_utils/mock_network_images.dart';

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
}
