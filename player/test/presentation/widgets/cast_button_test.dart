import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not re-exported by the main `flutter_riverpod.dart` barrel in
// Riverpod 3.x; it lives in the `misc.dart` sub-library alongside other
// advanced/library-author types (see `test/test_utils/riverpod_helpers.dart`).
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_button.dart';

const _device = CastDevice(
  id: 'device-1',
  name: 'Living Room TV',
  protocol: CastProtocolKind.chromecast,
);

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required CastCapabilities capabilities,
    VoidCallback? onPressed,
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        castCapabilitiesProvider.overrideWithValue(capabilities),
        ...overrides,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CastButton(onPressed: onPressed ?? () {}),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('renders when the build has cast capability', (tester) async {
    await pumpButton(tester, capabilities: const CastCapabilities.full());

    expect(find.byKey(const Key('cast-button')), findsOneWidget);
  });

  testWidgets('is absent when the build has no cast capability at all',
      (tester) async {
    await pumpButton(tester, capabilities: const CastCapabilities.web());

    expect(find.byKey(const Key('cast-button')), findsNothing);
  });

  testWidgets('still renders with only one protocol capable (iOS)',
      (tester) async {
    await pumpButton(tester, capabilities: const CastCapabilities.iOS());

    expect(find.byKey(const Key('cast-button')), findsOneWidget);
  });

  testWidgets('invokes onPressed when tapped', (tester) async {
    var tapped = false;
    await pumpButton(
      tester,
      capabilities: const CastCapabilities.full(),
      onPressed: () => tapped = true,
    );

    await tester.tap(find.byKey(const Key('cast-button')));
    await tester.pump();

    expect(tapped, isTrue);
  });

  testWidgets('shows the idle icon and neutral tooltip with no target',
      (tester) async {
    await pumpButton(tester, capabilities: const CastCapabilities.full());

    final icon = tester.widget<Icon>(find.descendant(
      of: find.byKey(const Key('cast-button')),
      matching: find.byType(Icon),
    ));
    expect(icon.icon, Icons.cast);
    expect(icon.color, Colors.white);

    final button = tester.widget<IconButton>(
      find.byKey(const Key('cast-button')),
    );
    expect(button.tooltip, 'Cast to device');
  });

  /// Reads the single Icon inside the button. The connecting state nests its
  /// icon in a Stack alongside a progress ring, so this deliberately finds a
  /// descendant rather than the button's direct child.
  Icon iconOf(WidgetTester tester) => tester.widget<Icon>(find.descendant(
        of: find.byKey(const Key('cast-button')),
        matching: find.byType(Icon),
      ));

  String? tooltipOf(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const Key('cast-button'))).tooltip;

  testWidgets('a remembered device with no connection is not "connected"',
      (tester) async {
    await pumpButton(
      tester,
      capabilities: const CastCapabilities.full(),
      overrides: [
        castConnectionProvider.overrideWithValue(
          CastConnection.chosenOffline,
        ),
        castDisplayDeviceProvider.overrideWithValue(_device),
      ],
    );

    expect(iconOf(tester).icon, Icons.cast,
        reason: 'cast_connected is the platform glyph for owning a receiver; '
            'a device nothing is connected to has not earned it');
    expect(iconOf(tester).color, Colors.blue);
    expect(tooltipOf(tester), '${_device.name} — not connected');
  });

  testWidgets('shows a progress ring while connecting', (tester) async {
    await pumpButton(
      tester,
      capabilities: const CastCapabilities.full(),
      overrides: [
        castConnectionProvider.overrideWithValue(CastConnection.connecting),
        castDisplayDeviceProvider.overrideWithValue(_device),
      ],
    );

    expect(iconOf(tester).icon, Icons.cast);
    expect(
      find.descendant(
        of: find.byKey(const Key('cast-button')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(tooltipOf(tester), 'Connecting to ${_device.name}…');
  });

  testWidgets('a live connection with no media shows cast_connected',
      (tester) async {
    await pumpButton(
      tester,
      capabilities: const CastCapabilities.full(),
      overrides: [
        castConnectionProvider.overrideWithValue(
          CastConnection.connectedIdle,
        ),
        castDisplayDeviceProvider.overrideWithValue(_device),
      ],
    );

    expect(iconOf(tester).icon, Icons.cast_connected);
    expect(iconOf(tester).color, Colors.blue);
    expect(tooltipOf(tester), 'Connected to ${_device.name}');
  });

  testWidgets('an active cast shows cast_connected and a casting tooltip',
      (tester) async {
    await pumpButton(
      tester,
      capabilities: const CastCapabilities.full(),
      overrides: [
        castConnectionProvider.overrideWithValue(CastConnection.casting),
        castDisplayDeviceProvider.overrideWithValue(_device),
      ],
    );

    expect(iconOf(tester).icon, Icons.cast_connected);
    expect(iconOf(tester).color, Colors.blue);
    expect(tooltipOf(tester), 'Casting to ${_device.name}');
  });

  testWidgets('cast_connected never appears without a live connection',
      (tester) async {
    for (final state in [
      CastConnection.none,
      CastConnection.connecting,
      CastConnection.chosenOffline,
    ]) {
      await pumpButton(
        tester,
        capabilities: const CastCapabilities.full(),
        overrides: [
          castConnectionProvider.overrideWithValue(state),
          castDisplayDeviceProvider.overrideWithValue(_device),
        ],
      );

      expect(iconOf(tester).icon, isNot(Icons.cast_connected),
          reason: '$state must not render the connected glyph');
    }
  });
}
