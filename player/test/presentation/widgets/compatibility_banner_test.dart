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

    // A regression that painted the banner chrome (Container/Icon) without a
    // Text child would still satisfy a Text-only assertion, so pin the
    // absence of the chrome widgets too, not just the absence of Text.
    expect(find.byType(Text), findsNothing);
    expect(find.byType(Container), findsNothing);
    expect(find.byType(Icon), findsNothing);
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
    expect(find.byType(Container), findsNothing);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('renders nothing for a dismissed soft nudge', (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.playerUpdateRecommended,
        playerVersion: '0.8.0',
        serverVersion: '0.9.0',
        requiredVersion: '0.9.0',
        dismissed: true,
      ),
    );

    expect(find.byType(Text), findsNothing);
    expect(find.byType(Container), findsNothing);
    expect(find.byType(Icon), findsNothing);
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

  testWidgets(
      'a recommended server mismatch is dismissible and offers no update button',
      (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.serverUpdateRecommended,
        playerVersion: '0.10.0',
        serverVersion: '0.9.0',
        requiredVersion: '0.10.0',
      ),
    );

    expect(find.textContaining('A newer Mydia server'), findsOneWidget);
    // The user cannot update someone else's server, hard or soft mismatch.
    expect(find.text('Update'), findsNothing);
    expect(find.text('Details'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
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
    // Both actions show together: the player side can act on Update, and can
    // still dismiss the nudge.
    expect(find.text('Update'), findsOneWidget);
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
