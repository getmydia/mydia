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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_providers.dart';
import 'package:player/core/playback/playback_progress_store.dart';
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
  FakeDownloadService({this.downloaded});

  final DownloadedMedia? downloaded;

  @override
  DownloadedMedia? getDownloadedMediaById(String mediaId) => downloaded;
}

/// Captures the [CastLaunchRequest] handed to `startCast` instead of routing
/// or connecting to anything real.
class CapturingCastSessionManager extends Fake implements CastSessionManager {
  CastLaunchRequest? capturedRequest;

  /// When set, `startCast` throws this instead of succeeding — simulating an
  /// unreachable receiver or a rejected codec, so a test can prove
  /// `_castToTargetIfSet` falls through to local playback on failure without
  /// clearing the chosen device (`castTargetProvider` stays set so the bar
  /// can offer a reconnect).
  Object? startCastError;

  @override
  Future<void> startCast({
    required CastDevice device,
    required CastLaunchRequest request,
  }) async {
    capturedRequest = request;
    final error = startCastError;
    if (error != null) throw error;
  }
}

/// Tracks whether `stop()` ran, without touching a real P2P/HTTP stack.
class TrackingLocalProxyService extends Fake implements LocalProxyService {
  bool stopped = false;
  bool startCalled = false;

  /// The file id `PlayerScreen` asked to direct-stream, or null if it never
  /// took the direct-play branch. This is the user's selected file: a test
  /// that mounts the screen with one file id and scripts the server to name a
  /// different one proves the selection is honored.
  String? capturedDirectStreamFileId;

  @override
  int get port => 12345;

  @override
  Future<void> start({required String targetPeer, String? authToken}) async {
    startCalled = true;
  }

  @override
  String buildHlsUrl(String sessionId) =>
      'http://127.0.0.1:$port/hls/$sessionId/index.m3u8';

  @override
  String buildDirectStreamUrl(String fileId) {
    capturedDirectStreamFileId = fileId;
    return 'http://127.0.0.1:$port/direct/$fileId/stream';
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

/// Mocks the path_provider platform channel so `getApplicationDocumentsDirectory`
/// resolves instead of hanging.
///
/// `_resolveDownloadedFilePath` calls it as a fallback once the stored path
/// misses. Under `testWidgets`, unlike plain `test()`, an unmocked platform
/// channel does not fail fast with `MissingPluginException` — the awaiting
/// Future simply never completes, even across repeated `tester.pump()`
/// calls, so any test that exercises a non-null `downloaded` item hangs until
/// the runner's watchdog kills it.
///
/// Register from `setUp`, not `setUpAll`: a handler registered before the
/// per-test binding reset that precedes each `testWidgets` body does not
/// survive into it.
void mockPathProviderDocumentsDirectory() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => Directory.systemTemp.path,
  );
}

/// A downloaded item pointing at [filePath].
///
/// `_resolveDownloadedFilePath` checks `file_utils.fileExists(filePath)`
/// first, before it ever falls back to `path_provider`: pass a path to a
/// file that actually exists on disk (e.g. a real temp file the caller
/// creates and tears down) to drive the offline branch past its "downloaded
/// file not found" bail-out and into the shared resume/start path this test
/// suite cares about. Pass a path that does not exist — the default used to
/// hardcode one — to exercise that bail-out instead.
DownloadedMedia downloadedItem({
  required String filePath,
  int? runtimeMinutes,
}) =>
    DownloadedMedia(
      id: 'dl-1',
      mediaId: 'movie-1',
      title: 'Arrival',
      quality: '1080p',
      filePath: filePath,
      fileSize: 1,
      mediaType: 'movie',
      downloadedAt: DateTime(2026, 1, 1),
      runtime: runtimeMinutes,
    );

/// Writes a local progress record into a container's store before the screen
/// mounts, standing in for a previous playback session.
Future<void> seedLocalProgress(
  ProviderContainer container, {
  String mediaId = 'movie-1',
  String mediaType = 'movie',
  int positionSeconds = 600,
  int durationSeconds = 5400,
  DateTime? updatedAt,
}) async {
  final store = await container.read(playbackProgressStoreProvider.future);
  await store.save(LocalPlaybackProgress(
    mediaId: mediaId,
    mediaType: mediaType,
    positionSeconds: positionSeconds,
    durationSeconds: durationSeconds,
    updatedAt: updatedAt ?? DateTime.utc(2026, 8, 2, 12),
  ));
}

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

