// Two real players, one real server, one real iroh connection between them.
//
// HARNESS NOTE — this deviates from the plan's Task 18 in one deliberate way,
// documented here rather than hidden:
//
// The plan proposed a second `test`-like compose service so "two player
// instances run against one server". That shape does not fit: the `test`
// service in `compose.player-e2e.yml` is the Flutter *test runner* — running
// a second one starts a second, independent `flutter test` process with no
// way to coordinate a single scenario across the two. There is no built-in
// mechanism for one test file to drive two containers through one scripted
// interaction.
//
// It also cannot be done by mounting two `MyApp()` widget trees in one
// process: `core/router/navigator_keys.dart` declares `rootNavigatorKey` as
// a single top-level `GlobalKey<NavigatorState>`, read by `app_router.dart`
// regardless of which `ProviderScope` builds the router. Two live `MyApp()`
// instances would each hand that same `GlobalKey` to a `Navigator`, which
// Flutter refuses outright ("Multiple widgets used the same GlobalKey").
//
// What actually works, and what this file does: **one process, one real
// `MyApp()` widget tree (player A, the controller, driven through its real
// UI) plus one headless second node (player B, the target) built directly
// from the same non-UI production classes `MyApp` itself wires up** —
// `P2PHost`/`P2pService` (a brand new random keypair; native builds never
// persist one — see `HostConfig.keypair_path` staying `None` in
// `player/rust/mydia_player_p2p/src/lib.rs`, so every `P2PHost.init()` call
// is already a distinct node identity with no extra plumbing needed),
// `PairingService` (real claim-code pairing, with an injected in-memory
// `AuthStorage` so B's credentials never collide with A's real ones — both
// devices otherwise share one OS process's default secure storage),
// `NodeRegistration`, `RemoteRoster`, `RemoteControlReceiver` and
// `RemoteTargetController`. B never mounts a `PlayerScreen` or decodes real
// video — a widget-tree-driven B hits the exact same `rootNavigatorKey`
// collision `MyApp` does, so nothing here can give B one without either
// spinning up a second OS process (the thing this note already ruled out) or
// patching the app's globals — which is out of scope for adding a test.
//
// The gap this leaves: B's playback loop is a hand-scripted
// `RemotePlayerBinding`, not `PlayerScreen`'s real `media_kit` player. Every
// wire exchange this test drives is still completely real — genuine iroh
// QUIC, genuine `FlutterRemoteControlRequest`/`Response` bytes, genuine
// `RemoteControlReceiver` dispatch, genuine GraphQL roster/registration
// calls against the real server — which is exactly what an integration test
// can prove that unit tests (already covering `RemoteControlReceiver`,
// `RemoteTargetController`, `MydiaCastBackend`, `CastSessionManager`'s
// adoption fork, etc. in isolation) cannot: that every one of those pieces
// still agrees once real bytes cross a real socket between two independent
// node identities. What it cannot prove is that a real mounted player
// screen answers commands correctly — that is `PlayerScreen`'s own
// `RemotePlayerBinding` implementation, exercised by unit tests instead.
//
// Coverage against the plan's 7 steps:
//   1. Pair two players to the same account; confirm both node IDs reached
//      the server.                                            — COVERED
//   2. Start playback locally on player B, without involving player A.
//                                                               — COVERED
//      ("locally" means B's own scripted playback state, per the harness
//      note above — not a decoded video frame.)
//   3. From player A, open the picker and assert B appears, showing what it
//      is playing.                                             — COVERED
//   4. Select B and assert A adopts rather than restarting: position must be
//      continuous, not reset to zero.                          — COVERED
//   5. Pause from A; assert B is paused.                       — COVERED
//   6. Seek from A; assert B's position follows.                — COVERED
//   7. Pull playback back to A; assert B stops and A resumes at the same
//      position.                                                — COVERED
//      (Asserted via the pushed `PlayerScreen`'s own `resumeSeconds` field
//      rather than waiting for real HLS/media_kit playback to visibly start,
//      which existing tests — `p2p_streaming_test.dart` — already cover for
//      this harness and would only add flakiness here without adding
//      confidence in the remote-control wire protocol this file exists to
//      pin down.)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:player/app.dart';
import 'package:player/core/auth/auth_storage.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/channels/pairing_service.dart';
import 'package:player/core/graphql/client.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/remote/node_registration.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_control_receiver.dart';
import 'package:player/core/remote/remote_roster.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/native/lib.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

