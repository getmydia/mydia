import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_control_receiver.dart';
import 'package:player/core/remote/remote_roster.dart';
import 'package:player/native/lib.dart';

import '../../test_utils/stub_graphql_client.dart';

const _capabilities = FlutterTargetCapabilities(
  volume: true,
  trackSelection: true,
  nextPrevious: true,
);

// NOT const: BigInt.from and BigInt.zero are not const constructors, so any
// literal containing them cannot be const. This bites every FlutterPlaybackSnapshot
// and FlutterLoadContentRequest in this plan, since all their u64 fields cross
// the bridge as BigInt.
FlutterPlaybackSnapshot playingSnapshot() => FlutterPlaybackSnapshot(
      state: FlutterPlaybackState.playing,
      mediaItemId: 'item-1',
      episodeId: null,
      title: 'Blade Runner',
      subtitle: null,
      imageUrl: null,
      positionMs: BigInt.from(2530000),
      durationMs: BigInt.from(6960000),
      volume: 0.8,
      muted: false,
      audioTracks: [],
      subtitleTracks: [],
      selectedAudio: null,
      selectedSubtitle: null,
      capabilities: _capabilities,
      sequence: BigInt.one,
    );

/// A roster stub backed by a StubLink, so the real query path is exercised.
RemoteRoster rosterAllowing(List<String> nodeIds) => RemoteRoster(
      client: stubClient(StubLink.responses([
        {
          // Root `__typename` included: without it the normalized cache
          // refuses the write and the query reports a spurious exception.
          '__typename': 'Query',
          'devices': [
            for (final (i, id) in nodeIds.indexed)
              {
                '__typename': 'RemoteDevice',
                'id': 'd$i',
                'deviceName': 'Device $i',
                'platform': 'linux',
                'nodeId': id,
              }
          ],
        },
      ])),
      now: () => DateTime(2026, 8, 20, 12, 0),
    );

void main() {
  group('RemoteControlReceiver', () {
    late List<RemoteControlIntent> intents;
    late List<FlutterRemoteControlResponse> responses;

    RemoteControlReceiver build({
      required List<String> allowed,
      FlutterPlaybackSnapshot? snapshot,
    }) {
      intents = [];
      responses = [];
      return RemoteControlReceiver(
        roster: rosterAllowing(allowed),
        targetName: 'Living Room',
        snapshotSource: () => snapshot,
        onIntent: intents.add,
        respond: (_, response) async => responses.add(response),
      );
    }

    FlutterInboundControlRequest inbound(
      String peer,
      FlutterRemoteControlRequest request,
    ) =>
        FlutterInboundControlRequest(
          peer: peer,
          requestId: 'req-1',
          request: request,
        );

    test('answers Hello with its name and capabilities', () async {
      final receiver =
          build(allowed: ['node-controller'], snapshot: playingSnapshot());

      await receiver.handle(inbound(
        'node-controller',
        const FlutterRemoteControlRequest_Hello(
          controllerName: 'iPhone',
          protocolVersion: 1,
        ),
      ));

      expect(responses.single, isA<FlutterRemoteControlResponse_Welcome>());
      final welcome = responses.single as FlutterRemoteControlResponse_Welcome;
      expect(welcome.targetName, 'Living Room');
      expect(welcome.capabilities.volume, isTrue);
      expect(intents, isEmpty, reason: 'Hello is not a playback action');
    });

    test('refuses a peer that is not in the roster', () async {
      final receiver =
          build(allowed: ['node-mine'], snapshot: playingSnapshot());

      await receiver.handle(
          inbound('node-stranger', const FlutterRemoteControlRequest_Play()));

      expect(
          responses.single, isA<FlutterRemoteControlResponse_NotAuthorized>());
      expect(intents, isEmpty,
          reason: 'an unauthorized command must not reach playback');
    });

    test('reports state for a session it never started', () async {
      // The whole point of the feature: a controller that did not start this
      // session can still read and drive it.
      final receiver =
          build(allowed: ['node-controller'], snapshot: playingSnapshot());

      await receiver.handle(
        inbound(
            'node-controller', const FlutterRemoteControlRequest_GetState()),
      );

      expect(responses.single, isA<FlutterRemoteControlResponse_State>());
      final state = responses.single as FlutterRemoteControlResponse_State;
      expect(state.field0.title, 'Blade Runner');
      expect(state.field0.state, FlutterPlaybackState.playing);
    });

    test('answers NotPlaying when no player is mounted', () async {
      final receiver = build(allowed: ['node-controller'], snapshot: null);

      await receiver.handle(inbound(
          'node-controller', const FlutterRemoteControlRequest_Pause()));

      expect(responses.single, isA<FlutterRemoteControlResponse_NotPlaying>());
      expect(intents, isEmpty);
    });

    test('forwards a transport command as an intent and accepts it', () async {
      final receiver =
          build(allowed: ['node-controller'], snapshot: playingSnapshot());

      await receiver.handle(
        inbound('node-controller',
            FlutterRemoteControlRequest.seek(positionMs: BigInt.from(754000))),
      );

      expect(responses.single, isA<FlutterRemoteControlResponse_Accepted>());
      final intent = intents.single as TransportIntent;
      expect(intent.action, TransportAction.seek);
      expect(intent.position, const Duration(milliseconds: 754000));
    });

    test('accepts LoadContent even with no player mounted', () async {
      // LoadContent is what starts playback, so it must not be gated on a
      // player already existing. The app-level listener navigates.
      final receiver = build(allowed: ['node-controller'], snapshot: null);

      await receiver.handle(inbound(
        'node-controller',
        FlutterRemoteControlRequest_LoadContent(
          FlutterLoadContentRequest(
            mediaItemId: 'item-9',
            episodeId: null,
            positionMs: BigInt.zero,
            audioTrack: null,
            subtitleTrack: null,
            autoplay: true,
          ),
        ),
      ));

      expect(responses.single, isA<FlutterRemoteControlResponse_Accepted>());
      expect(intents.single, isA<LoadContentIntent>());
    });
  });
}
