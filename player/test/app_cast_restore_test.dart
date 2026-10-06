import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/app.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/cast_mini_controller.dart';

void main() {
  /// Restoring a cast session needs a Mydia instance to sync progress to, so
  /// it is meaningless before one exists. A manager built earlier would also
  /// be torn down mid-build when the container is disposed on the pairing
  /// screen.
  ///
  /// These pin the gate: the cast stack is untouched until a Mydia account
  /// exists, and is reached once it does.
  group('MyApp cast session restore', () {
    late bool managerBuilt;

    buildOverrides({required bool bound}) => [
          sourcesLoadingProvider.overrideWithValue(false),
          hasMydiaProvider.overrideWithValue(bound),
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          castSessionManagerProvider.overrideWith((ref) async {
            managerBuilt = true;
            throw StateError('unreachable in these tests');
          }),
        ];

    setUp(() => managerBuilt = false);

    Future<void> pumpApp(
      WidgetTester tester, {
      required bool bound,
    }) async {
      await tester.pumpWidget(ProviderScope(
        overrides: buildOverrides(bound: bound),
        child: const MyApp(),
      ));
      await tester.pump();
    }

    testWidgets('does not touch the cast stack while no Mydia account exists',
        (tester) async {
      await pumpApp(tester, bound: false);

      expect(managerBuilt, isFalse,
          reason: 'the cast stack must not be built before a Mydia account '
              'exists');
    });

    testWidgets('restores once a Mydia account exists', (tester) async {
      await pumpApp(tester, bound: true);

      expect(managerBuilt, isTrue,
          reason: 'gating on a Mydia account must not disable restore '
              'outright');
    });
  });

  /// The second entry point into the cast stack. `CastMiniController` is
  /// mounted on every screen by `app.dart`, and `isCastingProvider` reaches
  /// `castSessionManagerProvider`. Gating `app.dart` alone left this path
  /// initialising the chain pre-auth, which is what actually tripped the E2E
  /// pairing test.
  group('CastMiniController', () {
    testWidgets('does not build the cast stack without a Mydia account',
        (tester) async {
      var managerBuilt = false;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          hasMydiaProvider.overrideWithValue(false),
          castSessionManagerProvider.overrideWith((ref) async {
            managerBuilt = true;
            throw StateError('unreachable in this test');
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: CastMiniController()),
        ),
      ));
      await tester.pump();

      expect(managerBuilt, isFalse,
          reason: 'the mini controller must not reach the cast stack with '
              'no Mydia account');
    });
  });

  /// `castSessionProvider` itself had the same hazard as `_restoreCastSession`
  /// and `_initRemoteControlIfEnabled`, but with no guard: `CastMiniController`
  /// starts it running (via `.value`, a plain sync watch — see the "the mini
  /// controller must not reach the cast stack" test above for how little it
  /// takes) the moment a Mydia account exists, on every screen, and its
  /// body reads `castSessionManagerProvider.future` with no try/catch of its
  /// own.
  ///
  /// A manager that never builds cannot reproduce this one: nothing ever
  /// rejects, so nothing ever needs to escape. What reproduces it is a
  /// rejection that arrives *after* the container is already disposed —
  /// exactly what happens in production when a pending provider future is
  /// force-completed with a StateError by
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
          hasMydiaProvider.overrideWithValue(true),
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