import 'helpers/e2e_api_client.dart';
import 'helpers/test_bootstrap.dart';

/// The E2E seed's single movie (`scripts/e2e/seed.sh`): a 5-second
/// ffmpeg-generated clip titled "E2E Test Movie". Every duration/position
/// this test uses is chosen to stay sane against that real 5000ms length.
const _realMovieDuration = Duration(seconds: 5);

/// In-memory [AuthStorage] for player B.
///
/// `AuthService`'s and `PairingService`'s default storage is a single,
/// process-wide secure store keyed by fixed strings (`auth_token`,
/// `pairing_access_token`, ...) — fine for one device, but this process runs
/// two. Without this, B's `pairWithClaimCodeOnly` would silently overwrite
/// player A's real, UI-driven credentials the moment it stores its own.
/// `AuthStorage`/`PairingService(authStorage: ...)` exist precisely so tests
/// can substitute this.
class _InMemoryAuthStorage implements AuthStorage {
  final _values = <String, String>{};

  @override
  bool get degraded => false;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> deleteAll() async => _values.clear();
}

/// Player B's scripted playback, standing in for a mounted `PlayerScreen`
/// (see the file header for why). Deliberately holds no wall-clock-driven
/// position math: every field only ever changes in response to an explicit
/// call, which is what a real `RemoteControlReceiver`/`RemoteTargetController`
/// pair drives it with over the wire. That determinism is what lets this
/// test assert exact positions instead of tolerance-laden ranges once B is
/// paused — [MydiaCastBackend]'s own client-side interpolation is the only
/// place a "playing" position drifts, and that happens on player A's side of
/// the wire, not here.
class _FakeTargetPlayer implements RemotePlayerBinding {
  _FakeTargetPlayer({
    required this.mediaItemId,
    required this.title,
    required Duration duration,
  }) : _duration = duration;

  final String mediaItemId;
  final String title;
  final Duration _duration;

  FlutterPlaybackState _state = FlutterPlaybackState.idle;
  Duration _position = Duration.zero;

  /// What this test asserts against directly — the real state a genuine
  /// wire command left B in, read the same way [describe] would report it.
  FlutterPlaybackState get currentState => _state;
  Duration get currentPosition => _position;

  /// Starts local playback at [at], the stand-in for a user pressing play on
  /// player B's own screen (step 2). Everything from here on is answered by
  /// the same production [RemoteTargetController]/[RemoteControlReceiver]
  /// pipeline a real mounted `PlayerScreen` would be attached to.
  void startPlaying({required Duration at}) {
    _position = at;
    _state = FlutterPlaybackState.playing;
  }

  @override
  Future<void> play() async => _state = FlutterPlaybackState.playing;

  @override
  Future<void> pause() async => _state = FlutterPlaybackState.paused;

  @override
  Future<void> stop() async {
    _position = Duration.zero;
    _state = FlutterPlaybackState.idle;
  }

  @override
  Future<void> seek(Duration to) async {
    _position =
        to < Duration.zero ? Duration.zero : (to > _duration ? _duration : to);
  }

  @override
  Future<void> setVolume(double level) async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> selectTrack(TrackKind kind, String? id) async {}

  @override
  Future<void> stepEpisode(EpisodeStep step) async {}

