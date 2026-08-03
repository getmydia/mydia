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
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/cast_device.dart';

/// Auth notifier whose state the test drives directly.
class _FakeAuthNotifier extends AuthStateNotifier {
  _FakeAuthNotifier(this._initial);

  final AsyncValue<AuthStatus> _initial;

  @override
  AsyncValue<AuthStatus> build() => _initial;
}

const _device = CastDevice(
  id: 'd1',
  name: 'Cottage Chromecast',
  protocol: CastProtocolKind.chromecast,
);

CastSession _playingSession() => const CastSession(
      device: _device,
      playbackState: CastPlaybackState.playing,
      mediaInfo: CastMediaInfo(
        title: 'Silo - S02E01',
        duration: Duration(minutes: 44),
        position: Duration(seconds: 29),
      ),
    );

/// `app.dart` mounts the cast bar above the router, so the bar's own subtree
/// gets whatever `MaterialApp.router`'s `builder` provides — not the
/// `Navigator`/`Overlay` that lives *inside* the router's child. Widgets in
/// the bar that need either of those (every `IconButton` has a `tooltip`, and
/// stopping a cast opens a confirmation dialog) break there while looking
/// perfectly fine in a test that pumps the bar under a plain `MaterialApp`.
///
/// These pump the real `MyApp` so the mounting point itself is under test.
void main() {
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    CastSession? session,
  }) async {
    final container = ProviderContainer(overrides: [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
      authStateProvider.overrideWith(() =>
          _FakeAuthNotifier(const AsyncValue.data(AuthStatus.authenticated))),
      asyncGraphqlClientProvider
          .overrideWith((ref) => Completer<GraphQLClient>().future),
      castSessionProvider.overrideWith((ref) => Stream.value(session)),
      castSessionManagerProvider
          .overrideWith((ref) => Completer<CastSessionManager>().future),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MyApp(),
    ));
    await tester.pump();
    return container;
  }

  testWidgets('the idle bar renders where app.dart mounts it', (tester) async {
    final container = await pumpApp(tester);

    container.read(castTargetProvider.notifier).set(_device);
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'the cast bar must build in its real mounting point, not '
            'only under a Scaffold in a widget test');
    expect(find.byKey(const Key('cast-bar-idle-clear')), findsOneWidget);
  });

  testWidgets('stopping a cast can open its confirmation dialog',
      (tester) async {
    await pumpApp(tester, session: _playingSession());
    await tester.pump();

    await tester.tap(find.byKey(const Key('cast-bar-stop')));
    // Not `pumpAndSettle`: the screens behind the bar keep a progress
    // indicator spinning while their GraphQL client never resolves, so the
    // frames never stop coming. Pump past the dialog's entrance instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
    expect(find.text('Stop Casting'), findsOneWidget,
        reason: 'the confirm dialog needs a Navigator reachable from the '
            'cast bar');
  });
}
