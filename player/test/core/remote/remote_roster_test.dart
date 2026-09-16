import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:gql/language.dart' show printNode;
import 'package:graphql_flutter/graphql_flutter.dart' show Request;
import 'package:player/core/remote/remote_roster.dart';

import '../../test_utils/stub_graphql_client.dart';

/// The root `__typename` is not decoration: without it the normalized cache
/// refuses to write the result and the query reports a spurious exception,
/// which reads exactly like the code under test being broken.
Map<String, dynamic> devicesResponse(List<Map<String, dynamic>> devices) => {
      '__typename': 'Query',
      'devices': devices,
    };

Map<String, dynamic> device(
  String id,
  String name,
  String? nodeId, {
  bool isRevoked = false,
  bool? online,
}) =>
    {
      '__typename': 'RemoteDevice',
      'id': id,
      'deviceName': name,
      'platform': 'linux',
      'nodeId': nodeId,
      'isRevoked': isRevoked,
      if (online != null) 'online': online,
    };

RemoteRoster rosterWith(StubLink link, DateTime Function() now) => RemoteRoster(
      client: stubClient(link),
      now: now,
    );

bool asksForOnline(Request request) =>
    printNode(request.operation.document).contains('online');

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

    test('omits revoked devices from the picker list', () async {
      final link = StubLink.responses([
        devicesResponse([
          device('d1', 'Kitchen', 'a' * 64),
          device('d2', 'Old Tablet', 'b' * 64, isRevoked: true),
        ]),
      ]);

      final roster = rosterWith(link, () => fixedClock);
      final entries = await roster.entries();

      expect(entries.map((e) => e.id), ['d1']);
    });

    test('refuses a revoked device that tries to drive this one', () async {
      final link = StubLink.responses([
        devicesResponse([
          device('d2', 'Old Tablet', 'b' * 64, isRevoked: true),
        ]),
      ]);

      final roster = rosterWith(link, () => fixedClock);

      expect(await roster.allows('b' * 64), isFalse);
    });
  });

  group('RemoteRoster.onlineEntries', () {
    test('keeps only devices the server reports online', () async {
      final roster = rosterWith(
        StubLink.responses([
          devicesResponse([
            device('d1', 'Hall Screen', 'a' * 64, online: true),
            device('d2', 'Attic Tablet', 'b' * 64, online: false),
            device('d3', 'Spare Phone', null, online: true),
            device('d4', 'Lent Laptop', 'c' * 64,
                isRevoked: true, online: true),
          ]),
        ]),
        () => fixedClock,
      );

      final entries = await roster.onlineEntries();

      expect(entries.map((e) => e.id), ['d1']);
    });

    test('asks the server on every call instead of reusing a cached list',
        () async {
      // A screen switched on a moment ago must be probed on the very next
      // scan, not after the roster's 15 minute TTL.
      final link = StubLink.responses([
        devicesResponse([
          device('d1', 'Hall Screen', 'a' * 64, online: false),
        ]),
        devicesResponse([
          device('d1', 'Hall Screen', 'a' * 64, online: true),
        ]),
      ]);
      final roster = rosterWith(link, () => fixedClock);

      expect(await roster.onlineEntries(), isEmpty);
      expect((await roster.onlineEntries()).map((e) => e.id), ['d1']);
      expect(link.requests.length, 2);
    });

    test('falls back to every device when the server predates online',
        () async {
      final link = StubLink((request, _) => asksForOnline(request)
          ? graphqlErrorResponse(
              'Cannot query field "online" on type "RemoteDevice".')
          : devicesResponse([
              device('d1', 'Hall Screen', 'a' * 64),
              device('d2', 'Attic Tablet', 'b' * 64),
            ]));
      final roster = rosterWith(link, () => fixedClock);

      expect((await roster.onlineEntries()).map((e) => e.id), ['d1', 'd2']);
      expect((await roster.onlineEntries()).map((e) => e.id), ['d1', 'd2']);

      expect(link.requests.where(asksForOnline).length, 1,
          reason: 'an old server is detected once, not re-asked every scan');
    });

    test('recognises the unknown-field error when it arrives over p2p',
        () async {
      // P2pGraphQLLink wraps the server's message in the Exception's text.
      final link = StubLink((request, _) => asksForOnline(request)
          ? graphqlErrorResponse('Exception: Cannot query field "online" '
              'on type "RemoteDevice".')
          : devicesResponse([device('d1', 'Hall Screen', 'a' * 64)]));
      final roster = rosterWith(link, () => fixedClock);

      expect((await roster.onlineEntries()).map((e) => e.id), ['d1']);
    });

    test('answers the last list it had when a fetch fails', () async {
      final link = StubLink.responses([
        devicesResponse([
          device('d1', 'Hall Screen', 'a' * 64, online: true),
        ]),
        Exception('connection reset'),
        devicesResponse([
          device('d1', 'Hall Screen', 'a' * 64, online: false),
        ]),
      ]);
      final roster = rosterWith(link, () => fixedClock);

      expect((await roster.onlineEntries()).map((e) => e.id), ['d1']);
      expect((await roster.onlineEntries()).map((e) => e.id), ['d1'],
          reason: 'a failed fetch keeps the previous answer');
      expect(await roster.onlineEntries(), isEmpty,
          reason: 'a transient failure must not switch to the fallback');
    });

    test('answers an empty list when the very first fetch fails', () async {
      final roster = rosterWith(
        StubLink.responses([Exception('connection reset')]),
        () => fixedClock,
      );

      expect(await roster.onlineEntries(), isEmpty);
    });

    test('leaves the access control list alone', () async {
      // entries() also backs allows(). An offline device may still drive this
      // one the moment it wakes up.
      final roster = rosterWith(
        StubLink((request, _) => devicesResponse([
              device('d1', 'Hall Screen', 'a' * 64,
                  online: asksForOnline(request) ? false : null),
            ])),
        () => fixedClock,
      );

      expect(await roster.onlineEntries(), isEmpty);
      expect(await roster.allows('a' * 64), isTrue);
    });
  });
}
