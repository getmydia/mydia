import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/mydia_cast_backend.dart';
import 'package:player/core/remote/remote_control_protocol.dart';
import 'package:player/core/remote/remote_roster.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/native/lib.dart';

import '../../test_utils/stub_graphql_client.dart';

/// A transport that answers from a script instead of dialing a real node.
class FakeTransport implements MydiaControlTransport {
  final Map<String, List<FlutterRemoteControlResponse>> scripted;
  final Set<String> unreachable;

  /// Nodes that answer `Hello` normally (from [scripted]) but throw on the
  /// discovery probe's follow-up `GetState` specifically — unlike
  /// [unreachable], which fails every request including `Hello` itself. This
  /// is what a target that Hello-succeeds but times out or errors on the
  /// state fetch looks like: reachable, but its playback state genuinely
  /// unknown.
  final Set<String> getStateFails;

  final sent = <String>[];

  /// The actual request objects passed to [send], in order. `sent` only
  /// records `'$nodeId:${request.runtimeType}'`, which passes for the right
  /// variant carrying a wrong or dropped payload — this is what lets a test
  /// assert on the real field values instead.
  final requests = <FlutterRemoteControlRequest>[];

  FakeTransport({
    this.scripted = const {},
    this.unreachable = const {},
    this.getStateFails = const {},
  });

  @override
  Future<FlutterRemoteControlResponse> send(
    String nodeId,
    FlutterRemoteControlRequest request,
  ) async {
    sent.add('$nodeId:${request.runtimeType}');
    requests.add(request);
    if (unreachable.contains(nodeId)) {
      throw StateError('unreachable');
    }
    if (getStateFails.contains(nodeId) &&
        request is FlutterRemoteControlRequest_GetState) {
      throw StateError('getState failed');
    }
    final queue = scripted[nodeId];
    if (queue == null || queue.isEmpty) {
      return const FlutterRemoteControlResponse_Accepted();
    }
    return queue.removeAt(0);
  }
}

/// A transport that answers after [delay] — for pinning
/// `probeMydiaNodeState`'s own timeout against `fakeAsync`, where a bare
/// `Future.delayed` inside [FakeTransport] would need the same treatment
/// anyway.
class _SlowTransport implements MydiaControlTransport {
  _SlowTransport(this.response, {required this.delay});

  final FlutterRemoteControlResponse response;
  final Duration delay;

  @override
  Future<FlutterRemoteControlResponse> send(
    String nodeId,
    FlutterRemoteControlRequest request,
  ) =>
      Future.delayed(delay, () => response);
}

/// A transport that answers `Hello` with [_welcome] immediately, but every
/// other request hangs on [pending] until the test completes it — for
/// simulating a response landing after the caller has already moved on
/// (e.g. `dispose()`).
class _StallingTransport implements MydiaControlTransport {
  final pending = Completer<FlutterRemoteControlResponse>();

  @override
  Future<FlutterRemoteControlResponse> send(
    String nodeId,
    FlutterRemoteControlRequest request,
  ) async {
    if (request is FlutterRemoteControlRequest_Hello) return _welcome;
    return pending.future;
  }
}

/// A [FlutterPlaybackSnapshot] with sensible defaults for every required
/// field, so a test only has to spell out the fields it cares about.
FlutterPlaybackSnapshot _snapshot({
  FlutterPlaybackState state = FlutterPlaybackState.playing,
  String? mediaItemId,
  String? episodeId,
  String title = 'Blade Runner',
  BigInt? positionMs,
  BigInt? durationMs,
  double? volume,
  BigInt? sequence,
}) =>
    FlutterPlaybackSnapshot(
      state: state,
      mediaItemId: mediaItemId,
      episodeId: episodeId,
      title: title,
      positionMs: positionMs ?? BigInt.zero,
      durationMs: durationMs ?? BigInt.from(60000),
      volume: volume,
      muted: false,
      audioTracks: const [],
      subtitleTracks: const [],
      capabilities: const FlutterTargetCapabilities(
        volume: true,
        trackSelection: true,
        nextPrevious: false,
      ),
      sequence: sequence ?? BigInt.one,
    );

