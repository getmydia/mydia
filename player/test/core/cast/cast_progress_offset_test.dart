// THE regression guard for this feature. `_syncProgress` pushes receiver
// position to the server as watch progress every 10 seconds. Once a session
// carries a start offset, the receiver reports 0 at the start, so an
// untranslated sync would overwrite the user's real position with 0 within
// ten seconds of resuming. That is strictly worse than the bug being fixed.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/domain/models/cast_device.dart';

import '../../test_utils/fake_cast_backend.dart';
import '../../test_utils/fake_streaming_session_service.dart';

/// Captures what the manager syncs, replacing the mocked GraphQL client used
/// elsewhere: these tests care about the numbers, not the mutation.
///
/// It calls [ProgressService.resolveSync] exactly as the real service does,
/// which is the point: the manager hands over a *raw* receiver position and
/// the timeline that translates it, so a manager that translated first would
/// show up here as a doubled offset.
class RecordingProgressService extends Fake implements ProgressService {
  final movies = <({String id, int position, int duration})>[];

  @override
  StreamTimeline timeline = StreamTimeline.zero;

  @override
  Future<bool> syncMoviePosition(
    String movieId,
    Duration position,
    Duration duration,
  ) async {
    final resolved = ProgressService.resolveSync(position, duration, timeline);
    if (resolved == null) return false;
    movies.add((
      id: movieId,
      position: resolved.positionSeconds,
      duration: resolved.durationSeconds,
    ));
    return true;
  }
}

