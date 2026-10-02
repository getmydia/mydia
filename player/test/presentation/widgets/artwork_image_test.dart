import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octo_image/octo_image.dart';
import 'package:player/core/cache/artwork_decode.dart';
import 'package:player/presentation/widgets/artwork_image.dart';

import '../../test_utils/mock_network_images.dart';

const _url = 'https://image.example/poster.png';

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: SizedBox(width: 100, height: 150, child: child)),
    );

void main() {
  testWidgets('resolves the shared artwork provider at the decode width',
      (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(
        _host(const ArtworkImage(imageUrl: _url, decodeWidth: 128)),
      );

      final octo = tester.widget<OctoImage>(find.byType(OctoImage));
      expect(octo.image, artworkImageProvider(_url, decodeWidth: 128));
      expect((octo.image as ResizeImage).width, 128);
    });
  });

  testWidgets('without a decode width the provider is not resized',
      (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(_host(const ArtworkImage(imageUrl: _url)));

      final octo = tester.widget<OctoImage>(find.byType(OctoImage));
      expect(octo.image, isA<ArtworkNetworkImageProvider>());
    });
  });

  testWidgets('shows the placeholder while loading', (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(
        _host(
          ArtworkImage(
            imageUrl: _url,
            placeholder: (_) => const Text('loading'),
          ),
        ),
      );

      expect(find.text('loading'), findsOneWidget);
    });
  });

  testWidgets('passes fit, alignment and fades to OctoImage', (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(
        _host(
          ArtworkImage(
            imageUrl: _url,
            fit: BoxFit.none,
            alignment: Alignment.topLeft,
            errorWidget: (_) => const Text('failed'),
          ),
        ),
      );

      final octo = tester.widget<OctoImage>(find.byType(OctoImage));
      expect(octo.fit, BoxFit.none);
      expect(octo.alignment, Alignment.topLeft);
      expect(octo.fadeInDuration, const Duration(milliseconds: 500));
      expect(octo.fadeOutDuration, const Duration(milliseconds: 1000));
      expect(octo.errorBuilder, isNotNull);
      expect(
        (octo.errorBuilder!(tester.element(find.byType(OctoImage)), 'e', null)
                as Text)
            .data,
        'failed',
      );
    });
  });

  testWidgets('always supplies a placeholder so OctoImage still fades',
      (tester) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(_host(const ArtworkImage(imageUrl: _url)));

      final octo = tester.widget<OctoImage>(find.byType(OctoImage));
      expect(octo.placeholderBuilder, isNotNull);
      expect(octo.errorBuilder, isNull);
    });
  });
}
