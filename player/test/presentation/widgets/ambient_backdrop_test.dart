import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/ambient_backdrop.dart';

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

    testWidgets('null imageUrl renders the static fallback (no image)',
        (tester) async {
      await tester.pumpWidget(_host(const AmbientBackdrop()));
      await tester.pump();

      expect(find.byType(CachedNetworkImage), findsNothing);
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
        expect(find.byType(CachedNetworkImage), findsNWidgets(2));

        // Settle to a single layer.
        await tester.pumpAndSettle();
        expect(find.byType(CachedNetworkImage), findsOneWidget);
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
        expect(find.byType(CachedNetworkImage), findsOneWidget);
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
  });
}
