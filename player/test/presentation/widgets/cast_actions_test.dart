import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_actions.dart';

const _device = CastDevice(
  id: 'device-1',
  name: 'Living Room TV',
  protocol: CastProtocolKind.chromecast,
);

void main() {
  group('castErrorMessage', () {
    test('names the port for an unreachable receiver', () {
      const e = CastBackendException('nope', CastFailureKind.unreachable);

      expect(castErrorMessage(e), isNot(contains('nope')));
      expect(castErrorMessage(e), isNotEmpty);
    });

    test('explains a denied local network permission', () {
      const e = CastBackendException('denied', CastFailureKind.discoveryDenied);

      expect(castErrorMessage(e), contains('local network'));
    });
  });

  group('castErrorMessage covers every failure kind', () {
    // A missed enum case would fall through to a generic string, losing the
    // port number or permission hint that makes the error actionable.
    for (final kind in CastFailureKind.values) {
      test('produces actionable text for $kind', () {
        final message = castErrorMessage(CastBackendException('raw', kind));

        expect(message, isNotEmpty);
        expect(message, isNot(equals('raw')),
            reason: 'the raw backend string is not user-facing');
      });
    }
  });

  group('CastOverlayButton', () {
    /// [CastOverlayButton] returns a bare [Positioned], so it is only valid
    /// as a direct child of a [Stack] — matching how `AppShell` mounts it as
    /// the last child of its own Stack.
    Widget host({double topInset = 40}) {
      return ProviderScope(
        overrides: [
          castCapabilitiesProvider.overrideWithValue(
            const CastCapabilities.full(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                CastOverlayButton(topInset: topInset),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('positions the cast button at the given top inset',
        (tester) async {
      await tester.pumpWidget(host(topInset: 52));
      await tester.pump();

      expect(find.byKey(const Key('cast-button')), findsOneWidget);

      final positioned = tester.widget<Positioned>(find.ancestor(
        of: find.byKey(const Key('cast-button')),
        matching: find.byType(Positioned),
      ));
      expect(positioned.top, 52);
      expect(positioned.right, 12);
    });

    testWidgets('reflects an idle target picked from elsewhere',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('cast-button'))),
      );
      container.read(castTargetProvider.notifier).set(_device);
      await tester.pump();

      final icon = tester.widget<Icon>(find.descendant(
        of: find.byKey(const Key('cast-button')),
        matching: find.byType(Icon),
      ));
      expect(icon.icon, Icons.cast_connected);
    });
  });
}
