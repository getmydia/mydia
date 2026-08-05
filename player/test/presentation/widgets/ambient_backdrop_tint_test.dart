// U8 — ambient backdrop tint + hover-follow (plan R5, R9).
//
// Hovering a poster publishes its artwork as a backdrop override on top of the
// screen default; moving off reverts to the default (R9). Real-blur chrome over
// that backdrop tints with it for free (R5) — asserted structurally elsewhere
// (U3 sidebar BackdropFilter). Here we verify the controller's default/hover
// layering and that the poster widgets drive it on hover.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';
import 'package:player/presentation/widgets/media_card.dart';

import '../../test_utils/mock_network_images.dart';

void main() {
  group('AmbientBackdropController default/hover layering (R9)', () {
    test('hover overrides the screen default; clearHover reverts', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier =
          container.read(ambientBackdropControllerProvider.notifier);

      notifier.setDefault(const BackdropSource(imageUrl: 'd', id: 'd'));
      expect(container.read(ambientBackdropControllerProvider).id, 'd');

      notifier.setHover(const BackdropSource(imageUrl: 'h', id: 'h'));
      expect(container.read(ambientBackdropControllerProvider).id, 'h');

      // Updating the default while hovering keeps the hover override visible...
      notifier.setDefault(const BackdropSource(imageUrl: 'd2', id: 'd2'));
      expect(container.read(ambientBackdropControllerProvider).id, 'h');

      // ...and clearing the hover reveals the latest default.
      notifier.clearHover();
      expect(container.read(ambientBackdropControllerProvider).id, 'd2');
    });

    test('clearHover with no hover set is a no-op', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier =
          container.read(ambientBackdropControllerProvider.notifier);

      notifier.setDefault(const BackdropSource(imageUrl: 'd', id: 'd'));
      notifier.clearHover();
      expect(container.read(ambientBackdropControllerProvider).id, 'd');
    });
  });

  group('poster hover drives the backdrop (R5/R9)', () {
    testWidgets('hovering a card publishes its artwork; off-hover reverts',
        (tester) async {
      await mockNetworkImages(() async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        // The shell always watches this provider; keep it alive here so the
        // autoDispose controller doesn't drop the hover state between writes.
        container.listen(ambientBackdropControllerProvider, (_, __) {});

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(
                // MediaCard's Column is MainAxisSize.max, so an unbounded host
                // stretches it to the full viewport while the poster occupies
                // only the top ~195px, putting getCenter in dead space. Hover is
                // scoped to the poster itself, so the host must be bounded.
                body: Center(
                  child: SizedBox(
                    width: 130,
                    height: 260,
                    child: MediaCard(
                      title: 'Movie',
                      posterUrl: 'https://example.com/p.jpg',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);

        // Hover enters the card.
        await gesture.moveTo(tester.getCenter(find.byType(MediaCard)));
        await tester.pumpAndSettle();
        expect(
          container.read(ambientBackdropControllerProvider).imageUrl,
          'https://example.com/p.jpg',
        );

        // Move off the card -> revert to the screen default (none).
        await gesture.moveTo(const Offset(-100, -100));
        await tester.pumpAndSettle();
        expect(
          container.read(ambientBackdropControllerProvider),
          BackdropSource.none,
        );
      });
    });

    testWidgets('a card with no artwork leaves the backdrop at the default',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(ambientBackdropControllerProvider, (_, __) {});

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 130,
                  height: 260,
                  child: MediaCard(title: 'No Art'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(MediaCard)));
      await tester.pumpAndSettle();

      // No artwork -> no override -> backdrop stays on the calm default.
      expect(
        container.read(ambientBackdropControllerProvider),
        BackdropSource.none,
      );
    });
  });

  group('default updates are not masked by a matching hover (regression)', () {
    testWidgets(
        'a published default is recorded even when it equals the '
        'active hover; clearHover then settles on it', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(ambientBackdropControllerProvider, (_, __) {});
      final notifier =
          container.read(ambientBackdropControllerProvider.notifier);

      const art = BackdropSource(imageUrl: 'u', id: 'a');

      // Hover the same artwork the screen is about to publish as its default.
      notifier.setHover(art);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: _DefaultPublisher(art)),
        ),
      );
      // Let the post-frame publish run.
      await tester.pump();
      await tester.pump();

      // The default was recorded despite equaling the active hover...
      expect(notifier.defaultSource, art);
      // ...so clearing the hover settles on it, not a stale fallback.
      notifier.clearHover();
      expect(container.read(ambientBackdropControllerProvider), art);
    });
  });
}

/// Publishes a fixed source as the screen default from `build`, like a real
/// browse screen.
class _DefaultPublisher extends ConsumerWidget {
  final BackdropSource source;

  const _DefaultPublisher(this.source);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    publishBackdropSource(ref, source);
    return const SizedBox.shrink();
  }
}
