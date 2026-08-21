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
  final sent = <String>[];

  FakeTransport({this.scripted = const {}, this.unreachable = const {}});

  @override
  Future<FlutterRemoteControlResponse> send(
    String nodeId,
    FlutterRemoteControlRequest request,
  ) async {
    sent.add('$nodeId:${request.runtimeType}');
    if (unreachable.contains(nodeId)) {
      throw StateError('unreachable');
    }
    final queue = scripted[nodeId];
    if (queue == null || queue.isEmpty) {
      return const FlutterRemoteControlResponse_Accepted();
    }
    return queue.removeAt(0);
  }
}

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
        'node-tv': [_welcome],
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
    test('sends a content reference rather than a URL', () async {
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
        contentRef: MydiaContentRef(
          mediaItemId: 'item-1',
          episodeId: null,
          audioTrack: null,
          subtitleTrack: null,
        ),
      ));

      expect(
        transport.sent.any((s) => s.contains('LoadContent')),
        isTrue,
      );
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
}
