import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/artwork_decode.dart';
import 'package:player/core/cache/poster_cache_manager.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/ambient_backdrop.dart';
import 'package:player/presentation/widgets/artwork_image.dart';

import '../../test_utils/mock_network_images.dart';

Widget _host(
  Widget child, {
  bool disableAnimations = false,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: SizedBox.expand(child: child)),
    ),
  );
}

AnimatedSwitcher _switcherOf(WidgetTester tester) {
  return tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher));
}

void main() {
  group('AmbientBackdrop', () {
    testWidgets('renders the blur via ImageFiltered, not BackdropFilter',
        (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://example.com/a.jpg',
            id: 'a',
          )),
        );
        await tester.pump();

        expect(find.byType(ImageFiltered), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
      });
    });

    testWidgets('passes headers and cacheKey through to the ArtworkImage',
        (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://art/x.jpg',
            id: 'x',
            headers: {'X-Token': 'a'},
            cacheKey: 'k',
          )),
        );
        await tester.pump();

        final image = tester.widget<ArtworkImage>(find.byType(ArtworkImage));
        expect(image.headers, {'X-Token': 'a'});
        expect(image.cacheKey, 'k');
      });
    });

    testWidgets('null imageUrl renders the static fallback (no image)',
        (tester) async {
      await tester.pumpWidget(_host(const AmbientBackdrop()));
      await tester.pump();

      expect(find.byType(ArtworkImage), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
    });

    testWidgets('changing the id key triggers an AnimatedSwitcher transition',
        (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://example.com/a.jpg',
            id: 'a',
          )),
        );
        await tester.pump();

        // Swap the id -> a new keyed child; the switcher keeps both layers
        // present mid-fade.
        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://example.com/b.jpg',
            id: 'b',
          )),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Two artwork layers exist mid-transition (outgoing + incoming).
        expect(find.byType(ArtworkImage), findsNWidgets(2));

        // Settle to a single layer.
        await tester.pumpAndSettle();
        expect(find.byType(ArtworkImage), findsOneWidget);
      });
    });

    testWidgets('same id with unchanged params does not transition',
        (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://example.com/a.jpg',
            id: 'a',
          )),
        );
        await tester.pump();

        // Rebuild with identical id/url.
        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://example.com/a.jpg',
            id: 'a',
          )),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // No second layer spawned.
        expect(find.byType(ArtworkImage), findsOneWidget);
      });
    });

    testWidgets(
        'toggling artwork on and off faster than the crossfade does not '
        'duplicate the fallback key', (tester) async {
      // Hovering across a poster grid flips the source artwork <-> none on
      // every mouse enter/leave, much faster than the 600ms crossfade. Each
      // flip parks an outgoing layer, so several fallback layers — which all
      // share the constant 'ambient-fallback' key — stay alive at once.
      // AnimatedSwitcher only dedupes outgoing children against the *current*
      // child, so without our own dedupe the layout Stack ends up with two
      // identically keyed children and asserts, taking the whole shell subtree
      // down with it.
      await mockNetworkImages(() async {
        await tester.pumpWidget(_host(const AmbientBackdrop()));
        await tester.pump();

        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://example.com/a.jpg',
            id: 'a',
          )),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Back to the fallback: a second layer with the same key is created
        // while the first one is still fading out.
        await tester.pumpWidget(_host(const AmbientBackdrop()));
        await tester.pump(const Duration(milliseconds: 100));

        // Switching away again leaves both fallback layers outgoing at once.
        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://example.com/b.jpg',
            id: 'b',
          )),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('with reduced motion on, the crossfade duration is zero',
        (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(
            const AmbientBackdrop(
              imageUrl: 'https://example.com/a.jpg',
              id: 'a',
            ),
            disableAnimations: true,
          ),
        );
        await tester.pump();

        expect(_switcherOf(tester).duration, Duration.zero);
      });
    });

    testWidgets('with motion allowed, the crossfade duration is non-zero',
        (tester) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _host(const AmbientBackdrop(
            imageUrl: 'https://example.com/a.jpg',
            id: 'a',
          )),
        );
        await tester.pump();

        expect(_switcherOf(tester).duration, greaterThan(Duration.zero));
      });
    });

    testWidgets('decodes the backdrop at viewport width, capped at w1280',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await mockNetworkImages(() async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox.expand(
                child: AmbientBackdrop(
                  imageUrl: 'https://image.tmdb.org/t/p/w1280/a.jpg',
                  id: 'a',
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final rendered = tester
            .widget<Image>(
              find.descendant(
                of: find.byType(AmbientBackdrop),
                matching: find.byType(Image),
              ),
            )
            .image;

        // The precache in didUpdateWidget builds exactly this provider, so
        // equality here is what guarantees the precache warms the entry the
        // layer reads.
        expect(
          rendered,
          artworkImageProvider(
            'https://image.tmdb.org/t/p/w1280/a.jpg',
            cacheManager: BackdropCacheManager(),
            decodeWidth: 832,
          ),
        );
      });
    });

    testWidgets(
        'didUpdateWidget precaches the bucketed key, never the unbounded one',
        (tester) async {
      // The test above only ever mounts once, so didUpdateWidget's
      // precacheImage call never runs. Swapping the id/url here is the only
      // way to exercise it.
      PaintingBinding.instance.imageCache.clear();
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      const urlA = 'https://image.tmdb.org/t/p/w1280/a.jpg';
      const urlB = 'https://image.tmdb.org/t/p/w1280/b.jpg';

      await mockNetworkImages(() async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox.expand(
                child: AmbientBackdrop(imageUrl: urlA, id: 'a'),
              ),
            ),
          ),
        );
        await tester.pump();

        // New id -> didUpdateWidget sees imageUrl change and precaches.
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox.expand(
                child: AmbientBackdrop(imageUrl: urlB, id: 'b'),
              ),
            ),
          ),
        );

        final boundedProvider = artworkImageProvider(
          urlB,
          cacheManager: BackdropCacheManager(),
          decodeWidth: 832,
        );
        // What didUpdateWidget would precache if it dropped the decode
        // width: the full-resolution provider _ArtworkLayer never asks for.
        final unboundedProvider = artworkImageProvider(
          urlB,
          cacheManager: BackdropCacheManager(),
          decodeWidth: null,
        );

        ImageCacheStatus? boundedStatus;
        ImageCacheStatus? unboundedStatus;
        // obtainKey (and so obtainCacheStatus) is documented async; run it
        // under runAsync so any real Future it awaits can actually complete.
        await tester.runAsync(() async {
          boundedStatus = await boundedProvider.obtainCacheStatus(
            configuration: const ImageConfiguration(),
          );
          unboundedStatus = await unboundedProvider.obtainCacheStatus(
            configuration: const ImageConfiguration(),
          );
        });

        // The precache must land the same bucketed key _ArtworkLayer
        // resolves...
        expect(boundedStatus?.tracked, isTrue);
        // ...and never the unbounded one. Otherwise the backdrop decodes
        // twice: once for the precache's full-resolution fetch, once for the
        // layer's correctly sized one -- the exact waste the precache exists
        // to avoid.
        expect(unboundedStatus?.tracked ?? false, isFalse);

        // Let the crossfade finish so a single Image remains to compare.
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();

        final rendered = tester
            .widget<Image>(
              find.descendant(
                of: find.byType(AmbientBackdrop),
                matching: find.byType(Image),
              ),
            )
            .image;

        expect(rendered, boundedProvider);

        // Sync the cache manager's deferred work: its store schedules a 10 s
        // cleanup timer once its first lookup lands, and when an earlier file
        // has left the shared manager usable that timer would otherwise be
        // pending when the tree is disposed. Poll in real time, bounded at
        // about 5 s, until a probe lookup completes: that means the store's
        // lookups have landed and the timer is scheduled, so the pump below
        // fires it. A lone run has no usable store, the probe never
        // completes and no timer is ever scheduled, so giving up at the
        // bound is correct there, not a failure.
        await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          var settled = false;
          unawaited(BackdropCacheManager()
              .getFileFromCache('ambient-backdrop-test-drain-probe')
              .then((_) => settled = true, onError: (_) => settled = true));
          while (!settled && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        await tester.pump(const Duration(seconds: 11));
      });
    });
  });

  group('AmbientBackdrop tint', () {
    ColoredBox firstBase(WidgetTester tester) => tester.widget<ColoredBox>(
          find
              .descendant(
                of: find.byType(AmbientBackdrop),
                matching: find.byType(ColoredBox),
              )
              .first,
        );

    testWidgets('base takes the tinted ground', (tester) async {
      final warm = AmbientTintColors.fromSeed(const Color(0xFF9F4A2F));
      await tester.pumpWidget(
        _host(AmbientTint(
          colors: warm,
          child: const AmbientBackdrop(imageUrl: null, id: 'a'),
        )),
      );
      expect(firstBase(tester).color, warm.ground);
    });

    testWidgets('base is the neutral background without a scope',
        (tester) async {
      await tester.pumpWidget(
        _host(const AmbientBackdrop(imageUrl: null, id: 'a')),
      );
      expect(firstBase(tester).color, Palettes.projectionBooth.background);
    });
  });
}
