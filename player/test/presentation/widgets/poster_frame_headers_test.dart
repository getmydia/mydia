// Artwork that needs request headers (a Plex or Stash credential) cannot feed
// the ambient backdrop, which loads its image with none.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';
import 'package:player/presentation/widgets/poster_frame.dart';

import '../../test_utils/mock_network_images.dart';
import '../../test_utils/poster_contract.dart';

const _placeholder = ColoredBox(color: Color(0xFF1E1E21));

void main() {
  Future<ProviderContainer> hoverPoster(
    WidgetTester tester, {
    Map<String, String>? headers,
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(ambientBackdropControllerProvider, (_, __) {});
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 140,
              height: 210,
              child: PosterFrame(
                imageUrl: 'https://example.com/a.jpg',
                imageHeaders: headers,
                placeholder: _placeholder,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await hoverOver(tester, find.byType(PosterFrame));
    return container;
  }

  testWidgets('hovering artwork that needs headers publishes no backdrop',
      (tester) async {
    await mockNetworkImages(() async {
      final container =
          await hoverPoster(tester, headers: const {'X-Plex-Token': 't'});
      expect(container.read(ambientBackdropControllerProvider).imageUrl, null);
    });
  });

  testWidgets('positive control: headerless artwork still publishes',
      (tester) async {
    await mockNetworkImages(() async {
      final container = await hoverPoster(tester);
      expect(container.read(ambientBackdropControllerProvider).imageUrl,
          'https://example.com/a.jpg');
    });
  });
}
