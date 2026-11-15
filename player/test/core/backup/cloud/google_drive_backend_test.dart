import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/cloud/cloud_backend.dart';
import 'package:player/core/backup/cloud/cloud_slot_transport.dart';
import 'package:player/core/backup/cloud/google_auth.dart';
import 'package:player/core/backup/cloud/google_drive_backend.dart';

import '../slot_transport_contract.dart';
import 'fake_drive_server.dart';

/// A [GoogleAuth] whose token follows the fake server: a forced refresh
/// moves to the next token.
class _FakeAuth implements GoogleAuth {
  _FakeAuth(this.server);

  final FakeDriveServer server;
  String? email = 'ana@example.com';
  int refreshes = 0;
  bool refreshHelps = true;
  bool signedOut = false;
  String _token = 'token-1';

  @override
  Future<String?> currentEmail() async => email;

  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    if (forceRefresh) {
      refreshes++;
      if (refreshHelps) {
        _token = 'token-${refreshes + 1}';
        server.validToken = _token;
      }
    }
    return _token;
  }

  @override
  Future<void> signOut() async {
    signedOut = true;
    email = null;
  }
}

GoogleDriveBackend _backend(
        FakeDriveServer server, _FakeAuth auth, BackupMetaStore meta) =>
    GoogleDriveBackend(auth: auth, client: server.client, meta: meta);

BackupMetaStore _meta() => BackupMetaStore(InMemoryBackupMetaStorage());

Future<void> _write(GoogleDriveBackend b, String slot, List<int> bytes,
        {String name = 'Living Room'}) =>
    b.writeBytes(slot, bytes, deviceName: name, platform: 'ios');

BackupRelayError _kindOf(Object? e) => (e as BackupRelayException).kind;

