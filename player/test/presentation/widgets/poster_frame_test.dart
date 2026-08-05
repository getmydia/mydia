// PosterFrame is the single owner of the poster depth contract. It must satisfy
// that contract itself, and it must render the caller's placeholder, persistent
// overlays, and hover overlay without owning any of their appearance.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';
import 'package:player/presentation/widgets/poster_frame.dart';

import '../../test_utils/mock_network_images.dart';
import '../../test_utils/poster_contract.dart';

const _placeholder = ColoredBox(
  color: Color(0xFF1E1E21),
  child: Center(child: Icon(Icons.movie_rounded, size: 40)),
);

void main() {
  runPosterDepthContract(
    description: 'PosterFrame',
    build: () => const PosterFrame(placeholder: _placeholder),
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

      // Scope to PosterFrame's own subtree. MaterialApp's Material 3 route
      // entrance transition contributes incidental widgets to the tree, so a
      // bare find.byType risks matching something outside this widget.
      AnimatedOpacity opacity() => tester.widget<AnimatedOpacity>(
            find.descendant(
              of: find.byType(PosterFrame),
              matching: find.byType(AnimatedOpacity),
            ),
          );

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

      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(PosterFrame),
          matching: find.byType(ClipRRect),
        ),
      );

      expect(
        clip.borderRadius,
        BorderRadius.circular(DepthTokens.radiusPoster),
      );
    });
  });

  group('PosterFrame ambient backdrop staleness (regression)', () {
    // These three tests build their own ProviderContainer (rather than the
    // shared posterHost, which wraps a plain ProviderScope) so the backdrop
    // state can be inspected directly, and attach a listener the way
    // ambient_backdrop_tint_test.dart does: the real shell always watches
    // this provider, and it is autoDispose, so an unwatched container would
    // drop the hover state between writes and mask the very staleness this
    // suite exists to catch.
    Widget host(ProviderContainer container, Widget child) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 140, height: 210, child: child),
            ),
          ),
        ),
      );
    }

    testWidgets(
        "republishes the backdrop when a hovered poster's artwork changes",
        (tester) async {
      await mockNetworkImages(() async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.listen(ambientBackdropControllerProvider, (_, __) {});

        const urlA = 'https://example.com/a.jpg';
        const urlB = 'https://example.com/b.jpg';

        await tester.pumpWidget(
          host(
            container,
            const PosterFrame(imageUrl: urlA, placeholder: _placeholder),
          ),
        );
        await tester.pumpAndSettle();
        await hoverOver(tester, find.byType(PosterFrame));

        expect(
          container.read(ambientBackdropControllerProvider).imageUrl,
          urlA,
        );

        // Same widget type, same position: Flutter reuses the element and
        // preserves State, exactly like a scrolling grid recycling an item
        // under a stationary cursor. Neither onEnter nor onExit fires here.
        await tester.pumpWidget(
          host(
            container,
            const PosterFrame(imageUrl: urlB, placeholder: _placeholder),
          ),
        );
        await tester.pump();

        expect(
          container.read(ambientBackdropControllerProvider).imageUrl,
          urlB,
        );
      });
    });

    testWidgets('clears the backdrop when a hovered poster leaves the tree',
        (tester) async {
      await mockNetworkImages(() async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.listen(ambientBackdropControllerProvider, (_, __) {});

        const url = 'https://example.com/a.jpg';

        await tester.pumpWidget(
          host(
            container,
            const PosterFrame(imageUrl: url, placeholder: _placeholder),
          ),
        );
        await tester.pumpAndSettle();
        await hoverOver(tester, find.byType(PosterFrame));

        expect(
          container.read(ambientBackdropControllerProvider).imageUrl,
          url,
        );

        // No PosterFrame in this tree at all. MouseRegion's own docs warn
        // onExit may not fire when the region unmounts while hovered, so
        // this must not depend on it.
        await tester.pumpWidget(host(container, const SizedBox.shrink()));
        await tester.pump();

        expect(
          container.read(ambientBackdropControllerProvider),
          BackdropSource.none,
        );
      });
    });

    testWidgets(
        "a hovered poster whose artwork becomes null clears the override",
        (tester) async {
      await mockNetworkImages(() async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.listen(ambientBackdropControllerProvider, (_, __) {});

        const url = 'https://example.com/a.jpg';

        await tester.pumpWidget(
          host(
            container,
            const PosterFrame(imageUrl: url, placeholder: _placeholder),
          ),
        );
        await tester.pumpAndSettle();
        await hoverOver(tester, find.byType(PosterFrame));

        expect(
          container.read(ambientBackdropControllerProvider).imageUrl,
          url,
        );

        await tester.pumpWidget(
          host(
            container,
            const PosterFrame(placeholder: _placeholder),
          ),
        );
        await tester.pump();

        expect(
          container.read(ambientBackdropControllerProvider),
          BackdropSource.none,
        );
      });
    });

    testWidgets(
        'an artwork-loss update does not wipe a newer override from a '
        'different poster (regression: scroll-recycling race)', (tester) async {
      await mockNetworkImages(() async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.listen(ambientBackdropControllerProvider, (_, __) {});

        const urlA = 'https://example.com/a.jpg';
        const urlB = 'https://example.com/b.jpg';

        await tester.pumpWidget(
          host(
            container,
            const PosterFrame(imageUrl: urlA, placeholder: _placeholder),
          ),
        );
        await tester.pumpAndSettle();
        await hoverOver(tester, find.byType(PosterFrame));

        expect(
          container.read(ambientBackdropControllerProvider).imageUrl,
          urlA,
        );

        // Simulate a different poster (elsewhere in the grid) publishing its
        // own override before this poster's pending artwork-loss clear runs
        // — exactly what a real onEnter from a poster scrolling in under the
        // same stationary cursor would do. This does not need to land inside
        // the exact same frame as the pump below: it only needs to still be
        // the active override at the moment the deferred callback below
        // fires, and nothing else touches the controller in between.
        const posterB = BackdropSource(imageUrl: urlB, id: urlB);
        container.read(ambientBackdropControllerProvider.notifier).setHover(
              posterB,
            );

        // Same widget, same position, still hovered: loses its artwork.
        // didUpdateWidget's no-artwork branch schedules a deferred clear of
        // what *this* poster published (urlA) — a bare clearHover() would
        // wipe posterB's fresher override instead.
        await tester.pumpWidget(
          host(container, const PosterFrame(placeholder: _placeholder)),
        );
        await tester.pump();

        expect(container.read(ambientBackdropControllerProvider), posterB);
      });
    });
  });
}
