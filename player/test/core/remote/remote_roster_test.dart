import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/remote_roster.dart';

import '../../test_utils/stub_graphql_client.dart';

/// The root `__typename` is not decoration: without it the normalized cache
/// refuses to write the result and the query reports a spurious exception,
/// which reads exactly like the code under test being broken.
Map<String, dynamic> devicesResponse(List<Map<String, dynamic>> devices) => {
      '__typename': 'Query',
      'devices': devices,
    };

Map<String, dynamic> device(String id, String name, String? nodeId) => {
      '__typename': 'RemoteDevice',
      'id': id,
      'deviceName': name,
      'platform': 'linux',
      'nodeId': nodeId,
    };

RemoteRoster rosterWith(StubLink link, DateTime Function() now) => RemoteRoster(
      client: stubClient(link),
      now: now,
    );

void main() {
  final fixedClock = DateTime(2026, 8, 20, 12, 0);

  group('RemoteRoster', () {
    test('lists only the devices that have a node id', () async {
      final roster = rosterWith(
        StubLink.responses([
          devicesResponse([
            device('d1', 'Living Room', 'node-a'),
            device('d2', 'Old Tablet', null),
          ]),
        ]),
        () => fixedClock,
      );

      final entries = await roster.entries();

      expect(entries.map((e) => e.id), ['d1']);
      expect(entries.single.nodeId, 'node-a');
    });

    test('allows a peer that is in the roster', () async {
      final roster = rosterWith(
        StubLink.responses([
          devicesResponse([device('d1', 'Living Room', 'node-a')])
        ]),
        () => fixedClock,
      );

      expect(await roster.allows('node-a'), isTrue);
    });

    test('refuses a peer that is not in the roster', () async {
      final roster = rosterWith(
        StubLink.responses([
          devicesResponse([device('d1', 'Living Room', 'node-a')])
        ]),
        () => fixedClock,
      );

      expect(await roster.allows('node-intruder'), isFalse);
    });

    test('refetches for an unknown peer, in case it was just paired', () async {
      final link = StubLink.responses([
        devicesResponse([device('d1', 'Living Room', 'node-a')]),
        devicesResponse([
          device('d1', 'Living Room', 'node-a'),
          device('d2', 'New Phone', 'node-b'),
        ]),
      ]);

      var clock = fixedClock;
      final roster = rosterWith(link, () => clock);

      expect(await roster.allows('node-b'), isFalse,
          reason: 'the first fetch predates the pairing');

      clock = clock.add(const Duration(minutes: 2));

      expect(await roster.allows('node-b'), isTrue,
          reason: 'a refetch picks it up');
    });

    test(
        'throttles the unknown-peer refetch so a stranger cannot hammer the server',
        () async {
      final link = StubLink.responses([
        devicesResponse([device('d1', 'Living Room', 'node-a')]),
      ]);

      final roster = rosterWith(link, () => fixedClock);

      for (var i = 0; i < 20; i++) {
        expect(await roster.allows('node-intruder-$i'), isFalse);
      }

      // The clock never advances past the one minute throttle, so twenty
      // strangers buy at most the initial fetch plus one refetch.
      // StubLink.responses repeats its last entry, so a short script is fine.
      expect(link.requests.length, lessThanOrEqualTo(2));
    });
  });
}
