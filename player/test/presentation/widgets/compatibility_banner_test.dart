import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/compatibility/compatibility_provider.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/presentation/widgets/compatibility_banner.dart';

/// Pumps the banner over a fixed state, bypassing the provider's own fetch.
Future<void> pumpBanner(WidgetTester tester, CompatibilityState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        compatibilityProvider.overrideWith(() => _FixedNotifier(state)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: CompatibilityBanner()),
      ),
    ),
  );
  await tester.pump();
}

class _FixedNotifier extends CompatibilityNotifier {
  _FixedNotifier(this._state);
  final CompatibilityState _state;

  @override
  Future<CompatibilityState> build() async => _state;
}

void main() {
  testWidgets('renders nothing when compatible', (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.compatible,
        playerVersion: '0.9.0',
        serverVersion: '0.9.0',
      ),
    );

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('renders nothing when the verdict is unknown', (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.unknown,
        playerVersion: '0.9.0',
      ),
    );

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('a required player mismatch shows a non-dismissible banner',
      (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.playerUpdateRequired,
        playerVersion: '0.8.0',
        serverVersion: '0.9.0',
        requiredVersion: '0.9.0',
      ),
    );

    expect(find.textContaining('Update Mydia Player'), findsOneWidget);
    expect(find.textContaining('0.9.0'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.text('Update'), findsOneWidget);
  });

  testWidgets('a required server mismatch offers no update button',
      (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.serverUpdateRequired,
        playerVersion: '0.10.0',
        serverVersion: '0.8.0',
        requiredVersion: '0.9.0',
      ),
    );

    expect(find.textContaining('This server is out of date'), findsOneWidget);
    // The user cannot update someone else's server.
    expect(find.text('Update'), findsNothing);
    expect(find.text('Details'), findsOneWidget);
  });

  testWidgets('a recommended mismatch shows a dismiss affordance',
      (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.playerUpdateRecommended,
        playerVersion: '0.8.0',
        serverVersion: '0.9.0',
        requiredVersion: '0.9.0',
      ),
    );

    expect(find.textContaining('A newer Mydia Player'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('tapping Details opens the dialog', (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.playerUpdateRequired,
        playerVersion: '0.8.0',
        serverVersion: '0.9.0',
        requiredVersion: '0.9.0',
      ),
    );

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(find.text('Version mismatch'), findsOneWidget);
  });
}
