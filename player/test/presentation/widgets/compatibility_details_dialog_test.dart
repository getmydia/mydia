import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/compatibility/compatibility_provider.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/presentation/widgets/compatibility_details_dialog.dart';

Future<void> pumpDialog(WidgetTester tester, CompatibilityState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CompatibilityDetailsDialog(state: state),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows all three versions for a player-side mismatch',
      (tester) async {
    await pumpDialog(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.playerUpdateRequired,
        playerVersion: '0.8.0',
        serverVersion: '0.9.0',
        requiredVersion: '0.9.0',
      ),
    );

    expect(find.text('0.8.0'), findsOneWidget);
    expect(find.text('0.9.0'), findsNWidgets(2));
    expect(find.textContaining('This app'), findsOneWidget);
  });

  testWidgets('names the server as the side behind for a server mismatch',
      (tester) async {
    await pumpDialog(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.serverUpdateRequired,
        playerVersion: '0.10.0',
        serverVersion: '0.8.0',
        requiredVersion: '0.9.0',
      ),
    );

    expect(find.textContaining('This server'), findsOneWidget);
  });

  testWidgets('renders without a server version', (tester) async {
    await pumpDialog(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.playerUpdateRecommended,
        playerVersion: '0.8.0',
      ),
    );

    expect(find.text('Unknown'), findsOneWidget);
  });
}
