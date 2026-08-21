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
import 'package:player/presentation/widgets/cast_mini_controller.dart';

/// Auth notifier whose state the test drives directly.
class _FakeAuthNotifier extends AuthStateNotifier {
  _FakeAuthNotifier(this._initial);

  final AsyncValue<AuthStatus> _initial;

  @override
  AsyncValue<AuthStatus> build() => _initial;
}

void main() {
  /// Restoring a cast session builds `castSessionManagerProvider`, whose body
  /// awaits `asyncGraphqlClientProvider`. That provider stays in the loading
  /// state until the user authenticates, so starting the chain beforehand
  /// leaves it in flight indefinitely. If the container is then disposed while
  /// it is still loading — app teardown, or an integration test finishing on
  /// the pairing screen — Riverpod completes the pending future with a
  /// StateError raised *inside* the provider body, where no caller can catch
  /// it. It escapes as an unhandled async error and fails the run, which is
  /// how this surfaced in the Player E2E suite.
  ///
  /// These pin the gate that prevents it: the cast stack is untouched until
  /// auth reports `authenticated`, and is reached once it does.
  group('MyApp cast session restore', () {
    late bool managerBuilt;

    // `asyncGraphqlClientProvider` never completes here, standing in for its
    // real pre-auth behaviour; the manager override awaits it exactly as the
    // real provider body does, so a regression reproduces the original race
    // rather than a sanitised version of it.
    buildOverrides(AsyncValue<AuthStatus> auth) => [
          authStateProvider.overrideWith(() => _FakeAuthNotifier(auth)),
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          asyncGraphqlClientProvider
              .overrideWith((ref) => Completer<GraphQLClient>().future),
          castSessionManagerProvider.overrideWith((ref) async {
            managerBuilt = true;
            await ref.read(asyncGraphqlClientProvider.future);
            throw StateError('unreachable in these tests');
          }),
        ];

    setUp(() => managerBuilt = false);

    Future<void> pumpApp(
      WidgetTester tester,
      AsyncValue<AuthStatus> auth,
    ) async {
      await tester.pumpWidget(ProviderScope(
        overrides: buildOverrides(auth),
        child: const MyApp(),
      ));
      await tester.pump();
    }

    testWidgets('does not touch the cast stack while auth is loading',
        (tester) async {
      await pumpApp(tester, const AsyncValue.loading());

      expect(managerBuilt, isFalse,
          reason: 'the cast stack must not be built while auth is still '
              'loading — its GraphQL dependency cannot resolve yet');
    });

    testWidgets('restores once the user is authenticated', (tester) async {
      await pumpApp(tester, const AsyncValue.data(AuthStatus.authenticated));

      expect(managerBuilt, isTrue,
          reason: 'gating on auth must not disable restore outright');
    });
  });

  /// The second entry point into the cast stack. `CastMiniController` is
  /// mounted on every screen by `app.dart`, and `isCastingProvider` reaches
  /// `castSessionManagerProvider`. Gating `app.dart` alone left this path
  /// initialising the chain pre-auth, which is what actually tripped the E2E
  /// pairing test.
  group('CastMiniController', () {
    testWidgets('does not build the cast stack before authentication',
        (tester) async {
      var managerBuilt = false;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          authStateProvider.overrideWith(
              () => _FakeAuthNotifier(const AsyncValue.loading())),
          asyncGraphqlClientProvider
              .overrideWith((ref) => Completer<GraphQLClient>().future),
          castSessionManagerProvider.overrideWith((ref) async {
            managerBuilt = true;
            await ref.read(asyncGraphqlClientProvider.future);
            throw StateError('unreachable in this test');
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: CastMiniController()),
        ),
      ));
      await tester.pump();

      expect(managerBuilt, isFalse,
          reason: 'the mini controller must not reach the cast stack while '
              'auth is unresolved');
    });
  });

  /// `castSessionProvider` itself had the same hazard as `_restoreCastSession`
  /// and `_initRemoteControlIfEnabled`, but with no guard: `CastMiniController`
  /// starts it running (via `.value`, a plain sync watch — see the "the mini
  /// controller must not reach the cast stack" test above for how little it
  /// takes) the moment auth reports `authenticated`, on every screen, and its
  /// body reads `castSessionManagerProvider.future` with no try/catch of its
  /// own.
  ///
  /// A permanently-loading `Completer().future`, as the two groups above use,
  /// cannot reproduce this one: nothing ever rejects, so nothing ever needs
  /// to escape. What reproduces it is a rejection that arrives *after* the
  /// container is already disposed — exactly what happens in production when
  /// `asyncGraphqlClientProvider` is force-completed with a StateError by
  /// `ElementWithFuture.dispose` (see that class in the riverpod package, and
  /// `castSessionProvider`'s own dartdoc in cast_providers.dart). A `Future`
  /// that resolves on a real delay stands in for that: the delay outlives the
  /// dispose, so the rejection lands on an already-torn-down subscription,
  /// the same way the real one does.
  group('castSessionProvider disposal', () {
    testWidgets('does not leak an unhandled error when disposed mid-loading',
        (tester) async {
      final flutterErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = flutterErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          authStateProvider.overrideWith(() => _FakeAuthNotifier(
              const AsyncValue.data(AuthStatus.authenticated))),
          // Rejects on a real delay chosen to land after this test disposes
          // the tree below — the "late arrival" that has nowhere to go once
          // `castSessionProvider`'s own subscription is already torn down.
          castSessionManagerProvider.overrideWith((ref) {
            return Future<CastSessionManager>.delayed(
              const Duration(milliseconds: 60),
              () => throw StateError('unreachable in this test'),
            );
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: CastMiniController()),
        ),
      ));
      await tester.pump();

      // Dispose well before the 60ms rejection above fires.
      await tester.pumpWidget(const SizedBox.shrink());

      // `flutter test` runs every test inside a `FakeAsync` zone (see
      // `AutomatedTestWidgetsFlutterBinding.runTest`), so a plain
      // `Future.delayed` never elapses on its own — `tester.pump(duration)`
      // is what actually advances that clock and lets the delayed rejection
      // above land, well after the tree (and `castSessionProvider`'s own
      // subscription) is already torn down.
      await tester.pump(const Duration(milliseconds: 150));

      expect(flutterErrors, isEmpty,
          reason: 'castSessionProvider must catch its own read of '
              'castSessionManagerProvider.future instead of letting a '
              'disposal-time rejection escape as an unhandled async error: '
              '${flutterErrors.map((d) => d.exceptionAsString()).toList()}');
    });
  });
}
