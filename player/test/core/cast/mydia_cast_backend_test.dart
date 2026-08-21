import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/mydia_cast_backend.dart';
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
