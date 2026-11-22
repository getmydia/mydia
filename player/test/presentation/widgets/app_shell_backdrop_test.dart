import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/ambient_backdrop.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';

import '../../test_utils/mock_network_images.dart';

/// A minimal stand-in for the shell: it watches the backdrop controller and
/// renders an [AmbientBackdrop] just like [AppShell] does, while [screen]
/// publishes a source from its own build.
Widget _shellHost(Widget screen) {
  return ProviderScope(
    child: MaterialApp(
      home: Consumer(
        builder: (context, ref, _) {
          final source = ref.watch(ambientBackdropControllerProvider);
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                Positioned.fill(
                  child: AmbientBackdrop(
                    imageUrl: source.imageUrl,
                    id: source.id,
                  ),
                ),
                screen,
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// A fake browse screen that publishes a fixed source from build.
class _PublishingScreen extends ConsumerWidget {
  final BackdropSource source;
  const _PublishingScreen(this.source);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    publishBackdropSource(ref, source);
    return const SizedBox.shrink();
  }
}

void main() {
  group('AmbientBackdropController', () {
    test('starts on the static fallback (none)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(ambientBackdropControllerProvider),
        BackdropSource.none,
      );
    });

    test('set updates the source; equal source is a no-op', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(
        ambientBackdropControllerProvider.notifier,
      );

      const a = BackdropSource(imageUrl: 'u', id: 'a');
      notifier.set(a);
      expect(container.read(ambientBackdropControllerProvider), a);

      // Re-setting the same value keeps state identical (no crossfade churn).
      notifier.set(const BackdropSource(imageUrl: 'u', id: 'a'));
      expect(container.read(ambientBackdropControllerProvider), a);
    });

    test('clear returns to the static fallback', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(
        ambientBackdropControllerProvider.notifier,
      );

      notifier.set(const BackdropSource(imageUrl: 'u', id: 'a'));
      notifier.clear();
      expect(
        container.read(ambientBackdropControllerProvider),
        BackdropSource.none,
      );
    });
  });

  group('shell backdrop integration', () {
    testWidgets('a screen publishing artwork feeds the backdrop with the URL', (
      tester,
    ) async {
      await mockNetworkImages(() async {
        await tester.pumpWidget(
          _shellHost(
            const _PublishingScreen(
              BackdropSource(imageUrl: 'https://example.com/hero.jpg', id: 'h'),
            ),
          ),
        );
        // Let the post-frame publish run and rebuild the shell.
        await tester.pump();
        await tester.pump();

        final backdrop = tester.widget<AmbientBackdrop>(
          find.byType(AmbientBackdrop),
        );
        expect(backdrop.imageUrl, 'https://example.com/hero.jpg');
        expect(backdrop.id, 'h');
      });
    });

    testWidgets('a screen publishing none renders the static fallback', (
      tester,
    ) async {
      await tester.pumpWidget(
        _shellHost(const _PublishingScreen(BackdropSource.none)),
      );
      await tester.pump();
      await tester.pump();

      final backdrop = tester.widget<AmbientBackdrop>(
        find.byType(AmbientBackdrop),
      );
      expect(backdrop.imageUrl, isNull);
      // No artwork image is fetched for the static fallback.
      expect(find.byType(ImageFiltered), findsNothing);
    });
  });

  group('hover override feeds the shell backdrop (U8/R9)', () {
    testWidgets('a hover override shows over a none default; clearing reverts', (
      tester,
    ) async {
      await mockNetworkImages(() async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) {
                  final source = ref.watch(ambientBackdropControllerProvider);
                  return Scaffold(
                    backgroundColor: Colors.transparent,
                    body: AmbientBackdrop(
                      imageUrl: source.imageUrl,
                      id: source.id,
                    ),
                  );
                },
              ),
            ),
          ),
        );
        // Screen default is the calm fallback.
        await tester.pump();
        expect(
          tester.widget<AmbientBackdrop>(find.byType(AmbientBackdrop)).imageUrl,
          isNull,
        );

        // A hovered poster publishes its artwork as an override (the WidgetRef
        // path is covered in ambient_backdrop_tint_test; here we drive the
        // notifier directly to assert it flows to the shell backdrop).
        final notifier = container.read(
          ambientBackdropControllerProvider.notifier,
        );
        notifier.setHover(
          const BackdropSource(imageUrl: 'https://example.com/h.jpg', id: 'h'),
        );
        await tester.pump();
        expect(
          tester.widget<AmbientBackdrop>(find.byType(AmbientBackdrop)).imageUrl,
          'https://example.com/h.jpg',
        );

        // Moving off clears the override back to the default fallback.
        notifier.clearHover();
        await tester.pump();
        expect(
          tester.widget<AmbientBackdrop>(find.byType(AmbientBackdrop)).imageUrl,
          isNull,
        );
      });
    });
  });
}