  @override
  FlutterPlaybackSnapshot describe(int sequence) => FlutterPlaybackSnapshot(
        state: _state,
        mediaItemId: mediaItemId,
        episodeId: null,
        title: title,
        subtitle: null,
        imageUrl: null,
        positionMs: BigInt.from(_position.inMilliseconds),
        durationMs: BigInt.from(_duration.inMilliseconds),
        volume: 1.0,
        muted: false,
        audioTracks: const [],
        subtitleTracks: const [],
        selectedAudio: null,
        selectedSubtitle: null,
        capabilities: const FlutterTargetCapabilities(
          volume: true,
          trackSelection: true,
          nextPrevious: false,
        ),
        sequence: BigInt.from(sequence),
      );
}

/// The E2E-seeded movie, fetched by title rather than assumed at a fixed id.
class _TestMovie {
  final String id;
  final String title;

  const _TestMovie({required this.id, required this.title});
}

Future<_TestMovie> _fetchTestMovie(E2eApiClient api) async {
  const query = r'''
    query RemoteControlE2ETestMovie {
      movies(first: 50) {
        edges {
          node {
            id
            title
            files { id }
          }
        }
      }
    }
  ''';

  final response = await api.graphqlRequest(query, const {});
  final edges = response['data']?['movies']?['edges'] as List? ?? const [];
  for (final edge in edges) {
    final movie = edge['node'] as Map<String, dynamic>;
    final files = movie['files'] as List?;
    if (files != null && files.isNotEmpty) {
      return _TestMovie(
        id: movie['id'] as String,
        title: movie['title'] as String,
      );
    }
  }
  throw StateError(
      'No E2E test movie with a file found — is scripts/e2e/seed.sh wired up?');
}

/// Retries claim-code generation the same way `p2p_streaming_test.dart`
/// does: a fresh claim code is cheap on the server, and this is the flakiest
/// single call in the setup path.
Future<String> _generateClaimCode(E2eApiClient api, String label) async {
  const maxAttempts = 10;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final claim = await api.generateClaimCode();
      return claim.code;
    } catch (error) {
      if (attempt == maxAttempts) rethrow;
      debugPrint(
          '[RemoteControlE2E] $label claim code attempt $attempt failed: $error');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  throw StateError('unreachable');
}

/// Pumps in real time (this binding runs real async, not `FakeAsync`) until
/// [condition] is true or [timeout] elapses. Returns whether it settled true,
/// so callers can attach their own failure message via `expect`/`fail`
/// instead of a generic timeout exception.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 500),
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(step);
  }
  return condition();
}

/// Same "pump in a loop, real time" pattern `pairing_flow_test.dart` and
/// `p2p_streaming_test.dart` already use — `pumpAndSettle` never returns
/// while a loading spinner's animation is running.
Future<void> _waitForLoginScreen(WidgetTester tester,
    {int maxSeconds = 30}) async {
  for (var i = 0; i < maxSeconds; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (find.text('Connect to Server').evaluate().isNotEmpty) return;
  }
  throw StateError('Login screen not found after $maxSeconds seconds');
}

/// Drives player A's real UI through claim-code pairing (step 1's A side).
Future<void> _pairPlayerA(
  WidgetTester tester,
  String claimCode, {
  int maxSeconds = 120,
}) async {
  await _waitForLoginScreen(tester);

  final textField = find.byType(TextFormField).first;
  expect(textField, findsOneWidget,
      reason: 'Should find the claim code input field');
  await tester.enterText(textField, claimCode.replaceAll('-', ''));
  await tester.pump(const Duration(milliseconds: 300));

  final connectButton = find.widgetWithText(ElevatedButton, 'Connect');
  expect(connectButton, findsOneWidget, reason: 'Should find Connect button');
  await tester.tap(connectButton);
  await tester.pump(const Duration(milliseconds: 100));

  for (var i = 0; i < maxSeconds; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (find.text('Connect to Server').evaluate().isEmpty) return;
  }
  fail('Player A pairing did not complete after $maxSeconds seconds');
}

