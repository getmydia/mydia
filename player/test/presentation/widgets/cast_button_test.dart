import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not re-exported by the main `flutter_riverpod.dart` barrel in
// Riverpod 3.x; it lives in the `misc.dart` sub-library alongside other
// advanced/library-author types (see `test/test_utils/riverpod_helpers.dart`).
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_target.dart';
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

  testWidgets(
      'reflects a chosen-but-idle target as active, with a "will play on" tooltip',
      (tester) async {
    await pumpButton(tester, capabilities: const CastCapabilities.full());

    // Set the target after the provider is live, matching how pickCastDevice
    // records an intent for the next playback.
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
    expect(icon.color, Colors.blue);

    final button = tester.widget<IconButton>(
      find.byKey(const Key('cast-button')),
    );
    expect(button.tooltip, 'Will play on ${_device.name}');
  });

  testWidgets('an active cast session takes priority over the tooltip text',
      (tester) async {
    await pumpButton(
      tester,
      capabilities: const CastCapabilities.full(),
      overrides: [
        isCastingProvider.overrideWithValue(true),
        currentCastDeviceProvider.overrideWithValue(_device),
      ],
    );

    final icon = tester.widget<Icon>(find.descendant(
      of: find.byKey(const Key('cast-button')),
      matching: find.byType(Icon),
    ));
    expect(icon.icon, Icons.cast_connected);
    expect(icon.color, Colors.blue);

    final button = tester.widget<IconButton>(
      find.byKey(const Key('cast-button')),
    );
    expect(button.tooltip, 'Casting to ${_device.name}');
  });
}
