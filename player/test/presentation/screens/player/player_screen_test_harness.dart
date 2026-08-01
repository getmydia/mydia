// Shared scaffolding for tests that fully mount `PlayerScreen` — building a
// live `Player`/`ConsumerStatefulWidget` with real Riverpod providers and a
// real (stubbed-transport) `GraphQLClient`. Not itself a test file (no
// `_test.dart` suffix), so `flutter test` does not try to run it directly.
//
// No such harness existed before the fix landed for the dispose()-time
// `ref.read` bug in `_terminateHlsSession` (see that method's doc comment in
// `player_screen.dart`): every test that mounted `PlayerScreen` and let it
// dispose hit `StateError: Using "ref" ... is unsafe`, unconditionally,
// because `BuildContext.mounted` is `false` throughout `State.dispose()` by
// core Flutter design. That is why `player_screen_key_handling_test.dart`
// only ever tested an extracted free function instead of the widget itself.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

import '../../../test_utils/stub_graphql_client.dart';

/// Reports whatever [AsyncValue] it is built with — the auth status this
/// screen sees is fixed for the lifetime of the test.
class FakeAuthNotifier extends AuthStateNotifier {
  FakeAuthNotifier(this._initial);

  final AsyncValue<AuthStatus> _initial;

  @override
  AsyncValue<AuthStatus> build() => _initial;
}

/// Reports a fixed [conn.ConnectionState] and skips `ConnectionNotifier`'s
/// real `_loadStoredState`, which reads platform secure storage — not
/// available, and not relevant, in a widget test.
class FixedConnectionNotifier extends conn.ConnectionNotifier {
  FixedConnectionNotifier(this._state);

  final conn.ConnectionState _state;

  @override
  conn.ConnectionState build() => _state;
}

class FakeDownloadService extends Fake implements DownloadService {
  @override
  DownloadedMedia? getDownloadedMediaById(String mediaId) => null;
}

/// Captures the [CastLaunchRequest] handed to `startCast` instead of routing
/// or connecting to anything real.
class CapturingCastSessionManager extends Fake implements CastSessionManager {
  CastLaunchRequest? capturedRequest;

  @override
  Future<void> startCast({
    required CastDevice device,
    required CastLaunchRequest request,
  }) async {
    capturedRequest = request;
  }
}

/// Tracks whether `stop()` ran, without touching a real P2P/HTTP stack.
class TrackingLocalProxyService extends Fake implements LocalProxyService {
  bool stopped = false;
  bool startCalled = false;

  @override
  int get port => 12345;

