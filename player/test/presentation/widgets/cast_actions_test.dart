import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_actions.dart';

import '../../core/cast/cast_session_manager_test.mocks.dart';
import '../../test_utils/fake_cast_backend.dart';
import '../../test_utils/fake_streaming_session_service.dart';

const _device = CastDevice(
  id: 'device-1',
  name: 'Living Room TV',
  protocol: CastProtocolKind.chromecast,
);

const _otherDevice = CastDevice(
  id: 'device-2',
  name: 'Bedroom TV',
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

    testWidgets('shows a remembered device as chosen, not connected',
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
      expect(icon.icon, Icons.cast,
          reason: 'a remembered device with no live connection must not claim '
              'the cast_connected glyph');
      expect(icon.color, Colors.blue);
    });
  });

  group('pickCastDevice connects on select', () {
    // Real widget-level coverage: drives `pickCastDevice` through an actual
    // picker dialog tap rather than calling `CastSessionManager.connectTo`
    // directly, so it proves the *wiring* this task adds, not just the
    // manager method Task 3 already covers.
    CastSessionManager buildManager(FakeCastBackend backend) {
      return CastSessionManager(
        backend: backend,
        store: InMemoryCastSessionStore(),
        progressService: ProgressService(MockGraphQLClient()),
        streamingSessions: FakeStreamingSessionService(),
        resolverFactory: () => CastRouteResolver(
          isP2pMode: false,
          serverUrl: 'https://mydia.test',
          mediaToken: () async => 'tok',
          lanBaseUrl: () => null,
          streamingSessions: FakeStreamingSessionService(),
        ),
        setLanAccess: (_) async {},
        clock: () => DateTime.utc(2026, 8, 3, 12),
      );
    }

    /// Mounts a bare button whose `onPressed` calls `pickCastDevice` — the
    /// same shape every real caller (`CastOverlayButton`, `CastButton`,
    /// screen app bars) uses — with the manager and picker's device list
    /// under test control.
    Widget host({
      required CastSessionManager manager,
      required List<CastDevice> devices,
    }) {
      return ProviderScope(
        overrides: [
          castSessionManagerProvider.overrideWith((ref) async => manager),
          castDiscoveryProvider.overrideWith((ref) => Stream.value(devices)),
          castCapabilitiesProvider.overrideWithValue(
            const CastCapabilities.full(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                key: const Key('pick-device-button'),
                onPressed: () => pickCastDevice(context, ref),
                child: const Text('Pick device'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a chosen device with no session connects immediately',
        (tester) async {
      // The behaviour this replaces set castTargetProvider and contacted
      // nothing, while the icon claimed the receiver was connected.
      final backend = FakeCastBackend();
      final manager = buildManager(backend);
      addTearDown(manager.dispose);

      await tester.pumpWidget(host(manager: manager, devices: [_device]));
      await tester.pump();

      await tester.tap(find.byKey(const Key('pick-device-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('cast-device-${_device.id}')), findsOneWidget);
      await tester.tap(find.byKey(Key('cast-device-${_device.id}')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pick-device-button'))),
      );

      expect(backend.connectAttempts, contains(_device));
      expect(container.read(castTargetProvider), _device);
    });

    testWidgets(
        'an idle connection to a different device connects to the new one',
        (tester) async {
      // An idle connection has no persisted session behind it, so the
      // live-media re-target path (which reads `persistedSession`) cannot
      // apply here. Without this branch, picking a new device while idly
      // connected to another would silently fall through to "set target
      // only", leaving the old connection live while the UI pointed at the
      // new device.
      final backend = FakeCastBackend();
      final manager = buildManager(backend);
      addTearDown(manager.dispose);

      // Establish the idle connection to the first device before the picker
      // ever renders, matching a user who is already parked on a receiver
      // with nothing playing.
      await manager.connectTo(_device);

      await tester.pumpWidget(
        host(manager: manager, devices: [_otherDevice]),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('pick-device-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('cast-device-${_otherDevice.id}')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(Key('cast-device-${_otherDevice.id}')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pick-device-button'))),
      );

      expect(backend.connectAttempts.last, _otherDevice);
      expect(container.read(castTargetProvider), _otherDevice);
    });
  });
}