/// Opens the cast picker and waits for [nodeId]'s tile to appear, retrying a
/// few fresh discovery sweeps (`castDiscoveryProvider` is `autoDispose` and
/// re-sweeps every time the dialog reopens — see that provider's own
/// dartdoc) rather than trusting a single 10-second sweep, since A↔B is a
/// brand new pairing with no warm connection or cached DNS discovery record
/// behind it yet, unlike A/B's own already-established links to the server.
Future<void> _openPickerAndWaitForDevice(
  WidgetTester tester,
  String nodeId, {
  int maxAttempts = 4,
}) async {
  final deviceKey = Key('cast-device-$nodeId');
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    await tester.tap(find.byKey(const Key('cast-button')));
    await tester.pump(const Duration(milliseconds: 300));

    final found = await _pumpUntil(
      tester,
      () => find.byKey(deviceKey).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 15),
    );
    if (found) return;

    debugPrint(
        '[RemoteControlE2E] B not in picker on sweep $attempt/$maxAttempts, retrying');
    final closeButton = find.widgetWithText(TextButton, 'Close');
    if (closeButton.evaluate().isNotEmpty) {
      await tester.tap(closeButton);
      await tester.pump(const Duration(milliseconds: 300));
    }
  }
  fail('Player B ($nodeId) never appeared in the cast picker '
      'after $maxAttempts sweeps');
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MyApp)),
        listen: false);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final adminApi = E2eApiClient.fromEnvironment();

  setUpAll(() async {
    await ensureTestBootstrap();
    await adminApi.waitForHealthy();
    await adminApi.login();
  });

  testWidgets('one player drives another end to end', (tester) async {
    final movie = await _fetchTestMovie(adminApi);

    // --- Player B: headless, real p2p host + real pairing (steps 1 & 2) ---
    //
    // See the file header for why B has no widget tree: a second `MyApp()`
    // collides on `rootNavigatorKey`, so this builds B from the same
    // non-UI classes `MyApp`'s own startup path wires together.
    final bClaimCode = await _generateClaimCode(adminApi, 'B');
    final bP2p = P2pService();
    final bPairing = PairingService(
      authStorage: _InMemoryAuthStorage(),
      p2pService: bP2p,
    );

    final bResult = await bPairing.pairWithClaimCodeOnly(
      claimCode: bClaimCode,
      deviceName: 'Player B (E2E target)',
    );
    expect(bResult.success, isTrue,
        reason: 'Player B failed to pair: ${bResult.error}');

    final bNodeId = bP2p.nodeId;
    expect(bNodeId, isNotNull, reason: 'Player B has no node ID after pairing');

    final bClient = createGraphQLClient(
        adminApi.mydiaUrl, bResult.credentials!.accessToken);

    final bRegistered = await NodeRegistration(
      client: bClient,
      nodeId: () async => bP2p.nodeId,
    ).register();
    expect(bRegistered, isTrue, reason: 'Player B node registration failed');

    final targetController = RemoteTargetController();
    final receiver = RemoteControlReceiver(
      roster: RemoteRoster(client: bClient),
      targetName: 'Player B (E2E target)',
      snapshotSource: targetController.snapshot,
      onIntent: targetController.submit,
      respond: bP2p.respondToControl,
    );
    final controlSub = bP2p.onControlRequest
        .listen((request) => unawaited(receiver.handle(request)));

    addTearDown(() async {
      await controlSub.cancel();
      targetController.dispose();
      await bP2p.dispose();
    });

    // Step 2: start playback locally on B, without involving A at all.
    final fakePlayer = _FakeTargetPlayer(
      mediaItemId: movie.id,
      title: movie.title,
      duration: _realMovieDuration,
    );
    fakePlayer.startPlaying(at: const Duration(milliseconds: 1500));
    targetController.attachPlayer(fakePlayer);

    // --- Player A: the real, UI-driven app (step 1's A side) ---
    //
    // Clear the shared store first, or this test cannot run inside
    // `all_tests.dart`. That aggregator runs every file in ONE isolate (see
    // `helpers/test_bootstrap.dart`), so the app's default `AuthStorage` is
    // process-wide — and `pairing_flow_test.dart`, which runs earlier, pairs a
    // real device into it and never clears it. Player B sidesteps this with an
    // injected in-memory store, but player A is a real `MyApp()` and uses the
    // default one, so without this it boots ALREADY AUTHENTICATED, routes
    // straight past the login screen, and `_waitForLoginScreen` times out
    // looking for text that will never render. Verified exactly that way in
    // CI run 32455230401: `[MyApp] authState=...AuthStatus.authenticated`
    // immediately after mount, then `Login screen not found after 30 seconds`.
    //
    // Deliberately not in `setUpAll`: player B pairs above and stores its
    // credentials in its own injected store, but clearing here rather than
    // earlier keeps the reset adjacent to the mount it exists to protect.
    await getAuthStorage().deleteAll();

    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    final aClaimCode = await _generateClaimCode(adminApi, 'A');
    await _pairPlayerA(tester, aClaimCode);

    final container = _containerOf(tester);
    final aNodeId = container.read(p2pServiceProvider).nodeId;
    expect(aNodeId, isNotNull, reason: 'Player A has no node ID after pairing');
    expect(aNodeId, isNot(equals(bNodeId)),
        reason: 'A and B must be distinct node identities');

    // Step 1: confirm both node IDs actually reached the server, not just
    // this process's own view of them. A plain async poll rather than
    // `_pumpUntil`: the wait is on the admin GraphQL API, not on anything
    // the widget tree needs to settle.
    Future<bool> bothNodeIdsRegistered() async {
      const query = r'''
        query RemoteControlE2EDevices {
          devices { nodeId }
        }
      ''';
      final response = await adminApi.graphqlRequest(query, const {});
      final devices = response['data']?['devices'] as List? ?? const [];
      final nodeIds = devices
          .map((d) => d['nodeId'] as String?)
          .whereType<String>()
          .toSet();
      return nodeIds.contains(aNodeId) && nodeIds.contains(bNodeId);
    }

    var bothRegistered = false;
    for (var i = 0; i < 20; i++) {
      if (await bothNodeIdsRegistered()) {
        bothRegistered = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(bothRegistered, isTrue,
        reason: 'Both A and B node IDs should be registered on the server');

    // --- Step 3: open the picker on A, assert B appears with what it's
    // playing ---
    await _openPickerAndWaitForDevice(tester, bNodeId!);

    final deviceTile =
        tester.widget<ListTile>(find.byKey(Key('cast-device-$bNodeId')));
    final subtitle = deviceTile.subtitle;
    expect(subtitle, isA<Text>());
    expect((subtitle as Text).data, equals(movie.title),
        reason: "Picker should show what B is playing, session-agnostically");

    // --- Step 4: select B, assert A adopts rather than restarts ---
    await tester.tap(find.byKey(Key('cast-device-$bNodeId')));
    await tester.pump(const Duration(milliseconds: 300));

    final adopted = await _pumpUntil(
      tester,
      () {
        final session = container.read(castSessionProvider).value;
        return session != null &&
            session.device.id == bNodeId &&
            session.mediaInfo != null &&
            session.mediaInfo!.duration > Duration.zero;
      },
      timeout: const Duration(seconds: 20),
    );
    expect(adopted, isTrue, reason: "A never adopted B's live session");

    final adoptedSession = container.read(castSessionProvider).value!;
    expect(adoptedSession.mediaInfo!.title, equals(movie.title));
    // The crux of the whole feature: adoption must carry over B's real,
    // already-elapsed position. A restart-instead-of-adopt bug would leave
    // this at (or very near) zero. B is still reporting `playing`, so
    // `MydiaCastBackend`'s own client-side interpolation
    // (`_positionAt`/`_positionTicker`) can project a little past the exact
    // 1500ms B started at — hence a range, not exact equality, here and
    // only here.
    expect(
      adoptedSession.mediaInfo!.position,
      greaterThanOrEqualTo(const Duration(milliseconds: 500)),
      reason: 'Adoption must not reset position to (near) zero',
    );
    expect(adoptedSession.mediaInfo!.position,
        lessThanOrEqualTo(_realMovieDuration));

    // --- Step 5: pause from A, assert B is paused ---
    await tester.tap(find.byKey(const Key('cast-bar-play-pause')));
    final paused = await _pumpUntil(
      tester,
      () => fakePlayer.currentState == FlutterPlaybackState.paused,
      timeout: const Duration(seconds: 10),
    );
    expect(paused, isTrue, reason: 'B never paused after A sent Pause');

    // A's own view should agree, not just B's raw state.
    final pausedOnA = await _pumpUntil(
      tester,
      () =>
          container.read(castSessionProvider).value?.playbackState ==
          CastPlaybackState.paused,
      timeout: const Duration(seconds: 10),
    );
    expect(pausedOnA, isTrue, reason: "A's own session never reflected pause");

    final pausedPosition = fakePlayer.currentPosition;

    // --- Step 6: seek from A, assert B's position follows ---
    // `cast-bar-forward` always jumps +10s, clamped to the reported
    // duration (5s here) — so given a ~1.5s starting position this
    // deterministically lands B at the clip's very end (5000ms). That is
    // still exactly what step 6 asks: B's position follows A's seek.
    await tester.tap(find.byKey(const Key('cast-bar-forward')));
    final expectedSeekTarget = _realMovieDuration; // clamped target
    final sought = await _pumpUntil(
      tester,
      () =>
          (fakePlayer.currentPosition - expectedSeekTarget).abs() <=
          const Duration(milliseconds: 200),
      timeout: const Duration(seconds: 10),
    );
    expect(sought, isTrue,
        reason: "B's position did not follow A's seek "
            '(expected ~${expectedSeekTarget.inMilliseconds}ms, '
            'got ${fakePlayer.currentPosition.inMilliseconds}ms; '
            'was paused at ${pausedPosition.inMilliseconds}ms)');

    // Wait for A's own cached snapshot to reflect the seek too — `pullToLocal`
    // below reads *A's* last snapshot, not B's directly.
    final aSawSeek = await _pumpUntil(
      tester,
      () {
        final position =
            container.read(castSessionProvider).value?.mediaInfo?.position;
        return position != null &&
            (position - expectedSeekTarget).abs() <=
                const Duration(milliseconds: 200);
      },
      timeout: const Duration(seconds: 10),
    );
    expect(aSawSeek, isTrue,
        reason: "A's own cached position never caught up to the seek");

    // --- Step 7: pull playback back to A ---
    await tester.tap(find.byKey(const Key('cast-bar-pull')));

    final stopped = await _pumpUntil(
      tester,
      () => fakePlayer.currentState == FlutterPlaybackState.idle,
      timeout: const Duration(seconds: 10),
    );
    expect(stopped, isTrue,
        reason: 'B never stopped after A pulled playback back');

    final resumed = await _pumpUntil(
      tester,
      () => find.byType(PlayerScreen).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    expect(resumed, isTrue,
        reason: 'A never opened a local player after pulling playback back');

    final playerScreen = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(playerScreen.mediaId, equals(movie.id));
    final resumeSeconds = playerScreen.resumeSeconds;
    expect(resumeSeconds, isNotNull,
        reason: 'A should resume with an explicit position, not from scratch');
    // Not a restart at zero, and specifically at (or immediately below,
    // depending on integer-second truncation) the position pulled from B.
    expect(resumeSeconds, inInclusiveRange(4, 5),
        reason: 'A should resume locally at the position pulled from B '
            '(expected ~${expectedSeekTarget.inSeconds}s, got ${resumeSeconds}s)');

    // Cleanup, matching the existing integration tests' pattern: replace the
    // app widget to stop pending async work before the test function
    // returns.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
