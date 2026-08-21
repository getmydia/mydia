import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/app.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/remote/ambient_targets.dart';

import 'core/remote/ambient_targets_test.dart' hide main;

/// Auth notifier whose state the test drives directly — copied from
/// `app_cast_bar_mounting_test.dart`'s own fake rather than shared, to keep
/// this file's only dependency on that one confined to the `pumpApp`
/// pattern it establishes for mounting the real `MyApp`.
class _FakeAuthNotifier extends AuthStateNotifier {
  _FakeAuthNotifier(this._initial);

  final AsyncValue<AuthStatus> _initial;

  @override
  AsyncValue<AuthStatus> build() => _initial;
}

/// Proves the wiring gap this file exists to close: that a real OS
/// background/foreground transition — not a Riverpod listener count
/// dropping to zero — actually reaches `AmbientTargets.onBackground()` and
/// `sweep()`.
///
/// `AmbientTargets`' own unit tests (`ambient_targets_test.dart`) already
/// cover that `onBackground()`/`sweep()` behave correctly in isolation, and
/// `ambient_lifecycle_test.dart` covers that `AmbientLifecycleBinding` maps
/// `AppLifecycleState` transitions onto those calls correctly. Neither
/// proves `_MyAppState.didChangeAppLifecycleState` (`app.dart`) is actually
/// the thing invoking the binding on a real, framework-delivered lifecycle
/// event — which is exactly the gap that shipped: the class was correct,
/// the call site was missing. This test pumps the real `MyApp` and drives
/// `WidgetsBinding.instance.handleAppLifecycleStateChanged`, the same entry
/// point the OS uses, rather than calling any of app.dart's internals
/// directly.
void main() {
  /// Pumps the real `MyApp` with [targets] standing in for
  /// [ambientTargetsProvider], the same minimal-override pattern
  /// `app_cast_bar_mounting_test.dart` uses to get `MyApp` on screen without
  /// a live p2p/GraphQL stack.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    required AmbientTargets targets,
  }) async {
    final container = ProviderContainer(overrides: [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
      authStateProvider.overrideWith(() =>
          _FakeAuthNotifier(const AsyncValue.data(AuthStatus.authenticated))),
      asyncGraphqlClientProvider
          .overrideWith((ref) => Completer<GraphQLClient>().future),
      castSessionProvider.overrideWith((ref) => Stream.value(null)),
      castSessionManagerProvider
          .overrideWith((ref) => Completer<CastSessionManager>().future),
      ambientTargetsProvider.overrideWithValue(targets),
    ]);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MyApp(),
    ));
    await tester.pump();
    return container;
  }

  /// Unmounts the pumped tree and disposes [container] before the test body
  /// returns.
  ///
  /// `container.dispose()` is safe to call again later via `addTearDown` —
  /// Riverpod documents repeat calls as a no-op — but calling it *only*
  /// there is too late for this file: overriding [ambientTargetsProvider]
  /// with a real, functioning [AmbientTargets] (rather than the `null` the
  /// unoverridden provider chain resolves to in
  /// `app_cast_bar_mounting_test.dart`) means `ambientPlayingProvider`
  /// (`cast_providers.dart`) actually starts its 30-second resweep `Timer`,
  /// and a held target starts [AmbientTargets]' own 5-second poll `Timer`.
  /// `flutter_test` checks for pending timers immediately after the test
  /// body returns, *before* `addTearDown` callbacks run — so without this,
  /// any test that ends holding a target fails on "A Timer is still pending"
  /// regardless of the `addTearDown` already registered for it. Unmounting
  /// first (rather than disposing the container outright) lets `MyApp` and
  /// `CastMiniController` run their own normal widget disposal — including
  /// `_MyAppState.dispose()` removing its lifecycle observer — before the
  /// container underneath them goes away.
  Future<void> teardown(
      WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
  }

  /// Steps a *full, valid* [AppLifecycleState] sequence into the background,
  /// pumping after each step.
  ///
  /// Flutter itself enforces a state machine on these transitions —
  /// `AppLifecycleListener` (which `FocusManager` always registers, so this
  /// applies to every widget test, not just this one) asserts
  /// `paused` is only reachable from `hidden`, which itself is only reachable
  /// from `inactive`. A raw `resumed -> paused` jump throws
  /// `'Invalid state transition'` before `_MyAppState` ever sees it. Real OS
  /// backgrounding always produces this exact sequence — see
  /// `AppLifecycleState.hidden`'s own dartdoc — so stepping through it here
  /// is what makes this test a faithful stand-in for the real thing, not a
  /// simplification of it.
  Future<void> goToBackground(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  /// The mirror image of [goToBackground]: `paused -> hidden -> inactive ->
  /// resumed`, the only sequence Flutter's own state machine accepts back
  /// out of `paused`.
  Future<void> goToForeground(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  testWidgets(
      'a real OS background transition drops held ambient targets, and '
      'foreground re-establishes them', (tester) async {
    final scripted = ScriptedProbe({
      'node-tv': playingSnapshot(title: 'Blade Runner'),
    });
    final targets = AmbientTargets(
      rosterSource: rosterOf(['node-tv']),
      probe: scripted.call,
    );
    addTearDown(targets.dispose);

    final container = await pumpApp(tester, targets: targets);

    // `ambientPlayingProvider`'s own first-listen sweep (`cast_providers.dart`)
    // is what seeds this, the same as it does in production — proving the
    // baseline is real, not manufactured by this test.
    expect(await targets.playing.first, isNotEmpty,
        reason: 'baseline: a target is already held before backgrounding');

    await goToBackground(tester);

    expect(await targets.playing.first, isEmpty,
        reason: 'app.dart must call AmbientTargets.onBackground() on a '
            'real paused transition, not only when every Riverpod '
            'listener drops');

    await goToForeground(tester);
    // sweep() is async; give its microtask chain a further beat to settle.
    await tester.pump();

    expect(await targets.playing.first, isNotEmpty,
        reason: 'recovery is the next foreground sweep');

    // Leave it backgrounded again so no live Timer is pending when this
    // test body returns — see `teardown`'s dartdoc.
    await goToBackground(tester);
    await teardown(tester, container);
  });

  testWidgets('an inactive transition does not drop held ambient targets',
      (tester) async {
    final scripted = ScriptedProbe({
      'node-tv': playingSnapshot(title: 'Blade Runner'),
    });
    final targets = AmbientTargets(
      rosterSource: rosterOf(['node-tv']),
      probe: scripted.call,
    );
    addTearDown(targets.dispose);

    final container = await pumpApp(tester, targets: targets);
    expect(await targets.playing.first, isNotEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(await targets.playing.first, isNotEmpty,
        reason: 'a notification shade pull (inactive) must not tear down a '
            'held connection');

    // Back to resumed (the only valid move from inactive-without-hidden),
    // then background before returning, matching `teardown`'s requirement.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await goToBackground(tester);
    await teardown(tester, container);
  });
}
