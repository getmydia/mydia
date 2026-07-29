import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/presentation/widgets/cast_button.dart';

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required CastCapabilities capabilities,
    VoidCallback? onPressed,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        castCapabilitiesProvider.overrideWithValue(capabilities),
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
}