void main() {
  runSlotTransportContract('gdrive', () async {
    final server = FakeDriveServer();
    final auth = _FakeAuth(server);
    return (
      CloudSlotTransport(_backend(server, auth, _meta()), 'a1b2c3d4e5f60001'),
      CloudSlotTransport(_backend(server, auth, _meta()), 'a1b2c3d4e5f60002'),
    );
  });

  group('GoogleDriveBackend', () {
    late FakeDriveServer server;
    late _FakeAuth auth;
    late BackupMetaStore meta;
    late GoogleDriveBackend backend;

    setUp(() {
      server = FakeDriveServer();
      auth = _FakeAuth(server);
      meta = _meta();
      backend = _backend(server, auth, meta);
    });

    test('first_write_creates_then_patches', () async {
      await _write(backend, 'a1b2c3d4e5f60001', [1, 2, 3]);
      expect(server.requests,
          ['GET /drive/v3/files', 'POST /upload/drive/v3/files']);
      final id = meta.gdriveOwnFileId;
      expect(id, isNotNull);
      expect(server.files[id]!.appProperties['slotId'], 'a1b2c3d4e5f60001');

      await _write(backend, 'a1b2c3d4e5f60001', [4, 5], name: 'Den');
      expect(server.requests.last, 'PATCH /upload/drive/v3/files/$id');
      expect(server.files, hasLength(1));
      expect(server.files[id]!.bytes, [4, 5]);
      expect(server.files[id]!.appProperties['deviceName'], 'Den');
    });

    test('patch_404_recreates', () async {
      await _write(backend, 'a1b2c3d4e5f60001', [1]);
      final old = meta.gdriveOwnFileId!;
      server.files.remove(old);

      await _write(backend, 'a1b2c3d4e5f60001', [2]);
      expect(meta.gdriveOwnFileId, isNot(old));
      expect(server.files.values.single.bytes, [2]);
      expect(server.requests.sublist(server.requests.length - 3), [
        'PATCH /upload/drive/v3/files/$old',
        'GET /drive/v3/files',
        'POST /upload/drive/v3/files',
      ]);
    });

    test('lost_cached_id_reuses_existing_file', () async {
      await _write(backend, 'a1b2c3d4e5f60001', [1]);
      final id = meta.gdriveOwnFileId!;
      await meta.setGdriveOwnFileId(null);
      server.requests.clear();

      await _write(backend, 'a1b2c3d4e5f60001', [2]);
      expect(server.files, hasLength(1));
      expect(server.files[id]!.bytes, [2]);
      expect(meta.gdriveOwnFileId, id);
      expect(server.requests,
          ['GET /drive/v3/files', 'PATCH /upload/drive/v3/files/$id']);
    });

    test('duplicate_files_keep_newest', () async {
      FakeDriveFile dup(String id, int minute, List<int> bytes) => server
              .files[id] = FakeDriveFile(id, 'slot-a1b2c3d4e5f60001.json.gz', {
            'slotId': 'a1b2c3d4e5f60001',
            'deviceName': 'Den',
          })
            ..bytes = bytes
            ..version = minute
            ..modified = DateTime.utc(2026, 1, 1, 0, minute);
      dup('old', 1, [1]);
      dup('new', 5, [5]);
      dup('mid', 3, [3]);

      final l = (await backend.list())!;
      expect(l.slots, hasLength(1));
      expect(l.slots.single.version, 'new:5');
      expect(await backend.readBytes('a1b2c3d4e5f60001'), [5]);
    });

    test('paged_listing_is_merged', () async {
      server.pageLimit = 2;
      for (var i = 0; i < 5; i++) {
        await _write(_backend(server, auth, _meta()), 'a1b2c3d4e5f6000$i', [i]);
      }
      server.requests.clear();
      final l = (await backend.list())!;
      expect(l.slots.map((s) => s.slotId).toSet(),
          {for (var i = 0; i < 5; i++) 'a1b2c3d4e5f6000$i'});
      expect(server.requests, everyElement('GET /drive/v3/files'));
      expect(server.requests, hasLength(3));
      expect(await backend.list(cursor: l.cursor), isNull);
    });

    test('list_reports_drive_metadata_and_skips_files_without_slot_id',
        () async {
      await _write(backend, 'a1b2c3d4e5f60001', [1, 2, 3], name: 'Den');
      server.files['stray'] = FakeDriveFile('stray', 'stray.gz', {})
        ..version = 9;
      final slot = (await backend.list())!.slots.single;
      expect(slot.slotId, 'a1b2c3d4e5f60001');
      expect(slot.deviceName, 'Den');
      expect(slot.size, 3);
      expect(slot.updatedAtMs, isNotNull);
      expect(
        slot.version,
        '${meta.gdriveOwnFileId}:${server.files[meta.gdriveOwnFileId]!.version}',
      );
    });

    test('read_of_unlisted_slot_lists_first_then_not_found', () async {
      await _write(_backend(server, auth, _meta()), 'a1b2c3d4e5f60002', [7]);
      expect(await backend.readBytes('a1b2c3d4e5f60002'), [7]);
      await expectLater(backend.readBytes('nope'),
          throwsA(predicate((e) => _kindOf(e) == BackupRelayError.notFound)));
    });

    test('read_404_after_vanish_is_not_found', () async {
      await _write(backend, 'a1b2c3d4e5f60001', [1]);
      await backend.list();
      server.files.clear();
      await expectLater(backend.readBytes('a1b2c3d4e5f60001'),
          throwsA(predicate((e) => _kindOf(e) == BackupRelayError.notFound)));
    });

    test('delete_404_is_success', () async {
      await _write(backend, 'a1b2c3d4e5f60001', [1]);
      await backend.list();
      server.files.clear();
      await backend.delete('a1b2c3d4e5f60001');
    });

    test('401_refreshes_once_then_signed_out', () async {
      server.validToken = 'rotated';
      auth.refreshHelps = false;
      await expectLater(backend.list(),
          throwsA(predicate((e) => _kindOf(e) == BackupRelayError.signedOut)));
      expect(auth.refreshes, 1);
    });

    test('401_then_refreshed_token_succeeds', () async {
      server.validToken = 'token-2';
      expect(await backend.list(), isNotNull);
      expect(auth.refreshes, 1);
    });

    test('quota_exceeded_maps_to_quotaFull', () async {
      server.failOnce(
          'POST',
          FakeDriveFailure(403,
              body: jsonEncode({
                'error': {
                  'code': 403,
                  'errors': [
                    {'reason': 'storageQuotaExceeded'}
                  ]
                }
              })));
      await expectLater(_write(backend, 'a1b2c3d4e5f60001', [1]),
          throwsA(predicate((e) => _kindOf(e) == BackupRelayError.quotaFull)));
    });

    test('rate_limit_carries_retry_after', () async {
      server.failOnce(
          'GET',
          FakeDriveFailure(403,
              body: jsonEncode({
                'error': {
                  'errors': [
                    {'reason': 'userRateLimitExceeded'}
                  ]
                }
              }),
              headers: {'retry-after': '7'}));
      await expectLater(
          backend.list(),
          throwsA(predicate((e) =>
              _kindOf(e) == BackupRelayError.rateLimited &&
              (e as BackupRelayException).retryAfterMs == 7000)));
      server.failOnce(
          'GET', FakeDriveFailure(429, headers: {'retry-after': '3'}));
      await expectLater(
          backend.list(),
          throwsA(predicate((e) =>
              _kindOf(e) == BackupRelayError.rateLimited &&
              (e as BackupRelayException).retryAfterMs == 3000)));
    });

    test('insufficient_scope_403_is_signed_out', () async {
      Matcher scopeMissing() => throwsA(predicate((e) =>
          _kindOf(e) == BackupRelayError.signedOut &&
          (e as BackupRelayException).code == googleScopeMissingCode));
      // The v3 shape: a legacy reason in errors[].
      server.failOnce(
          'GET',
          FakeDriveFailure(403,
              body: jsonEncode({
                'error': {
                  'code': 403,
                  'errors': [
                    {'reason': 'insufficientPermissions'}
                  ],
                  'status': 'PERMISSION_DENIED',
                }
              })));
      await expectLater(backend.list(), scopeMissing());
      // The google.rpc shape: the reason in an ErrorInfo detail.
      server.failOnce(
          'GET',
          FakeDriveFailure(403,
              body: jsonEncode({
                'error': {
                  'code': 403,
                  'status': 'PERMISSION_DENIED',
                  'details': [
                    {
                      '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
                      'reason': 'ACCESS_TOKEN_SCOPE_INSUFFICIENT',
                    }
                  ],
                }
              })));
      await expectLater(backend.list(), scopeMissing());
    });

    test('other_403_and_5xx_are_server', () async {
      server.failOnce('GET', FakeDriveFailure(403, body: 'nope'));
      await expectLater(backend.list(),
          throwsA(predicate((e) => _kindOf(e) == BackupRelayError.server)));
      server.failOnce('GET', FakeDriveFailure(503));
      await expectLater(backend.list(),
          throwsA(predicate((e) => _kindOf(e) == BackupRelayError.server)));
    });

    test('socket_and_timeout_are_network', () async {
      server.throwNext = const SocketException('down');
      await expectLater(backend.list(),
          throwsA(predicate((e) => _kindOf(e) == BackupRelayError.network)));
      server.throwNext = TimeoutException('slow');
      await expectLater(backend.list(),
          throwsA(predicate((e) => _kindOf(e) == BackupRelayError.network)));
    });

    test('availability_follows_the_email', () async {
      expect((await backend.availability() as CloudAvailable).accountLabel,
          'ana@example.com');
      auth.email = null;
      expect(await backend.availability(), isA<CloudSignedOut>());
      expect(backend.kind, CloudStoreKind.gdrive);
    });

    test('sign_out_delegates_and_clears_the_own_file_id', () async {
      await _write(backend, 'a1b2c3d4e5f60001', [1]);
      expect(meta.gdriveOwnFileId, isNotNull);
      await backend.signOut();
      expect(auth.signedOut, isTrue);
      expect(meta.gdriveOwnFileId, isNull);
    });

    test('changes_never_emits', () async {
      expect(
          await backend.changes.isEmpty
              .timeout(const Duration(milliseconds: 50), onTimeout: () => true),
          isTrue);
    });

    test('replacing_file_with_same_version_changes_slot_version_and_cursor',
        () async {
      await _write(backend, 'a1b2c3d4e5f60001', [1, 2]);
      final first = (await backend.list())!;
      final oldId = meta.gdriveOwnFileId!;
      final sameVersion = server.files[oldId]!.version;

      server.files.remove(oldId);
      server.files['replacement-id'] = FakeDriveFile(
        'replacement-id',
        'slot_a1b2c3d4e5f60001.json',
        {
          'slotId': 'a1b2c3d4e5f60001',
          'deviceName': 'Replaced',
          'platform': 'ios',
        },
      )
        ..bytes = [3, 4]
        ..version = sameVersion
        ..modified = DateTime.utc(2026, 1, 2);

      final second = await backend.list(cursor: first.cursor);
      expect(second, isNotNull);
      expect(second!.cursor, isNot(first.cursor));
      expect(second.slots.single.version, 'replacement-id:$sameVersion');
      expect(second.slots.single.version, isNot(first.slots.single.version));
    });

    test('delete_removes_all_duplicate_files_and_clears_own_file_id', () async {
      FakeDriveFile makeFile(String id, int minute) => FakeDriveFile(
            id,
            'slot_a1b2c3d4e5f60001.json',
            {
              'slotId': 'a1b2c3d4e5f60001',
              'deviceName': 'Living Room',
              'platform': 'ios',
            },
          )
            ..bytes = [minute]
            ..version = minute
            ..modified = DateTime.utc(2026, 1, 1, 0, minute);
      server.files['dup-1'] = makeFile('dup-1', 1);
      server.files['dup-2'] = makeFile('dup-2', 5);
      await meta.setGdriveOwnFileId('dup-2');

      await backend.delete('a1b2c3d4e5f60001');
      expect(server.files, isEmpty);
      expect(meta.gdriveOwnFileId, isNull);
    });
  });
}
