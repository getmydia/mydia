// PosterFrame is the single owner of the poster depth contract. It must satisfy
// that contract itself, and it must render the caller's placeholder, persistent
// overlays, and hover overlay without owning any of their appearance.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/poster_frame.dart';

import '../../test_utils/poster_contract.dart';

const _placeholder = ColoredBox(
  color: Color(0xFF1E1E21),
  child: Center(child: Icon(Icons.movie_rounded, size: 40)),
);

void main() {
  runPosterDepthContract(
    description: 'PosterFrame',
    build: () => const PosterFrame(placeholder: _placeholder),
    target: find.byType(PosterFrame),
    size: const Size(140, 210),
  );

  group('PosterFrame content', () {
    testWidgets('renders the placeholder when there is no artwork',
        (tester) async {
      await tester.pumpWidget(
        posterHost(
          const PosterFrame(placeholder: _placeholder),
          size: const Size(140, 210),
        ),
      );

      expect(find.byIcon(Icons.movie_rounded), findsOneWidget);
    });

    testWidgets('renders persistent overlays above the artwork',
        (tester) async {
      await tester.pumpWidget(
        posterHost(
          const PosterFrame(
            placeholder: _placeholder,
            overlays: [
              Positioned(top: 8, right: 8, child: Icon(Icons.hd_rounded)),
            ],
          ),
          size: const Size(140, 210),
        ),
      );

      expect(find.byIcon(Icons.hd_rounded), findsOneWidget);
    });

    testWidgets('fades the hover overlay in on hover', (tester) async {
      await tester.pumpWidget(
        posterHost(
          const PosterFrame(
            placeholder: _placeholder,
            hoverOverlay: ColoredBox(
              color: Color(0xCC000000),
              child: Center(child: Icon(Icons.play_circle_filled)),
            ),
          ),
          size: const Size(140, 210),
        ),
      );
      await tester.pumpAndSettle();

      AnimatedOpacity opacity() =>
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));

      expect(opacity().opacity, 0.0);

      await hoverOver(tester, find.byType(PosterFrame));

      expect(opacity().opacity, 1.0);
    });

    testWidgets('clips to the shared poster radius', (tester) async {
      await tester.pumpWidget(
        posterHost(
          const PosterFrame(placeholder: _placeholder),
          size: const Size(140, 210),
        ),
      );

      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);

      expect(
        clip.borderRadius,
        BorderRadius.circular(DepthTokens.radiusPoster),
      );
    });
  });

  group('PosterPlayScrim', () {
    testWidgets('renders the neutral play affordance over a dark ground',
        (tester) async {
      await tester.pumpWidget(
        posterHost(const PosterPlayScrim(), size: const Size(140, 210)),
      );

      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
      // Scope to the scrim's own ColoredBox. MaterialApp's Material 3 route
      // entrance transition contributes an incidental transparent ColoredBox to
      // the tree, so a bare find.byType(ColoredBox) matches two and throws.
      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(
                of: find.byType(PosterPlayScrim),
                matching: find.byType(ColoredBox),
              ),
            )
            .color,
        AppColors.overlayDark,
      );
    });
  });
}