/// A well-formed `MovieSegments` response.
///
/// `_fetchProgressAndEpisodes` issues this immediately after the detail query
/// and before streaming candidates, so an ordered `StubLink.responses` script
/// has to carry it in that slot. Segments travel in their own document on
/// purpose, not inside `MediaFileFragment` — see
/// `player_screen_segments_isolation_test.dart` for why. The default is
/// "detection found nothing", which is what every test that is not about
/// segments wants.
Map<String, dynamic> movieSegmentsResponse({
  List<Map<String, dynamic>> segments = const [],
}) {
  return {
    '__typename': 'Query',
    'movie': {
      '__typename': 'Movie',
      'id': 'movie-1',
      'files': [
        {
          '__typename': 'MediaFile',
          'id': 'file-1',
          'segments': segments,
        },
      ],
    },
  };
}

/// A well-formed `StreamingCandidates` response.
///
/// Empty `candidates` (the default) forces the HLS/TRANSCODE path, because
/// `_canDirectPlay` declines an empty list. Pass [directPlay] to put a
/// `DIRECT_PLAY` candidate first instead, which is what makes
/// `_initializePlayer` take its native direct-play branch.
Map<String, dynamic> streamingCandidatesResponse({
  double? duration,
  bool directPlay = false,
}) {
  return {
    '__typename': 'Query',
    'streamingCandidates': {
      '__typename': 'StreamingCandidatesResult',
      'fileId': 'file-1',
      'candidates': <dynamic>[
        if (directPlay)
          {
            '__typename': 'StreamingCandidate',
            'strategy': 'DIRECT_PLAY',
            'mime': 'video/mp4; codecs="avc1.640028, mp4a.40.2"',
            'container': 'mp4',
            'videoCodec': 'avc1.640028',
            'audioCodec': 'mp4a.40.2',
          },
      ],
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
  DownloadedMedia? downloaded,
  AuthStatus authStatus = AuthStatus.authenticated,
  PlaybackProgressStore? progressStore,
}) {
  return ProviderContainer(overrides: [
    authStateProvider.overrideWith(
      () => FakeAuthNotifier(AsyncValue.data(authStatus)),
    ),
    downloadManagerProvider.overrideWith(
        (ref) async => FakeDownloadService(downloaded: downloaded)),
    asyncGraphqlClientProvider.overrideWith((ref) async => stubClient(link)),
    serverUrlProvider.overrideWith((ref) async => 'https://mydia.test'),
    authTokenProvider.overrideWith((ref) async => 'tok'),
    conn.connectionProvider
        .overrideWith(() => FixedConnectionNotifier(connectionState)),
    localProxyServiceProvider.overrideWithValue(proxyService),
    castSessionManagerProvider.overrideWith((ref) async => castManager),
    castSessionProvider.overrideWith((ref) => Stream.value(null)),
    playbackProgressStoreProvider.overrideWith(
        (ref) async => progressStore ?? InMemoryPlaybackProgressStore()),
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

/// Polls [condition] until it is satisfied or [ceiling] elapses, yielding to
/// the real event loop between checks.
///
/// For tests whose `_initializePlayer` path depends on real asynchronous I/O
/// — `dart:io` file checks, a `path_provider` platform-channel round trip
/// (see [mockPathProviderDocumentsDirectory]'s doc comment for why those
/// never resolve under plain `tester.pump()`) — a fixed pump-count budget is
/// either wastefully long or, on a slower/loaded machine, flaky-short. This
/// polls the actual outcome instead of guessing a duration, with a ceiling
/// generous enough that hitting it means something is genuinely stuck, not
/// just slow.
///
/// Must be called from inside `tester.runAsync(() async { ... })`: the real
/// `Future.delayed` between pumps is what yields to the real event loop for
/// pending I/O to complete, and that only takes effect inside `runAsync`.
Future<void> pumpUntilReal(
  WidgetTester tester,
  bool Function() condition, {
  Duration ceiling = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(ceiling);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    await Future.delayed(const Duration(milliseconds: 5));
  }
}
