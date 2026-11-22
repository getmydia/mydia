import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_relay_client.dart';

import 'in_memory_slot_transport.dart';
import 'slot_transport_contract.dart';

void main() {
  runSlotTransportContract('in-memory', () async {
    final server = <String, List<int>>{};
    return (
      InMemorySlotTransport(ownSlotId: 'slot-a', server: server),
      InMemorySlotTransport(ownSlotId: 'slot-b', server: server),
    );
  });

  group('InMemorySlotTransport hooks', () {
    test('failNext fails exactly one call', () async {
      final t = InMemorySlotTransport(ownSlotId: 's', server: {});
      t.failNext(const BackupRelayException(BackupRelayError.network));
      await expectLater(
        t.list(),
        throwsA(
          isA<BackupRelayException>().having(
            (e) => e.kind,
            'kind',
            BackupRelayError.network,
          ),
        ),
      );
      expect(await t.list(), isNotNull);
    });

    test('pushChange emits on changes', () async {
      final t = InMemorySlotTransport(ownSlotId: 's', server: {});
      final future = t.changes.first;
      t.pushChange();
      await future;
    });

    test('undecodable slot read throws FormatException', () async {
      final server = <String, List<int>>{
        'bad': [1, 2, 3],
      };
      final t = InMemorySlotTransport(ownSlotId: 's', server: server);
      final info = (await t.list())!.slots.single;
      await expectLater(t.read(info), throwsFormatException);
    });
  });
}
