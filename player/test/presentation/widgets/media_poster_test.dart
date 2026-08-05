// MediaPoster must satisfy the shared poster depth contract (plan R7, R11).
// The contract itself lives in test_utils/poster_contract.dart so every poster
// surface asserts the same thing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../../test_utils/poster_contract.dart';

void main() {
  runPosterDepthContract(
    description: 'MediaPoster',
    build: () => const MediaPoster(title: 'Show'),
    target: find.byType(MediaPoster),
    size: const Size(140, 230),
  );

  group('MediaPoster behavior', () {
    testWidgets('tap fires onTap', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        posterHost(
          MediaPoster(title: 'Show', onTap: () => tapped = true),
          size: const Size(140, 230),
        ),
      );
      await tester.tap(find.byType(MediaPoster));

      expect(tapped, isTrue);
    });
  });
}