  @override
  Future<void> start({required String targetPeer, String? authToken}) async {
    startCalled = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

const testDevice = CastDevice(
  id: 'd1',
  name: 'Living Room',
  protocol: CastProtocolKind.chromecast,
);

/// A well-formed `MovieDetail` response. All fields beyond the required ones
/// (`id`, `title`, `monitored`, `addedAt`, `isFavorite`) are omitted deliberately
/// so the fallback chain in `_resolveRealDuration` sees nothing from progress
/// or runtime unless [positionSeconds] or [durationSeconds] is supplied —
/// isolating whichever signal a given test wants to exercise.
Map<String, dynamic> movieDetailResponse({
  int? positionSeconds,
  int? durationSeconds,
}) {
  return {
    '__typename': 'Query',
    'movie': {
      '__typename': 'Movie',
      'id': 'movie-1',
      'title': 'Arrival',
      'monitored': false,
      'addedAt': '2026-01-01T00:00:00Z',
      'isFavorite': false,
      if (positionSeconds != null || durationSeconds != null)
        'progress': {
          '__typename': 'Progress',
          'positionSeconds': positionSeconds ?? 0,
          'durationSeconds': durationSeconds,
          'percentage': null,
          'watched': false,
          'lastWatchedAt': null,
        },
    },
  };
}

/// A well-formed `StreamingCandidates` response. Empty `candidates` forces
/// the HLS/TRANSCODE path (`_canDirectPlay` declines an empty list), which is
/// what every test in this suite wants: none of them are testing direct play.
Map<String, dynamic> streamingCandidatesResponse({double? duration}) {
  return {
    '__typename': 'Query',
    'streamingCandidates': {
      '__typename': 'StreamingCandidatesResult',
      'fileId': 'file-1',
      'candidates': <dynamic>[],
      'metadata': {
        '__typename': 'StreamingMetadata',
        'duration': duration,
        'width': null,
        'height': null,
      },
    },
  };
}

/// A well-formed `StartStreamingSession` response. [startPosition] is the
/// *echoed* value the server claims to have used — deliberately a separate
/// parameter from whatever the client requested, so tests can make them
/// differ on purpose.
Map<String, dynamic> startStreamingSessionResponse({
  String sessionId = 'sess-1',
  double? duration,
  int? startPosition,
}) {
  return {
    '__typename': 'RootMutationType',
    'startStreamingSession': {
      '__typename': 'StreamingSessionResult',
      'sessionId': sessionId,
      'duration': duration,
      'startPosition': startPosition,
    },
  };
}

Map<String, dynamic> endStreamingSessionResponse({bool ok = true}) {
  return {
    '__typename': 'RootMutationType',
    'endStreamingSession': ok,
  };
}

/// Builds a [ProviderContainer] with the overrides every `PlayerScreen` mount
/// needs, wiring [link] as the transport for a real [GraphQLClient] (see
/// `stub_graphql_client.dart`) and [connectionState]/[castManager]/
/// [proxyService] for the pieces a real app would resolve from native
/// services this test has no business touching.
///
/// Returns a [ProviderContainer] directly rather than the raw override list:
/// `Override` (the element type `ProviderContainer.overrides` expects) is not
/// part of `flutter_riverpod`'s public export surface, so a helper can only
/// spell its return type by constructing the container itself.
ProviderContainer buildPlayerScreenContainer({
  required StubLink link,
  required conn.ConnectionState connectionState,
  required CapturingCastSessionManager castManager,
  required TrackingLocalProxyService proxyService,
}) {
  return ProviderContainer(overrides: [
    authStateProvider.overrideWith(
      () => FakeAuthNotifier(
        const AsyncValue.data(AuthStatus.authenticated),
      ),
    ),
    downloadManagerProvider.overrideWith((ref) async => FakeDownloadService()),
    asyncGraphqlClientProvider.overrideWith((ref) async => stubClient(link)),
    serverUrlProvider.overrideWith((ref) async => 'https://mydia.test'),
    authTokenProvider.overrideWith((ref) async => 'tok'),
    conn.connectionProvider
        .overrideWith(() => FixedConnectionNotifier(connectionState)),
    localProxyServiceProvider.overrideWithValue(proxyService),
    castSessionManagerProvider.overrideWith((ref) async => castManager),
    castSessionProvider.overrideWith((ref) => Stream.value(null)),
  ]);
}

/// Mounts `PlayerScreen` under [container] and pumps once.
Future<void> pumpPlayerScreen(
  WidgetTester tester,
  ProviderContainer container, {
  String mediaId = 'movie-1',
  String mediaType = 'movie',
  String fileId = 'file-1',
}) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: PlayerScreen(
        mediaId: mediaId,
        mediaType: mediaType,
        fileId: fileId,
        title: 'Arrival',
      ),
    ),
  ));
  await tester.pump();
}

/// Pumps in small steps until [condition] is satisfied or [maxTries] is hit.
/// Deliberately not `pumpAndSettle`: `PlayerScreen` shows a
/// `CircularProgressIndicator` while `_isLoading` is true, whose implicit
/// animation never settles, so `pumpAndSettle` would time out.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxTries = 100,
}) async {
  for (var i = 0; i < maxTries && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}