const _connectedDevice = CastDevice(
  id: 'node-tv',
  name: 'Living Room',
  protocol: CastProtocolKind.mydia,
  metadata: {'nodeId': 'node-tv'},
);

RemoteRoster rosterOf(List<(String, String)> devices) => RemoteRoster(
      client: stubClient(StubLink.responses([
        {
          // Root `__typename` included: without it the normalized cache
          // refuses the write and the query reports a spurious exception.
          '__typename': 'Query',
          'devices': [
            for (final (id, nodeId) in devices)
              {
                '__typename': 'RemoteDevice',
                'id': id,
                'deviceName': 'Device $id',
                'platform': 'linux',
                'nodeId': nodeId,
              }
          ],
        },
      ])),
      now: () => DateTime(2026, 8, 20, 12, 0),
    );

const _welcome = FlutterRemoteControlResponse_Welcome(
  targetName: 'Living Room',
  protocolVersion: 1,
  capabilities: FlutterTargetCapabilities(
    volume: true,
    trackSelection: true,
    nextPrevious: false,
  ),
);

void main() {
  group('MydiaCastBackend discovery', () {
    test('lists reachable devices and omits this one', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          _welcome,
          FlutterRemoteControlResponse_State(
            _snapshot(state: FlutterPlaybackState.playing, title: 'Dune'),
          ),
        ],
      });

      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv'), ('d2', 'node-self')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final devices = await backend
          .startDiscovery(capabilities: const CastCapabilities.full())
          .first;

      expect(devices.map((d) => d.id), ['node-tv']);
      expect(devices.single.protocol, CastProtocolKind.mydia);
      expect(devices.single.name, 'Living Room',
          reason: 'the name comes from the target itself, not the roster row');
      expect(devices.single.metadata['nowPlayingTitle'], 'Dune',
          reason: 'the discovery GetState follow-up succeeded while playing');
    });

    test(
        'omits nowPlayingTitle when the GetState follow-up confirms the '
        'target genuinely idle', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          _welcome,
          FlutterRemoteControlResponse_State(
            _snapshot(state: FlutterPlaybackState.idle),
          ),
        ],
      });

      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final devices = await backend
          .startDiscovery(capabilities: const CastCapabilities.full())
          .first;

      expect(devices.single.metadata.containsKey('nowPlayingTitle'), isFalse,
          reason: 'GetState succeeded and confirmed nothing is loaded at '
              'all, so the fallback title never applies');
    });

    test(
        'sets nowPlayingTitle for a paused target too, so adopting it does '
        'not clobber a resumable session', () async {
      // Picking a device from the list dials `connectTo`, which restarts
      // playback outright for anything this probe does not flag as
      // adoptable (see `isPlayingMydiaTarget`). A paused target is just as
      // mid-watch as a playing one — only a target confirmed genuinely idle
      // (see the sibling test above) should read that way.
      final transport = FakeTransport(scripted: {
        'node-tv': [
          _welcome,
          FlutterRemoteControlResponse_State(
            _snapshot(state: FlutterPlaybackState.paused, title: 'Arrival'),
          ),
        ],
      });

      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final devices = await backend
          .startDiscovery(capabilities: const CastCapabilities.full())
          .first;

      expect(devices.single.metadata['nowPlayingTitle'], 'Arrival');
    });

    test(
        'flags statusUnavailable when Hello succeeds but the GetState '
        'follow-up fails', () async {
      // Different from "omits a device that does not answer" below: this
      // target IS reachable (Hello worked, so it stays listed), but its
      // playback state genuinely could not be determined — a distinct claim
      // from "confirmed not playing", which the picker's copy has to tell
      // apart (see `cast_device_picker.dart`).
      final transport = FakeTransport(
        scripted: {
          'node-tv': [_welcome],
        },
        getStateFails: {'node-tv'},
      );

      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final devices = await backend
          .startDiscovery(capabilities: const CastCapabilities.full())
          .first;

      expect(devices.single.metadata.containsKey('nowPlayingTitle'), isFalse);
      expect(devices.single.metadata['statusUnavailable'], 'true');
    });

    test('omits a device that does not answer', () async {
      final transport = FakeTransport(unreachable: {'node-tv'});

      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final devices = await backend
          .startDiscovery(capabilities: const CastCapabilities.full())
          .first;

      // An app that is closed is genuinely not controllable. Saying so is the
      // honest picker the design asks for.
      expect(devices, isEmpty);
    });
  });

  group('MydiaCastBackend connect', () {
    test(
        'throws and clears connectedDevice when Hello is answered with '
        'NotAuthorized, and never starts a poll timer', () {
      fakeAsync((async) {
        final transport = FakeTransport(scripted: {
          'node-tv': [const FlutterRemoteControlResponse_NotAuthorized()],
        });
        final backend = MydiaCastBackend(
          roster: rosterOf([('d1', 'node-tv')]),
          transport: transport,
          selfNodeId: 'node-self',
        );

        Object? caught;
        unawaited(backend.connect(_connectedDevice).catchError((e) {
          caught = e;
        }));
        async.flushMicrotasks();

        expect(caught, isA<CastBackendException>(),
            reason: 'a refused Hello must fail connect(), not silently '
                'commit a connected session');
        expect(
          (caught as CastBackendException).kind,
          CastFailureKind.notAuthorized,
        );
        expect(backend.connectedDevice, isNull,
            reason: 'a refused Hello must not leave connectedDevice naming '
                'a target that refused this device');

        // No poll timer was ever armed against the refusing target:
        // elapsing well past both poll cadences (1s visible, 5s background)
        // must produce no further sends at all.
        async.elapse(const Duration(seconds: 10));
        expect(
          transport.sent.where((s) => s.contains('GetState')),
          isEmpty,
          reason: 'connect must not start polling a target that refused us',
        );

        backend.dispose();
      });
    });

    test('throws CastBackendException for any other non-Welcome answer too',
        () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [const FlutterRemoteControlResponse_Error('boom')],
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      await expectLater(
        backend.connect(_connectedDevice),
        throwsA(isA<CastBackendException>()),
      );
      expect(backend.connectedDevice, isNull);
    });

    test('clears connectedDevice when the transport itself throws on Hello',
        () async {
      final transport = FakeTransport(unreachable: {'node-tv'});
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      await expectLater(
        backend.connect(_connectedDevice),
        throwsA(isA<CastBackendException>()),
      );
      expect(backend.connectedDevice, isNull,
          reason: 'a target the transport never reached must not be named '
              'as connected');
    });

    test('succeeds and starts polling when Hello answers Welcome', () {
      fakeAsync((async) {
        final transport = FakeTransport(scripted: {
          'node-tv': [_welcome],
        });
        final backend = MydiaCastBackend(
          roster: rosterOf([('d1', 'node-tv')]),
          transport: transport,
          selfNodeId: 'node-self',
        );

        unawaited(backend.connect(_connectedDevice));
        async.flushMicrotasks();

        expect(backend.connectedDevice, _connectedDevice);

        async.elapse(const Duration(seconds: 1));
        expect(
          transport.sent.where((s) => s.contains('GetState')),
          hasLength(1),
          reason: 'a successful connect must still start the poll timer',
        );

        backend.dispose();
      });
    });

    test(
        'throws and clears connectedDevice when Welcome reports an '
        'incompatible protocol version', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          const FlutterRemoteControlResponse_Welcome(
            targetName: 'Living Room',
            // One past whatever this build actually speaks — not hardcoded
            // to a literal, so this stays a mismatch even if
            // `remoteControlProtocolVersion` is ever bumped.
            protocolVersion: remoteControlProtocolVersion + 1,
            capabilities: FlutterTargetCapabilities(
              volume: true,
              trackSelection: true,
              nextPrevious: false,
            ),
          ),
        ],
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      await expectLater(
        backend.connect(_connectedDevice),
        throwsA(isA<CastBackendException>()),
      );
      expect(backend.connectedDevice, isNull,
          reason: 'a protocol mismatch must not be recorded as a live, '
              'connected session');
    });

    test(
        'discovery does not offer a target reporting an incompatible '
        'protocol version', () async {
      final transport = FakeTransport(scripted: {
        'node-old': [
          const FlutterRemoteControlResponse_Welcome(
            targetName: 'Old Build',
            protocolVersion: remoteControlProtocolVersion + 1,
            capabilities: FlutterTargetCapabilities(
              volume: true,
              trackSelection: true,
              nextPrevious: false,
            ),
          ),
        ],
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-old')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final devices = await backend
          .startDiscovery(capabilities: const CastCapabilities.full())
          .first;

      expect(devices, isEmpty);
    });
  });

  group('MydiaCastBackend dispose', () {
    test(
        'a command answer landing after dispose does not throw on the '
        'closed streams', () async {
      final transport = _StallingTransport();
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      await backend.connect(_connectedDevice);

      // `play()` sends the Play command through `_sendCommand` -> `_send`,
      // which now hangs on `transport.pending` until this test completes it
      // below — simulating a response landing after `dispose()` has already
      // closed every stream controller.
      final playFuture = backend.play();

      await backend.dispose();

      // Without the `_disposed` guard, completing this makes
      // `_sendCommand`'s `_handleResponse` call `_states.add`/... on a
      // closed `StreamController`, throwing `StateError: Cannot add new
      // events after calling close` — which surfaces as an error on
      // `playFuture` since `_handleResponse` runs outside `_sendCommand`'s
      // own try/catch.
      transport.pending.complete(FlutterRemoteControlResponse_State(
        _snapshot(),
      ));

      await expectLater(playFuture, completes);
    });
  });

  group('MydiaCastBackend commands', () {
    test(
        'sends the load-content payload with real field values, not just '
        'the right envelope', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [_welcome]
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      await backend.connect(const CastDevice(
        id: 'node-tv',
        name: 'Living Room',
        protocol: CastProtocolKind.mydia,
        metadata: {'nodeId': 'node-tv'},
      ));

      await backend.loadMedia(const CastMediaRequest(
        url: '',
        kind: CastMediaKind.hls,
        title: 'Blade Runner',
        startPosition: Duration(seconds: 30),
        contentRef: MydiaContentRef(
          mediaItemId: 'item-1',
          episodeId: 'ep-4',
          audioTrack: 'audio-eng',
          subtitleTrack: 'sub-fre',
        ),
      ));

      final loadRequests = transport.requests
          .whereType<FlutterRemoteControlRequest_LoadContent>();
      expect(loadRequests, hasLength(1));
      final payload = loadRequests.single.field0;
      expect(payload.mediaItemId, 'item-1');
      expect(payload.episodeId, 'ep-4');
      expect(payload.audioTrack, 'audio-eng');
      expect(payload.subtitleTrack, 'sub-fre');
      expect(payload.positionMs, BigInt.from(30000));
      expect(payload.autoplay, isTrue);
    });

    test(
        'discards a stale sequence number so a slower poll cannot regress '
        'state', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          _welcome,
          FlutterRemoteControlResponse_State(_snapshot(
            state: FlutterPlaybackState.playing,
            positionMs: BigInt.from(10000),
            durationMs: BigInt.from(60000),
            sequence: BigInt.from(5),
          )),
          FlutterRemoteControlResponse_State(_snapshot(
            state: FlutterPlaybackState.playing,
            positionMs: BigInt.from(1000),
            durationMs: BigInt.from(60000),
            sequence: BigInt.from(3), // stale: lower than the seq-5 above
          )),
        ],
      });

      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
        // Fixed and never advanced, so `_positionAt`'s elapsed-since-capture
        // term is always exactly zero and the published position exactly
        // matches each snapshot's `positionMs` — no wall-clock jitter to
        // blur the seq-5-vs-seq-3 comparison below.
        now: () => DateTime(2026, 8, 20, 12, 0),
      );

      await backend.connect(_connectedDevice);

      final positions = <Duration>[];
      backend.positionStream.listen(positions.add);

      // `play()` sends the play command — answered here, per the script
      // above, by the seq-5 snapshot — and then immediately polls again
      // (`_sendCommand`'s post-command poll), which is answered by the
      // stale seq-3 snapshot.
      await backend.play();
      await Future<void>.delayed(Duration.zero);

      expect(positions, isNot(contains(const Duration(milliseconds: 1000))),
          reason:
              'the stale, lower-sequence snapshot must never reach the stream');
    });

    test('refuses a request with no content reference', () async {
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: FakeTransport(scripted: {
          'node-tv': [_welcome]
        }),
        selfNodeId: 'node-self',
      );

      await backend.connect(const CastDevice(
        id: 'node-tv',
        name: 'Living Room',
        protocol: CastProtocolKind.mydia,
        metadata: {'nodeId': 'node-tv'},
      ));

      expect(
        () => backend.loadMedia(const CastMediaRequest(
          url: 'https://example.test/index.m3u8',
          kind: CastMediaKind.hls,
          title: 'Blade Runner',
        )),
        throwsA(isA<CastBackendException>()),
      );
    });

    test('maps a NotAuthorized answer onto the notAuthorized failure',
        () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          _welcome,
          const FlutterRemoteControlResponse_NotAuthorized(),
        ],
      });

      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      await backend.connect(const CastDevice(
        id: 'node-tv',
        name: 'Living Room',
        protocol: CastProtocolKind.mydia,
        metadata: {'nodeId': 'node-tv'},
      ));

      final failures = <CastFailureKind>[];
      backend.failureStream.listen(failures.add);

      await backend.play();
      await Future<void>.delayed(Duration.zero);

      expect(failures, contains(CastFailureKind.notAuthorized));
    });

    test('reports capabilities from the target Welcome', () async {
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: FakeTransport(scripted: {
          'node-tv': [_welcome]
        }),
        selfNodeId: 'node-self',
      );

      await backend.connect(const CastDevice(
        id: 'node-tv',
        name: 'Living Room',
        protocol: CastProtocolKind.mydia,
        metadata: {'nodeId': 'node-tv'},
      ));

      expect(backend.capabilities.volume, isTrue);
      expect(backend.capabilities.nextPrevious, isFalse,
          reason: 'the target said it cannot step episodes');
    });

    test('treats a decode failure on Hello as a target that is too old',
        () async {
      final transport = FakeTransport(unreachable: {'node-old'});

      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-old')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final devices = await backend
          .startDiscovery(capabilities: const CastCapabilities.full())
          .first;

      // An old build cannot decode the new outer variant at all, so Hello
      // fails. The device is simply not offered.
      expect(devices, isEmpty);
    });
  });

  group('MydiaCastBackend snapshot bridge', () {
    test('lastSnapshot exposes what the generic streams collapse away',
        () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          _welcome,
          FlutterRemoteControlResponse_State(_snapshot(
            state: FlutterPlaybackState.playing,
            mediaItemId: 'item-1',
            episodeId: 'ep-2',
            title: 'Blade Runner',
          )),
        ],
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      expect(backend.lastSnapshot, isNull,
          reason: 'nothing has been polled yet');

      await backend.connect(_connectedDevice);
      await backend.play();

      // `positionStream`/`durationStream`/`stateStream` only ever carry a
      // `Duration` or an enum value — mediaItemId and episodeId have no
      // channel of their own on `CastBackend` at all. This is the seam that
      // closes that gap.
      expect(backend.lastSnapshot?.mediaItemId, 'item-1');
      expect(backend.lastSnapshot?.episodeId, 'ep-2');
    });

    test('a stale, lower-sequence snapshot never overwrites lastSnapshot',
        () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          _welcome,
          FlutterRemoteControlResponse_State(_snapshot(
            mediaItemId: 'item-fresh',
            sequence: BigInt.from(5),
          )),
          FlutterRemoteControlResponse_State(_snapshot(
            mediaItemId: 'item-stale',
            sequence: BigInt.from(3),
          )),
        ],
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      await backend.connect(_connectedDevice);
      // Same trigger `_applySnapshot`'s own sequence test uses: `play()`
      // consumes the fresh snapshot as its own response, then its follow-up
      // poll (`_sendCommand`) consumes the stale one.
      await backend.play();

      expect(backend.lastSnapshot?.mediaItemId, 'item-fresh',
          reason: 'the same ordering guard `_applySnapshot` uses for the '
              'generic streams also protects this seam — it is the same '
              'cached field, not a second one a stale poll could desync '
              'from the first');
    });
  });

  group('MydiaCastBackend probeReceiverContentUrl', () {
    test('reports mediaItemId:episodeId when an episode is loaded', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          FlutterRemoteControlResponse_State(
            _snapshot(mediaItemId: 'item-1', episodeId: 'ep-2'),
          ),
        ],
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final url = await backend.probeReceiverContentUrl(_connectedDevice);

      expect(url, 'item-1:ep-2');
    });

    test('reports just the mediaItemId when nothing episodic is loaded',
        () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          FlutterRemoteControlResponse_State(_snapshot(mediaItemId: 'item-1')),
        ],
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final url = await backend.probeReceiverContentUrl(_connectedDevice);

      expect(url, 'item-1');
    });

    test('cannot tell what is loaded when nothing is mounted', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [const FlutterRemoteControlResponse_NotPlaying()],
      });
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: transport,
        selfNodeId: 'node-self',
      );

      final url = await backend.probeReceiverContentUrl(_connectedDevice);

      expect(url, isNull);
    });

    test('cannot tell what is loaded when the target is unreachable', () async {
      final backend = MydiaCastBackend(
        roster: rosterOf([('d1', 'node-tv')]),
        transport: FakeTransport(unreachable: {'node-tv'}),
        selfNodeId: 'node-self',
      );

      final url = await backend.probeReceiverContentUrl(_connectedDevice);

      expect(url, isNull);
    });
  });

  group('probeMydiaNodeState', () {
    test('answers the snapshot for a node that is playing', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          FlutterRemoteControlResponse_State(
            _snapshot(state: FlutterPlaybackState.playing, title: 'Arrival'),
          ),
        ],
      });

      final snapshot = await probeMydiaNodeState(transport, 'node-tv');

      expect(snapshot?.title, 'Arrival');
      expect(transport.sent, ['node-tv:FlutterRemoteControlRequest_GetState'],
          reason: 'no Hello, no connect — just the one GetState');
    });

    test('answers the snapshot for a node that is paused too', () async {
      // Matches `isPlayingMydiaTarget`'s own reasoning: a paused-but-
      // resumable session is exactly the kind of thing ambient awareness
      // exists to surface, not something to treat as idle.
      final transport = FakeTransport(scripted: {
        'node-tv': [
          FlutterRemoteControlResponse_State(
            _snapshot(state: FlutterPlaybackState.paused, title: 'Arrival'),
          ),
        ],
      });

      final snapshot = await probeMydiaNodeState(transport, 'node-tv');

      expect(snapshot?.title, 'Arrival');
    });

    test('answers null for a node that is genuinely idle', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [
          FlutterRemoteControlResponse_State(
            _snapshot(state: FlutterPlaybackState.idle),
          ),
        ],
      });

      expect(await probeMydiaNodeState(transport, 'node-tv'), isNull);
    });

    test('answers null when the node has nothing mounted at all', () async {
      final transport = FakeTransport(scripted: {
        'node-tv': [const FlutterRemoteControlResponse_NotPlaying()],
      });

      expect(await probeMydiaNodeState(transport, 'node-tv'), isNull);
    });

    test('answers null for an unreachable node rather than throwing', () async {
      final transport = FakeTransport(unreachable: {'node-tv'});

      expect(await probeMydiaNodeState(transport, 'node-tv'), isNull);
    });

    test('answers null when the node does not respond within the timeout', () {
      fakeAsync((async) {
        final transport = _SlowTransport(
          FlutterRemoteControlResponse_State(
            _snapshot(state: FlutterPlaybackState.playing),
          ),
          delay: const Duration(seconds: 10),
        );

        FlutterPlaybackSnapshot? result;
        var completed = false;
        unawaited(probeMydiaNodeState(
          transport,
          'node-tv',
          timeout: const Duration(seconds: 3),
        ).then((snapshot) {
          result = snapshot;
          completed = true;
        }));

        async.elapse(const Duration(seconds: 3));

        expect(completed, isTrue);
        expect(result, isNull);
      });
    });
  });

  group('MydiaCastBackend poll cadence', () {
    test(
        'polls at 1 Hz while the remote UI is visible; hiding it moves the '
        'next tick to 5s', () {
      fakeAsync((async) {
        final transport = FakeTransport(scripted: {
          'node-tv': [_welcome],
        });
        final backend = MydiaCastBackend(
          roster: rosterOf([('d1', 'node-tv')]),
          transport: transport,
          selfNodeId: 'node-self',
        );

        unawaited(backend.connect(_connectedDevice));
        async.flushMicrotasks();

        int getStateCount() =>
            transport.sent.where((s) => s.contains('GetState')).length;

        expect(getStateCount(), 0,
            reason: 'only the connect Hello has gone out so far');

        async.elapse(const Duration(seconds: 1));
        expect(getStateCount(), 1);

        async.elapse(const Duration(seconds: 1));
        expect(getStateCount(), 2);

        backend.remoteUiVisible = false;

        // The 1 Hz timer was torn down and replaced; the next tick is 5s
        // out, not 1s.
        async.elapse(const Duration(seconds: 1));
        expect(getStateCount(), 2, reason: 'still short of the new 5s cadence');

        async.elapse(const Duration(seconds: 4));
        expect(getStateCount(), 3);

        backend.dispose();
      });
    });
  });

  group('MydiaCastBackend position interpolation', () {
    test('advances the published position while playing, between polls', () {
      fakeAsync((async) {
        DateTime now = DateTime(2026, 8, 20, 12, 0);
        final transport = FakeTransport(scripted: {
          'node-tv': [
            _welcome,
            FlutterRemoteControlResponse_State(_snapshot(
              state: FlutterPlaybackState.playing,
              positionMs: BigInt.from(10000),
              durationMs: BigInt.from(60000),
              sequence: BigInt.from(1),
            )),
          ],
        });
        final backend = MydiaCastBackend(
          roster: rosterOf([('d1', 'node-tv')]),
          transport: transport,
          selfNodeId: 'node-self',
          now: () => now,
        );

        unawaited(backend.connect(_connectedDevice));
        async.flushMicrotasks();

        final positions = <Duration>[];
        backend.positionStream.listen(positions.add);

        // The 1 Hz poll tick delivers the snapshot above at t=1s.
        now = now.add(const Duration(seconds: 1));
        async.elapse(const Duration(seconds: 1));

        // Two more seconds of wall clock, projected by the 500ms
        // interpolation ticker without a new poll landing.
        now = now.add(const Duration(seconds: 2));
        async.elapse(const Duration(seconds: 2));

        expect(positions.last, const Duration(milliseconds: 12000));

        backend.dispose();
      });
    });

    test('freezes the published position once the target is paused', () {
      fakeAsync((async) {
        DateTime now = DateTime(2026, 8, 20, 12, 0);
        final transport = FakeTransport(scripted: {
          'node-tv': [
            _welcome,
            FlutterRemoteControlResponse_State(_snapshot(
              state: FlutterPlaybackState.paused,
              positionMs: BigInt.from(12000),
              durationMs: BigInt.from(60000),
              sequence: BigInt.from(1),
            )),
          ],
        });
        final backend = MydiaCastBackend(
          roster: rosterOf([('d1', 'node-tv')]),
          transport: transport,
          selfNodeId: 'node-self',
          now: () => now,
        );

        unawaited(backend.connect(_connectedDevice));
        async.flushMicrotasks();

        final positions = <Duration>[];
        backend.positionStream.listen(positions.add);

        now = now.add(const Duration(seconds: 1));
        async.elapse(const Duration(seconds: 1));

        // Wall clock keeps moving, but a paused snapshot never advances just
        // because time passed.
        now = now.add(const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 5));

        expect(positions.last, const Duration(milliseconds: 12000));

        backend.dispose();
      });
    });

    test(
        'clamps the published position at duration rather than running '
        'past it', () {
      fakeAsync((async) {
        DateTime now = DateTime(2026, 8, 20, 12, 0);
        final transport = FakeTransport(scripted: {
          'node-tv': [
            _welcome,
            FlutterRemoteControlResponse_State(_snapshot(
              state: FlutterPlaybackState.playing,
              positionMs: BigInt.from(59000),
              durationMs: BigInt.from(60000),
              sequence: BigInt.from(1),
            )),
          ],
        });
        final backend = MydiaCastBackend(
          roster: rosterOf([('d1', 'node-tv')]),
          transport: transport,
          selfNodeId: 'node-self',
          now: () => now,
        );

        unawaited(backend.connect(_connectedDevice));
        async.flushMicrotasks();

        final positions = <Duration>[];
        backend.positionStream.listen(positions.add);

        now = now.add(const Duration(seconds: 1));
        async.elapse(const Duration(seconds: 1));

        // Five more seconds of wall clock would put the naive projection
        // well past the 60s duration.
        now = now.add(const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 5));

        expect(positions.last, const Duration(milliseconds: 60000),
            reason: 'clamped at duration, never running past it');

        backend.dispose();
      });
    });

    test(
        'never goes negative when the clock moves backward under the '
        'captured snapshot time', () {
      fakeAsync((async) {
        DateTime now = DateTime(2026, 8, 20, 12, 0);
        final transport = FakeTransport(scripted: {
          'node-tv': [
            _welcome,
            FlutterRemoteControlResponse_State(_snapshot(
              state: FlutterPlaybackState.playing,
              positionMs: BigInt.from(5000),
              durationMs: BigInt.from(60000),
              sequence: BigInt.from(1),
            )),
          ],
        });
        final backend = MydiaCastBackend(
          roster: rosterOf([('d1', 'node-tv')]),
          transport: transport,
          selfNodeId: 'node-self',
          now: () => now,
        );

        unawaited(backend.connect(_connectedDevice));
        async.flushMicrotasks();

        final positions = <Duration>[];
        backend.positionStream.listen(positions.add);

        // The poll tick at t=1s delivers and captures the snapshot above.
        now = now.add(const Duration(seconds: 1));
        async.elapse(const Duration(seconds: 1));

        // The clock then moves backward relative to the captured time (a
        // clock correction), so `elapsed` at the next interpolation tick is
        // negative.
        now = now.subtract(const Duration(milliseconds: 200));
        async.elapse(const Duration(milliseconds: 500));

        expect(positions.last, const Duration(milliseconds: 5000),
            reason: 'a negative elapsed must never subtract from the base '
                'position');

        backend.dispose();
      });
    });
  });
}
