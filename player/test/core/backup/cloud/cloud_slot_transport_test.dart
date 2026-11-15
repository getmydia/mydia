import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/cloud/cloud_slot_transport.dart';

import '../slot_transport_contract.dart';
import 'in_memory_cloud_backend.dart';

void main() {
  runSlotTransportContract('cloud', () async {
    final store = InMemoryCloudStore();
    return (
      CloudSlotTransport(InMemoryCloudBackend(store), 'slot-a'),
      CloudSlotTransport(InMemoryCloudBackend(store), 'slot-b'),
    );
  });

  group('CloudSlotTransport', () {
    late InMemoryCloudStore store;
    late CloudSlotTransport a;

    setUp(() {
      store = InMemoryCloudStore();
      a = CloudSlotTransport(InMemoryCloudBackend(store), 'slot-a');
    });

    test('writes the device name and platform with the slot', () async {
      await a.writeOwn(const BackupPayload(
          deviceName: 'Living Room',
          platform: 'ios',
          createdAt: 1,
          records: []));
      expect(store.names['slot-a'], 'Living Room');
      expect(store.platforms['slot-a'], 'ios');
    });

    test('a group record never reaches the store', () async {
      await a.writeOwn(const BackupPayload(
        deviceName: 'Living Room',
        platform: 'ios',
        createdAt: 1,
        records: [
          GroupBackupRecord(
              key: 'group',
              groupSecretB64: 'c2VjcmV0',
              nodeToSlot: {},
              updatedAt: 1),
        ],
      ));
      final stored = BackupPayload.decode(store.bytes['slot-a']!);
      expect(stored.records, isEmpty);
    });

    test('the own slot missing from a listing marks it stale', () async {
      final b = CloudSlotTransport(InMemoryCloudBackend(store), 'slot-b');
      await b.writeOwn(const BackupPayload(
          deviceName: 'Bedroom', platform: 'ios', createdAt: 1, records: []));
      expect((await a.list())!.ownStale, isTrue);
      await a.writeOwn(const BackupPayload(
          deviceName: 'Living Room',
          platform: 'ios',
          createdAt: 1,
          records: []));
      expect((await a.list())!.ownStale, isFalse);
    });
  });
}
