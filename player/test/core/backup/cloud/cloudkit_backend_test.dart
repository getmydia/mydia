import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/cloud/cloud_backend.dart';
import 'package:player/core/backup/cloud/cloud_slot_transport.dart';
import 'package:player/core/backup/cloud/cloudkit_backend.dart';

import '../slot_transport_contract.dart';

/// One record of [_FakeZone], as the Swift handler stores it.
class _FakeRecord {
  _FakeRecord(this.deviceName, this.platform, this.bytes, this.changedAt);

  final String deviceName;
  final String platform;
  final List<int> bytes;
  final int changedAt;
}

/// One iCloud account's `Backup` zone. Every save or delete bumps [seq];
/// a change token is `tok-<seq>`, and a record's tag is `t<seq>` of its save.
class _FakeZone {
  int seq = 0;
  final records = <String, _FakeRecord>{};
  final deletedAt = <String, int>{};
}

/// The `mydia/cloudkit` handler. [zones] is keyed by user record name, so
/// switching [user] switches the account.
class _FakeCloudKit {
  _FakeCloudKit();

  final zones = <String, _FakeZone>{'user-a': _FakeZone()};
  String user = 'user-a';
  String status = 'available';
  final calls = <MethodCall>[];

  /// Codes thrown by the next calls of a method, in order.
  final failures = <String, List<String>>{};

  /// Tokens the server no longer accepts.
  bool expireTokens = false;

  _FakeZone get zone => zones.putIfAbsent(user, _FakeZone.new);

  void install(MethodChannel channel) => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final queued = failures[call.method];
        if (queued != null && queued.isNotEmpty) {
          throw PlatformException(code: queued.removeAt(0));
        }
        return _handle(call);
      });

  Object? _handle(MethodCall call) {
    final args =
        (call.arguments as Map<Object?, Object?>?)?.cast<String, Object?>() ??
        {};
    switch (call.method) {
      case 'accountStatus':
        return {
          'status': status,
          if (status == 'available') 'userRecordName': user,
        };
      case 'fetchChanges':
        final token = args['token'] as String?;
        var since = 0;
        if (token != null) {
          if (expireTokens) {
            throw PlatformException(code: 'changeTokenExpired');
          }
          since = int.parse(token.substring(4));
        }
        return {
          'records': [
            for (final e in zone.records.entries)
              if (e.value.changedAt > since)
                {
                  'slotId': e.key,
                  'deviceName': e.value.deviceName,
                  'platform': e.value.platform,
                  'updatedAt': 1700000000000 + e.value.changedAt,
                  'size': e.value.bytes.length,
                  'tag': 't${e.value.changedAt}',
                },
          ],
          'deleted': [
            if (token != null)
              for (final e in zone.deletedAt.entries)
                if (e.value > since && !zone.records.containsKey(e.key)) e.key,
          ],
          'token': 'tok-${zone.seq}',
        };
      case 'fetchPayload':
        final r = zone.records[args['slotId']];
        return r == null ? null : Uint8List.fromList(r.bytes);
      case 'save':
        final id = args['slotId'] as String;
        zone.records[id] = _FakeRecord(
          args['deviceName'] as String,
          args['platform'] as String,
          List<int>.of(args['bytes'] as Uint8List),
          ++zone.seq,
        );
        zone.deletedAt.remove(id);
        return null;
      case 'delete':
        final id = args['slotId'] as String;
        if (zone.records.remove(id) != null) zone.deletedAt[id] = ++zone.seq;
        return null;
      case 'subscribe':
        return null;
      case 'isEnabled':
        return status != 'disabled';
      case 'completePush':
        return null;
    }
    throw MissingPluginException(call.method);
  }

  List<Object?> tokensSent() => [
    for (final c in calls)
      if (c.method == 'fetchChanges')
        (c.arguments as Map<Object?, Object?>)['token'],
  ];
}

BackupMetaStore _meta() => BackupMetaStore(InMemoryBackupMetaStorage());

BackupRelayError _kindOf(Object? e) => (e as BackupRelayException).kind;

