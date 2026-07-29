import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_device_picker.dart';

void main() {
  Future<void> pumpPicker(
    WidgetTester tester, {
    required AsyncValue<List<CastDevice>> devices,
    CastCapabilities capabilities = const CastCapabilities.full(),
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        castDiscoveryProvider.overrideWith((ref) => const Stream.empty()),
        castCapabilitiesProvider.overrideWithValue(capabilities),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CastDevicePickerDialog(debugDevicesOverride: devices),
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

  testWidgets('admits it found nothing once the sweep is over',
      (tester) async {
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

  testWidgets('shows a generic error for other discovery failures',
      (tester) async {
    await pumpPicker(
      tester,
      devices: AsyncValue.error(Exception('boom'), StackTrace.empty),
    );

    expect(find.byKey(const Key('cast-picker-error')), findsOneWidget);
  });
}
