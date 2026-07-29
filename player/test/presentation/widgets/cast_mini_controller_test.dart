import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_mini_controller.dart';

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

CastSession _session({
  required Duration duration,
  Duration position = const Duration(seconds: 29),
  bool isStale = false,
}) {
  return CastSession(
    device: _device,
    playbackState: CastPlaybackState.playing,
    isStale: isStale,
    mediaInfo: CastMediaInfo(
      title: 'Silo - S02E01',
      duration: duration,
      position: position,
    ),
  );
}

/// Returns the container so a test can set a cast target after pumping.
Future<ProviderContainer> _pump(
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
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: CastMiniController())),
  ));
  await tester.pump();
  return container;
}

void main() {
  testWidgets('shows title and device while casting', (tester) async {
    await _pump(tester,
        session: _session(duration: const Duration(minutes: 44)));

    expect(find.text('Silo - S02E01'), findsOneWidget);
    expect(find.textContaining('Cottage Chromecast'), findsOneWidget);
  });

  testWidgets(
      'renders --:-- and disables the scrubber when duration is unknown',
      (tester) async {
    await _pump(tester, session: _session(duration: Duration.zero));

    expect(
      find.byKey(const Key('cast-bar-duration')),
      findsOneWidget,
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('cast-bar-duration')))).data,
      '--:--',
    );

    final slider =
        tester.widget<Slider>(find.byKey(const Key('cast-bar-scrubber')));
    expect(slider.onChanged, isNull,
        reason: 'an unknown duration must make the scrubber inert rather than '
            'seeking to fraction * -1s');
  });

  testWidgets('renders the stale state with reconnect and stop',
      (tester) async {
    await _pump(
      tester,
      session: _session(duration: const Duration(minutes: 44), isStale: true),
    );

    expect(find.byKey(const Key('cast-stale-reconnect')), findsOneWidget);
    expect(find.byKey(const Key('cast-stale-stop')), findsOneWidget);
    expect(find.byKey(const Key('cast-bar-scrubber')), findsNothing);
  });

  testWidgets('renders nothing when there is no session and no target',
      (tester) async {
    await _pump(tester);

    expect(find.byKey(const Key('cast-bar-scrubber')), findsNothing);
    expect(find.textContaining('Cottage Chromecast'), findsNothing);
  });

  testWidgets('renders the idle state for a target with no session',
      (tester) async {
    final container = await _pump(tester);

    container.read(castTargetProvider.notifier).set(_device);
    await tester.pump();

    expect(find.textContaining('Will play on'), findsOneWidget);
    expect(find.textContaining('Cottage Chromecast'), findsOneWidget);
    expect(find.byKey(const Key('cast-bar-scrubber')), findsNothing);
  });

  testWidgets('the idle clear button drops the target', (tester) async {
    final container = await _pump(tester);

    container.read(castTargetProvider.notifier).set(_device);
    await tester.pump();

    await tester.tap(find.byKey(const Key('cast-bar-idle-clear')));
    await tester.pump();

    expect(container.read(castTargetProvider), isNull);
    expect(find.textContaining('Will play on'), findsNothing);
  });
}