const _a = 'a1b2c3d4e5f60001';
const _b = 'a1b2c3d4e5f60002';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const channelA = MethodChannel('test/cloudkit-a');
  const channelB = MethodChannel('test/cloudkit-b');
  const events = EventChannel('test/cloudkit/changes');

  tearDown(() {
    messenger.setMockMethodCallHandler(channelA, null);
    messenger.setMockMethodCallHandler(channelB, null);
    messenger.setMockStreamHandler(events, null);
  });

  runSlotTransportContract('icloud', () async {
    // Two devices on one account: one fake zone behind both channels.
    _FakeCloudKit()
      ..install(channelA)
      ..install(channelB);
    return (
      CloudSlotTransport(
        CloudKitBackend(channel: channelA, events: events, meta: _meta()),
        _a,
      ),
      CloudSlotTransport(
        CloudKitBackend(channel: channelB, events: events, meta: _meta()),
        _b,
      ),
    );
  });

  group('CloudKitBackend', () {
    late _FakeCloudKit fake;
    late BackupMetaStore meta;
    late CloudKitBackend backend;
    late CloudKitBackend other;

    Future<void> write(
      CloudKitBackend b,
      String slot,
      List<int> bytes, {
      String name = 'Living Room',
    }) => b.writeBytes(slot, bytes, deviceName: name, platform: 'ios');

    setUp(() {
      fake = _FakeCloudKit()
        ..install(channelA)
        ..install(channelB);
      meta = _meta();
      backend = CloudKitBackend(channel: channelA, events: events, meta: meta);
      other = CloudKitBackend(channel: channelB, events: events, meta: _meta());
    });

    test('token_persisted_and_sent_back', () async {
      await write(backend, _a, [1, 2, 3]);
      final first = (await backend.list())!;
      expect(meta.cloudkitToken, 'tok-1');
      expect(first.cursor, 'tok-1');
      final slot = first.slots.single;
      expect(slot.slotId, _a);
      expect(slot.version, 't1');
      expect(slot.deviceName, 'Living Room');
      expect(slot.size, 3);
      expect(slot.updatedAtMs, 1700000000001);

      expect(await backend.list(cursor: first.cursor), isNull);
      expect(fake.tokensSent(), [null, 'tok-1']);

      await write(other, _b, [4]);
      final next = (await backend.list(cursor: first.cursor))!;
      expect(fake.tokensSent().last, 'tok-1');
      expect(meta.cloudkitToken, 'tok-2');
      expect(next.slots.map((s) => s.slotId).toSet(), {_a, _b});
    });

    test('table_survives_a_new_backend_instance', () async {
      await write(backend, _a, [1]);
      await backend.list();
      final again = CloudKitBackend(
        channel: channelA,
        events: events,
        meta: meta,
      );
      final l = (await again.list())!;
      expect(fake.tokensSent().last, 'tok-1');
      expect(l.slots.single.slotId, _a);
    });

    test('unreadable_table_refetches_from_scratch', () async {
      await write(backend, _a, [1]);
      final first = (await backend.list())!;
      await meta.setCloudkitSlots('{not json');
      fake.calls.clear();
      final l = await backend.list(cursor: first.cursor);
      expect(fake.tokensSent(), [null]);
      expect(l!.slots.single.slotId, _a);
    });

    test('expired_token_refetches_once', () async {
      await write(backend, _a, [1]);
      await backend.list();
      await write(other, _b, [2]);
      fake.expireTokens = true;
      fake.calls.clear();

      final l = (await backend.list())!;
      expect(fake.tokensSent(), ['tok-1', null]);
      expect(l.slots.map((s) => s.slotId).toSet(), {_a, _b});
      expect(meta.cloudkitToken, 'tok-2');
    });

    test('expired_token_twice_is_an_error', () async {
      await write(backend, _a, [1]);
      await backend.list();
      fake.failures['fetchChanges'] = [
        'changeTokenExpired',
        'changeTokenExpired',
      ];
      fake.calls.clear();
      await expectLater(
        backend.list(),
        throwsA(predicate((e) => _kindOf(e) == BackupRelayError.server)),
      );
      expect(fake.tokensSent(), ['tok-1', null]);
    });

    test('zone_not_found_clears_table_and_refetches', () async {
      await write(backend, _a, [1]);
      await backend.list();
      // The user deleted the zone from iCloud settings; a new one is empty.
      fake.zones['user-a'] = _FakeZone();
      fake.failures['fetchChanges'] = ['zoneNotFound'];
      fake.calls.clear();
      final l = (await backend.list())!;
      expect(fake.tokensSent(), ['tok-1', null]);
      expect(l.slots, isEmpty);
    });

    test('deleted_ids_drop_from_listing', () async {
      await write(backend, _a, [1]);
      await write(other, _b, [2]);
      final first = (await backend.list())!;
      expect(first.slots, hasLength(2));

      await other.delete(_a);
      final next = (await backend.list(cursor: first.cursor))!;
      expect(next.slots.map((s) => s.slotId), [_b]);
      expect(meta.cloudkitSlots, isNot(contains(_a)));
    });

    test('account_change_resets_token', () async {
      await write(backend, _a, [1]);
      await backend.list();
      expect(meta.cloudkitUser, 'user-a');

      fake.user = 'user-b';
      await write(other, _b, [9]);
      fake.calls.clear();

      final l = (await backend.list())!;
      expect(fake.tokensSent(), [null]);
      expect(l.slots.map((s) => s.slotId), [_b]);
      expect(meta.cloudkitUser, 'user-b');
      expect(meta.cloudkitToken, 'tok-1');
    });

    test('account_change_in_availability_resets_token', () async {
      await write(backend, _a, [1]);
      await backend.list();
      fake.user = 'user-b';
      expect(await backend.availability(), isA<CloudAvailable>());
      expect(meta.cloudkitToken, isNull);
      expect(meta.cloudkitSlots, isNull);
      expect(meta.cloudkitUser, 'user-b');
    });

    test('not_authenticated_maps_to_cloudUnavailable', () async {
      fake.failures['fetchChanges'] = ['notAuthenticated'];
      await expectLater(
        backend.list(),
        throwsA(
          predicate((e) => _kindOf(e) == BackupRelayError.cloudUnavailable),
        ),
      );
      fake.failures['save'] = ['unavailable'];
      await expectLater(
        write(backend, _a, [1]),
        throwsA(
          predicate((e) => _kindOf(e) == BackupRelayError.cloudUnavailable),
        ),
      );
    });

    test('signed_out_account_lists_as_cloudUnavailable', () async {
      fake.status = 'noAccount';
      await expectLater(
        backend.list(),
        throwsA(
          predicate((e) => _kindOf(e) == BackupRelayError.cloudUnavailable),
        ),
      );
      expect(fake.tokensSent(), isEmpty);
    });

    test('other_codes_map_to_kinds', () async {
      fake.failures['save'] = ['quotaExceeded', 'network', 'other'];
      await expectLater(
        write(backend, _a, [1]),
        throwsA(predicate((e) => _kindOf(e) == BackupRelayError.quotaFull)),
      );
      await expectLater(
        write(backend, _a, [1]),
        throwsA(predicate((e) => _kindOf(e) == BackupRelayError.network)),
      );
      await expectLater(
        write(backend, _a, [1]),
        throwsA(predicate((e) => _kindOf(e) == BackupRelayError.server)),
      );
    });

    test('availability_maps_account_status', () async {
      final ok = await backend.availability();
      expect((ok as CloudAvailable).accountLabel, isNull);
      expect(backend.kind, CloudStoreKind.icloud);
      for (final s in ['noAccount', 'restricted']) {
        fake.status = s;
        expect(
          await backend.availability(),
          isA<CloudUnavailable>(),
          reason: s,
        );
      }
      fake.status = 'temporarilyUnavailable';
      await expectLater(
        backend.availability(),
        throwsA(
          isA<BackupRelayException>().having(
            (e) => e.kind,
            'kind',
            BackupRelayError.network,
          ),
        ),
      );
      fake.failures['accountStatus'] = ['other'];
      expect(await backend.availability(), isA<CloudUnavailable>());
    });

    test('disabled_build_is_unavailable', () async {
      fake.status = 'disabled';
      expect(await backend.availability(), isA<CloudUnavailable>());
      await expectLater(
        backend.list(),
        throwsA(
          predicate((e) => _kindOf(e) == BackupRelayError.cloudUnavailable),
        ),
      );
      expect(fake.tokensSent(), isEmpty);
    });

    test('transient_account_status_error_is_not_unavailable', () async {
      fake.failures['accountStatus'] = ['network'];
      await expectLater(
        backend.availability(),
        throwsA(predicate((e) => _kindOf(e) == BackupRelayError.network)),
      );
      // Recovers on the next check.
      expect(await backend.availability(), isA<CloudAvailable>());
    });

    test('is_enabled_reads_the_channel', () async {
      expect(await CloudKitBackend.isEnabled(channel: channelA), isTrue);
      fake.status = 'disabled';
      expect(await CloudKitBackend.isEnabled(channel: channelA), isFalse);
      fake.failures['isEnabled'] = ['other'];
      expect(await CloudKitBackend.isEnabled(channel: channelA), isFalse);
      // No plugin at all (any platform but iOS and macOS).
      expect(
        await CloudKitBackend.isEnabled(
          channel: const MethodChannel('test/cloudkit-none'),
        ),
        isFalse,
      );
    });

    test('read_of_missing_slot_is_not_found', () async {
      await expectLater(
        backend.readBytes(_a),
        throwsA(predicate((e) => _kindOf(e) == BackupRelayError.notFound)),
      );
      fake.failures['fetchPayload'] = ['zoneNotFound'];
      await expectLater(
        backend.readBytes(_a),
        throwsA(predicate((e) => _kindOf(e) == BackupRelayError.notFound)),
      );
    });

    test('delete_of_missing_slot_is_success', () async {
      await backend.delete(_a);
      fake.failures['delete'] = ['zoneNotFound'];
      await backend.delete(_a);
    });

    test('first_list_subscribes_once', () async {
      await backend.list();
      await backend.list();
      expect(fake.calls.where((c) => c.method == 'subscribe'), hasLength(1));
    });

    test('subscribe_failure_does_not_fail_the_list', () async {
      fake.failures['subscribe'] = ['network'];
      expect(await backend.list(), isNotNull);
    });

    test('sign_out_clears_local_state_only', () async {
      await write(backend, _a, [1]);
      await backend.list();
      await backend.signOut();
      expect(meta.cloudkitToken, isNull);
      expect(meta.cloudkitSlots, isNull);
      expect(meta.cloudkitUser, isNull);
      expect(fake.zone.records, contains(_a));
    });

    test('changes_emit_on_native_events', () async {
      late MockStreamHandlerEventSink sink;
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (_, s) => sink = s,
          onCancel: (_) {},
        ),
      );
      final got = <void>[];
      final sub = backend.changes.listen(got.add);
      await pumpEventQueue();
      sink.success('push');
      sink.success('account');
      await pumpEventQueue();
      expect(got, hasLength(2));
      await sub.cancel();
    });

    test('list_with_null_cursor_resets_stale_table', () async {
      await write(backend, _a, [1]);
      final first = (await backend.list())!;
      expect(first.slots.map((s) => s.slotId), [_a]);

      await other.delete(_a);
      await meta.setCloudkitToken(null);

      // Even though meta.cloudkitSlots still held _a, a null-cursor list
      // resets the cached table instead of resurrecting deleted records.
      final freshBackend = CloudKitBackend(
        channel: channelA,
        events: events,
        meta: meta,
      );
      final afterReset = (await freshBackend.list())!;
      expect(afterReset.slots, isEmpty);
    });

    test('completePush_reports_outcome_only_when_push_is_pending', () async {
      late MockStreamHandlerEventSink sink;
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (_, s) => sink = s,
          onCancel: (_) {},
        ),
      );
      final sub = backend.changes.listen((_) {});
      await pumpEventQueue();

      await backend.completePush('noData');
      sink.success('account');
      await pumpEventQueue();
      await backend.completePush('noData');
      expect(fake.calls.where((c) => c.method == 'completePush'), isEmpty);

      sink.success('push');
      await pumpEventQueue();
      await backend.completePush('newData');
      await backend.completePush('noData');
      final pushCalls = fake.calls
          .where((c) => c.method == 'completePush')
          .toList();
      expect(pushCalls, hasLength(1));
      expect(
        (pushCalls.single.arguments as Map<Object?, Object?>)['result'],
        'newData',
      );
      await sub.cancel();
    });
  });
}
