import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_device_picker.dart';

const _chromecast = CastDevice(
  id: 'cc-1',
  name: 'Living Room',
  protocol: CastProtocolKind.chromecast,
);

const _otherChromecast = CastDevice(
  id: 'cc-2',
  name: 'Bedroom',
  protocol: CastProtocolKind.chromecast,
);

void main() {
  Future<void> pumpPicker(
    WidgetTester tester, {
    required AsyncValue<List<CastDevice>> devices,
    CastCapabilities capabilities = const CastCapabilities.full(),
    List<Override> overrides = const [],
    bool? settingsAvailable,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        castDiscoveryProvider.overrideWith((ref) => const Stream.empty()),
        castCapabilitiesProvider.overrideWithValue(capabilities),
        ...overrides,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CastDevicePickerDialog(
            debugDevicesOverride: devices,
            debugSettingsAvailableOverride: settingsAvailable,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('shows a searching state while the list is empty',
      (tester) async {
    await pumpPicker(tester, devices: const AsyncValue.data([]));

    expect(find.byKey(const Key('cast-picker-searching')), findsOneWidget);
  });

  testWidgets('admits it found nothing once the sweep is over', (tester) async {
    // Otherwise a network with no receivers spins forever with no terminal
    // state and nothing for the user to act on.
    await pumpPicker(tester, devices: const AsyncValue.data([]));

    await tester.pump(const Duration(seconds: 11));

    expect(find.byKey(const Key('cast-picker-empty')), findsOneWidget);
    expect(find.byKey(const Key('cast-picker-searching')), findsNothing);
  });

  testWidgets('a still-loading discovery stream also terminates',
      (tester) async {
    // The discovery stream emits nothing at all until the first device
    // answers, so the loading branch is the one a quiet network actually
    // renders.
    await pumpPicker(tester, devices: const AsyncValue.loading());

    expect(find.byKey(const Key('cast-picker-searching')), findsOneWidget);

    await tester.pump(const Duration(seconds: 11));

    expect(find.byKey(const Key('cast-picker-empty')), findsOneWidget);
  });

  testWidgets('groups devices by protocol', (tester) async {
    await pumpPicker(tester,
        devices: const AsyncValue.data([
          CastDevice(
              id: 'c1',
              name: 'Living Room',
              protocol: CastProtocolKind.chromecast),
          CastDevice(
              id: 'd1', name: 'Bedroom TV', protocol: CastProtocolKind.dlna),
        ]));

    expect(find.byKey(const Key('cast-group-chromecast')), findsOneWidget);
    expect(find.byKey(const Key('cast-group-dlna')), findsOneWidget);
    expect(find.byKey(const Key('cast-device-c1')), findsOneWidget);
    expect(find.byKey(const Key('cast-device-d1')), findsOneWidget);
  });

  testWidgets('shows a Mydia group with what the target is playing',
      (tester) async {
    await pumpPicker(tester,
        devices: const AsyncValue.data([
          CastDevice(
            id: 'node-a',
            name: 'Living Room',
            protocol: CastProtocolKind.mydia,
            metadata: {'nodeId': 'node-a', 'nowPlayingTitle': 'Arrival'},
          ),
        ]));

    expect(find.byKey(const Key('cast-group-mydia')), findsOneWidget);
    expect(find.byKey(const Key('cast-device-node-a')), findsOneWidget);
    expect(find.text('Living Room'), findsOneWidget);
    expect(find.text('Arrival'), findsOneWidget);
  });

  testWidgets(
      'falls back to a placeholder when a Mydia target reports nothing playing',
      (tester) async {
    // Idle, paused, and probe-failed targets all share this: the discovery
    // probe only populates `nowPlayingTitle` when it catches the target
    // actively playing something (see `MydiaCastBackend`).
    await pumpPicker(tester,
        devices: const AsyncValue.data([
          CastDevice(
            id: 'node-b',
            name: 'Bedroom',
            protocol: CastProtocolKind.mydia,
            metadata: {'nodeId': 'node-b'},
          ),
        ]));

    expect(find.byKey(const Key('cast-device-node-b')), findsOneWidget);
    expect(find.text('Nothing playing'), findsOneWidget);
  });

  testWidgets('shows a Mydia group regardless of Chromecast/DLNA capability',
      (tester) async {
    // Not gated on `capabilities`: a Mydia target is reached over the p2p
    // host, not the platform's local-network entitlement.
    await pumpPicker(
      tester,
      capabilities: const CastCapabilities.web(),
      devices: const AsyncValue.data([
        CastDevice(
          id: 'node-c',
          name: 'Kitchen',
          protocol: CastProtocolKind.mydia,
          metadata: {'nodeId': 'node-c'},
        ),
      ]),
    );

    expect(find.byKey(const Key('cast-group-mydia')), findsOneWidget);
  });

  testWidgets(
      'keeps showing devices past the search timeout when devices arrive early',
      (tester) async {
    // Devices are present from the very first frame, so the search-timeout
    // timer should never have been armed; if it fired anyway and flipped
    // `_searchExpired`, this would still pass today (that flag is only read
    // for empty lists), but a stray timer firing after the widget tree
    // changed shape would surface as an exception here.
    await pumpPicker(tester,
        devices: const AsyncValue.data([
          CastDevice(
              id: 'c1',
              name: 'Living Room',
              protocol: CastProtocolKind.chromecast),
        ]));

    await tester.pump(const Duration(seconds: 11));

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('cast-group-chromecast')), findsOneWidget);
  });

  testWidgets('omits the DLNA group when the platform cannot discover it',
      (tester) async {
    await pumpPicker(
      tester,
      devices: const AsyncValue.data([
        CastDevice(
            id: 'c1',
            name: 'Living Room',
            protocol: CastProtocolKind.chromecast),
      ]),
      capabilities: const CastCapabilities.iOS(),
    );

    expect(find.byKey(const Key('cast-group-chromecast')), findsOneWidget);
    expect(find.byKey(const Key('cast-group-dlna')), findsNothing);
  });

  testWidgets('shows an actionable message when discovery is denied',
      (tester) async {
    await pumpPicker(
      tester,
      devices: const AsyncValue.error(
        CastBackendException('denied', CastFailureKind.discoveryDenied),
        StackTrace.empty,
      ),
    );

    expect(
        find.byKey(const Key('cast-picker-permission-denied')), findsOneWidget);
  });

  testWidgets('offers a settings button when discovery is denied on Apple',
      (tester) async {
    await pumpPicker(
      tester,
      devices: const AsyncValue.error(
        CastBackendException('denied', CastFailureKind.discoveryDenied),
        StackTrace.empty,
      ),
      settingsAvailable: true,
    );

    expect(
        find.byKey(const Key('local-network-settings-button')), findsOneWidget);
  });

  testWidgets('withholds the settings button off Apple platforms',
      (tester) async {
    // discoveryDenied also covers Android's multicast lock failing. An
    // Apple-only deep link there fails and then prints macOS instructions,
    // so the panel keeps its explanation and drops the button.
    await pumpPicker(
      tester,
      devices: const AsyncValue.error(
        CastBackendException('denied', CastFailureKind.discoveryDenied),
        StackTrace.empty,
      ),
      settingsAvailable: false,
    );

    expect(
        find.byKey(const Key('cast-picker-permission-denied')), findsOneWidget);
    expect(
        find.byKey(const Key('local-network-settings-button')), findsNothing);
  });

  testWidgets('shows a generic error for other discovery failures',
      (tester) async {
    await pumpPicker(
      tester,
      devices: AsyncValue.error(Exception('boom'), StackTrace.empty),
    );

    expect(find.byKey(const Key('cast-picker-error')), findsOneWidget);
  });

  group('chosen device marking', () {
    testWidgets('marks a connected device with the check and connected glyph',
        (tester) async {
      await pumpPicker(
        tester,
        devices: const AsyncValue.data([_chromecast]),
        overrides: [
          castConnectionProvider.overrideWithValue(
            CastConnection.connectedIdle,
          ),
          castDisplayDeviceProvider.overrideWithValue(_chromecast),
        ],
      );

      final tile = tester.widget<ListTile>(
        find.byKey(Key('cast-device-${_chromecast.id}')),
      );
      expect((tile.leading as Icon).icon, Icons.cast_connected);
      expect((tile.leading as Icon).color, AppColors.primary);
      expect(tile.trailing, isA<Icon>());
    });

    testWidgets('marks a chosen-but-unconnected device without the check',
        (tester) async {
      await pumpPicker(
        tester,
        devices: const AsyncValue.data([_chromecast]),
        overrides: [
          castConnectionProvider.overrideWithValue(
            CastConnection.chosenOffline,
          ),
          castDisplayDeviceProvider.overrideWithValue(_chromecast),
        ],
      );

      final tile = tester.widget<ListTile>(
        find.byKey(Key('cast-device-${_chromecast.id}')),
      );
      expect((tile.leading as Icon).icon, Icons.cast,
          reason: 'the row must not claim a connection the app does not have');
      expect((tile.leading as Icon).color, AppColors.primary,
          reason: 'chosen still gets the accent colour, even unconnected');
      expect(tile.trailing, isNull,
          reason: 'the check mark means connected, not merely chosen');
    });

    testWidgets('leaves other devices unmarked', (tester) async {
      await pumpPicker(
        tester,
        devices: const AsyncValue.data([_chromecast, _otherChromecast]),
        overrides: [
          castConnectionProvider.overrideWithValue(
            CastConnection.connectedIdle,
          ),
          castDisplayDeviceProvider.overrideWithValue(_chromecast),
        ],
      );

      final tile = tester.widget<ListTile>(
        find.byKey(Key('cast-device-${_otherChromecast.id}')),
      );
      expect((tile.leading as Icon).icon, Icons.cast);
      expect((tile.leading as Icon).color, AppColors.textSecondary,
          reason: 'only the chosen device gets the accent colour');
      expect(tile.trailing, isNull);
    });
  });
}
