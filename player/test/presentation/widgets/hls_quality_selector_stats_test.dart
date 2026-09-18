import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/presentation/widgets/hls_quality_selector.dart';

Future<void> openPicker(
  WidgetTester tester, {
  bool? statsEnabled,
  ValueChanged<bool>? onStatsChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showQualityPicker(
              context,
              const [QualityRung.auto, QualityRung.original],
              QualityRung.auto,
              autoSubtitle: 'Auto',
              originalSubtitle: 'Original',
              statsEnabled: statsEnabled,
              onStatsChanged: onStatsChanged,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  // The settings screen calls this with neither parameter and must not
  // grow a stats row it cannot wire.
  testWidgets('no stats row without both parameters', (tester) async {
    await openPicker(tester);

    expect(find.byKey(statsToggleKey), findsNothing);
  });

  // Proves the gate is `&&`, not `||`: either parameter alone must not be
  // enough to grow the row. Without this, a regression to `||` would show a
  // dead toggle in the settings screen's standing-preference picker, which
  // passes neither parameter and has nothing to wire an `onChanged` to.
  testWidgets('no stats row with only statsEnabled supplied', (tester) async {
    await openPicker(tester, statsEnabled: true);

    expect(find.byKey(statsToggleKey), findsNothing);
  });

  testWidgets('no stats row with only onStatsChanged supplied', (tester) async {
    await openPicker(tester, onStatsChanged: (_) {});

    expect(find.byKey(statsToggleKey), findsNothing);
  });

  testWidgets('the stats row reflects the flag', (tester) async {
    await openPicker(tester, statsEnabled: true, onStatsChanged: (_) {});

    final toggle = tester.widget<SwitchListTile>(
      find.byKey(statsToggleKey),
    );
    expect(toggle.value, isTrue);
  });

  // Flipping it must not close the sheet: a viewer comparing rungs wants
  // the numbers up while they keep choosing.
  testWidgets('flipping the row reports and leaves the sheet open',
      (tester) async {
    final flips = <bool>[];
    await openPicker(
      tester,
      statsEnabled: false,
      onStatsChanged: flips.add,
    );

    await tester.tap(find.byKey(statsToggleKey));
    await tester.pumpAndSettle();

    expect(flips, [true]);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(statsToggleKey),
    );
    expect(toggle.value, isTrue,
        reason: 'the switch itself must move, not just report the change '
            'and survive the tap');
  });
}
