import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/compatibility/compatibility_provider.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/update/install_environment.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/app_update.dart';
import 'package:player/presentation/widgets/compatibility_banner.dart';

/// Pumps the banner over a fixed state, bypassing the provider's own fetch.
Future<void> pumpBanner(
  WidgetTester tester,
  CompatibilityState state, {
  UpdateState updateState = const UpdateState(),
  InstallEnvironment? environmentOverride,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        compatibilityProvider.overrideWith(() => _FixedNotifier(state)),
        updateProvider.overrideWith(() => _FakeUpdateNotifier(updateState)),
      ],
      // No longer const: CompatibilityBanner now takes a runtime argument.
      child: MaterialApp(
        home: Scaffold(
          body: CompatibilityBanner(environmentOverride: environmentOverride),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Pumps the banner inside a real router, for the branch that navigates.
///
/// `context.go` needs a GoRouter in the tree. Asserting only that the confirm
/// dialog is absent would pass even if the button did nothing, so the
/// navigation has to land somewhere observable.
Future<void> pumpRoutedBanner(
  WidgetTester tester,
  CompatibilityState state, {
  UpdateState updateState = const UpdateState(),
}) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, stateArg) =>
            const Scaffold(body: CompatibilityBanner()),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, stateArg) =>
            const Scaffold(body: Text('settings-screen')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        compatibilityProvider.overrideWith(() => _FixedNotifier(state)),
        updateProvider.overrideWith(() => _FakeUpdateNotifier(updateState)),
      ],
      child: MaterialApp.router(routerConfig: router),
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

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state);
  final UpdateState _state;
  int applyCount = 0;

  @override
  UpdateState build() => _state;

  @override
  Future<void> applyUpdate() async => applyCount++;
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

  testWidgets(
      'with an update in hand, Update starts it rather than '
      'navigating to Settings', (tester) async {
    await pumpBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.playerUpdateRequired,
        playerVersion: '0.8.0',
        serverVersion: '0.9.0',
        requiredVersion: '0.9.0',
      ),
      updateState: UpdateState(
        currentVersion: '0.8.0',
        availableUpdate: AppUpdate(
          version: '0.9.0',
          downloadUrl: 'https://example.invalid/player-linux-v0.9.0.tar.gz',
          releaseNotesUrl: 'https://example.invalid/releases/0.9.0',
          releaseTitle: 'Faster library scans',
          publishedAt: DateTime.utc(2026, 8, 1),
        ),
      ),
      environmentOverride: InstallEnvironment.inPlace,
    );

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    // startUpdate's in-place branch confirms first. Reaching the dialog is
    // what proves the button no longer just navigates.
    expect(find.textContaining('Mydia will close and update'), findsOneWidget);
  });

  testWidgets('with no update in hand, Update still routes to Settings',
      (tester) async {
    // Covers macOS, where Sparkle owns checking and availableUpdate stays
    // null, and the window before the first check lands.
    //
    // This needs a real router. Asserting only that the confirm dialog is
    // absent would pass even if the button did nothing at all, so the test
    // has to observe the navigation actually landing somewhere.
    await pumpRoutedBanner(
      tester,
      const CompatibilityState(
        verdict: CompatibilityVerdict.playerUpdateRequired,
        playerVersion: '0.8.0',
        serverVersion: '0.9.0',
        requiredVersion: '0.9.0',
      ),
    );

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(find.text('settings-screen'), findsOneWidget);
    expect(find.textContaining('Mydia will close and update'), findsNothing);
  });
}
