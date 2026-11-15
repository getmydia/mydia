import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/slot_transport.dart';

BackupPayload _payload(String deviceName, {int stamp = 1, String? value}) =>
    BackupPayload(
      deviceName: deviceName,
      platform: 'android',
      createdAt: stamp,
      records: [
        SettingBackupRecord(
          key: 'setting:theme',
          settingKey: 'theme',
          value: value ?? 'dark-$stamp',
          updatedAt: stamp,
        ),
        WatchBackupRecord(
          key: 'watch:one',
          watched: true,
          positionSeconds: 12,
          durationSeconds: 90,
          updatedAt: stamp,
        ),
      ],
    );

SlotInfo _own(SlotListing l, SlotTransport t) =>
    l.slots.singleWhere((s) => s.slotId == t.ownSlotId);

/// Shared behavior every [SlotTransport] backend must satisfy. [make] returns
/// two transports with different `ownSlotId`s over one shared store.
void runSlotTransportContract(
  String name,
  Future<(SlotTransport a, SlotTransport b)> Function() make,
) {
  group('SlotTransport contract: $name', () {
    late SlotTransport a;
    late SlotTransport b;

    setUp(() async {
      (a, b) = await make();
      expect(a.ownSlotId, isNot(b.ownSlotId));
    });

    test('own_write_is_listed_with_device_name', () async {
      await a.writeOwn(_payload('Living Room'));
      final listing = (await a.list())!;
      expect(_own(listing, a).deviceName, 'Living Room');
    });

    test('version_changes_on_rewrite', () async {
      await a.writeOwn(_payload('Living Room', stamp: 1));
      final v1 = _own((await a.list())!, a).version;
      await a.writeOwn(_payload('Living Room', stamp: 2));
      final v2 = _own((await a.list())!, a).version;
      expect(v2, isNot(v1));
    });

    test('list_with_current_cursor_returns_null', () async {
      await a.writeOwn(_payload('Living Room'));
      final listing = (await a.list())!;
      expect(listing.cursor, isNotNull);
      expect(await a.list(cursor: listing.cursor), isNull);
    });

    test('other_device_write_makes_list_non_null', () async {
      await a.writeOwn(_payload('Living Room'));
      final listing = (await a.list())!;
      await b.writeOwn(_payload('Bedroom'));
      final next = await a.list(cursor: listing.cursor);
      expect(next, isNotNull);
      expect(next!.slots.map((s) => s.slotId),
          containsAll([a.ownSlotId, b.ownSlotId]));
    });

    test('read_roundtrips_payload', () async {
      final payload = _payload('Living Room');
      await a.writeOwn(payload);
      final info = _own((await b.list())!, a);
      final read = await b.read(info);
      expect(read.deviceName, payload.deviceName);
      expect(read.platform, payload.platform);
      expect(read.records, payload.records);
    });

    test('delete_removes_from_listing', () async {
      await a.writeOwn(_payload('Living Room'));
      await b.writeOwn(_payload('Bedroom'));
      await b.delete(a.ownSlotId);
      final listing = (await b.list())!;
      expect(listing.slots.map((s) => s.slotId), [b.ownSlotId]);
    });

    test('oversize_write_throws_tooLarge', () async {
      final rng = Random.secure();
      final noise = base64.encode(
          List<int>.generate(4 * 1024 * 1024 + 4096, (_) => rng.nextInt(256)));
      final big = _payload('Living Room', value: noise);
      expect(big.encode().length, greaterThan(4194304));
      await expectLater(
        a.writeOwn(big),
        throwsA(isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.tooLarge)),
      );
    });
  });
}