void main() {
  const device = CastDevice(
    id: 'd1',
    name: 'Living Room',
    protocol: CastProtocolKind.chromecast,
  );

  late FakeCastBackend backend;
  late InMemoryCastSessionStore store;
  late FakeStreamingSessionService sessions;
  late RecordingProgressService progress;

  /// Pumps the event loop until [condition] holds.
  ///
  /// `_syncProgress` is fired with `unawaited` and awaits the session store
  /// before it ever reaches the progress service, so how many event-loop
  /// turns separate emitting a position from observing the sync is an
  /// implementation detail. A fixed delay would be a guess at it.
  Future<void> until(bool Function() condition,
      {required String describe}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('never observed: $describe');
      await Future<void>.delayed(Duration.zero);
    }
  }

  CastSessionManager build() {
    final manager = CastSessionManager(
      backend: backend,
      store: store,
      progressService: progress,
      streamingSessions: sessions,
      resolverFactory: () => CastRouteResolver(
        isP2pMode: false,
        serverUrl: 'https://mydia.test',
        mediaToken: () async => 'tok',
        lanBaseUrl: () => null,
        streamingSessions: sessions,
      ),
      setLanAccess: (_) async {},
      clock: () => DateTime.utc(2026, 8, 2, 12),
    );
    addTearDown(manager.dispose);
    return manager;
  }

  setUp(() {
    backend = FakeCastBackend();
    store = InMemoryCastSessionStore();
    sessions = FakeStreamingSessionService();
    progress = RecordingProgressService();
  });

  /// A cast resumed 40 minutes in. The server clamps to the nearest keyframe,
  /// so it echoes 2394s for a requested 2400s.
  Future<CastSessionManager> resumedCast() async {
    sessions.echoedStartOffset = const Duration(seconds: 2394);
    final manager = build();
    await manager.startCast(
      device: device,
      request: const CastLaunchRequest(
        fileId: 'file-1',
        mediaId: 'movie-1',
        mediaType: 'movie',
        title: 'Arrival',
        startPosition: Duration(seconds: 2400),
        duration: Duration(seconds: 5400),
      ),
    );
    return manager;
  }

  test('a receiver at position zero syncs the real position, not zero',
      () async {
    await resumedCast();

    backend.emitPosition(Duration.zero);
    await until(() => progress.movies.isNotEmpty,
        describe: 'the first position event reaching the server');

    expect(
      progress.movies.single.position,
      2394,
      reason: 'syncing the raw receiver position would overwrite the user\'s '
          'real watch position with zero',
    );
    expect(progress.movies.single.duration, 5400);
  });

  test('a receiver part-way in syncs offset plus receiver position', () async {
    await resumedCast();

    backend.emitPosition(const Duration(seconds: 60));
    await until(() => progress.movies.isNotEmpty,
        describe: 'a synced position');

    expect(
      progress.movies.single.position,
      2454,
      reason: 'a doubled translation would sync 4848 here',
    );
  });

  test('mediaInfo publishes real positions', () async {
    final manager = await resumedCast();

    backend.emitPosition(const Duration(seconds: 60));
    await until(
      () =>
          manager.currentSession?.mediaInfo?.position ==
          const Duration(seconds: 2454),
      describe: 'the published position reaching 40:54',
    );

    expect(
      manager.currentSession!.mediaInfo!.position,
      const Duration(seconds: 2454),
      reason: 'the mini controller must not read 1:00 for a cast resumed 40 '
          'minutes in',
    );
  });

  test('the persisted session stores a real position', () async {
    await resumedCast();

    backend.emitPosition(const Duration(seconds: 60));
    // `_syncProgress` saves before it syncs, so a recorded sync proves the
    // save already landed.
    await until(() => progress.movies.isNotEmpty,
        describe: 'a synced position');

    final stored = await store.load();
    expect(
      stored!.position,
      const Duration(seconds: 2454),
      reason: 'reconnectStoredSession feeds this back as startPosition, so a '
          'receiver-relative value would compound the offset every reconnect',
    );
  });

  test('the receiver is asked only for the residual above the baked-in offset',
      () async {
    await resumedCast();

    expect(
      backend.loadedRequests.single.startPosition,
      const Duration(seconds: 6),
      reason: '2394s of the requested 2400s is already in the stream, so only '
          'the 6s the keyframe snap gave away is left for the receiver',
    );
    expect(
      backend.loadedRequests.single.startPosition,
      isNot(const Duration(seconds: 2400)),
      reason: 'seeking to the absolute position on top of the offset would '
          'land at very nearly twice it',
    );
  });

  test('an exactly honored offset leaves the receiver nothing to seek',
      () async {
    sessions.echoedStartOffset = const Duration(seconds: 2400);
    final manager = build();

    await manager.startCast(
      device: device,
      request: const CastLaunchRequest(
        fileId: 'file-1',
        mediaId: 'movie-1',
        mediaType: 'movie',
        title: 'Arrival',
        startPosition: Duration(seconds: 2400),
        duration: Duration(seconds: 5400),
      ),
    );

    expect(backend.loadedRequests.single.startPosition, Duration.zero);
  });

  test('a zero-offset session translates nothing', () async {
    sessions.echoedStartOffset = Duration.zero;
    final manager = build();
    await manager.startCast(
      device: device,
      request: const CastLaunchRequest(
        fileId: 'file-1',
        mediaId: 'movie-1',
        mediaType: 'movie',
        title: 'Arrival',
        duration: Duration(seconds: 5400),
      ),
    );

    backend.emitPosition(const Duration(seconds: 60));
    await until(() => progress.movies.isNotEmpty,
        describe: 'a synced position');

    expect(progress.movies.single.position, 60);
  });

  test('a progressive receiver still gets a plain seek', () async {
    // DLNA keeps `startOffset` at zero, so the resume position has to reach
    // the receiver as a seek or it is lost entirely.
    const dlna = CastDevice(
      id: 'd2',
      name: 'Bedroom TV',
      protocol: CastProtocolKind.dlna,
    );
    final manager = build();

    await manager.startCast(
      device: dlna,
      request: const CastLaunchRequest(
        fileId: 'file-1',
        mediaId: 'movie-1',
        mediaType: 'movie',
        title: 'Arrival',
        startPosition: Duration(seconds: 2400),
        duration: Duration(seconds: 5400),
      ),
    );

    expect(
      backend.loadedRequests.single.startPosition,
      const Duration(seconds: 2400),
    );

    backend.emitPosition(const Duration(seconds: 2460));
    await until(() => progress.movies.isNotEmpty,
        describe: 'a synced position');

    expect(progress.movies.single.position, 2460);
  });
}
