import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/backup/backup_relay_client.dart';

final _now = DateTime.fromMillisecondsSinceEpoch(1786000000000, isUtc: true);

Future<bool> _verifies(http.Request r, SimpleKeyPair kp) async {
  final auth = r.headers['authorization']!;
  expect(auth, startsWith('MydiaSig '));
  final f = {
    for (final p in auth.substring(9).split(', '))
      p.substring(0, p.indexOf('=')): p.substring(p.indexOf('=') + 1),
  };
  final pub = await kp.extractPublicKey();
  expect(f['signer'], backupB64(pub.bytes));
  final hash = await Sha256().hash(r.bodyBytes);
  final hex = hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final msg = '${r.method}\n${r.url.path}\n$hex\n${f['ts']}';
  return Ed25519().verify(
    utf8.encode(msg),
    signature: Signature(backupUnb64(f['sig']!), publicKey: pub),
  );
}

http.Response _err(int s, String code, {Map<String, String>? h}) =>
    http.Response(jsonEncode({'error': code}), s, headers: h ?? {});

void main() {
  late SimpleKeyPair kp;
  setUp(() async => kp = await Ed25519().newKeyPair());

  BackupRelayClient client(MockClientHandler h) => BackupRelayClient(
    client: MockClient(h),
    baseUrl: 'https://relay.test',
    clock: () => _now,
  );

  Future<void> expectKind(Future<void> f, BackupRelayError k) async {
    await expectLater(
      f,
      throwsA(isA<BackupRelayException>().having((e) => e.kind, 'kind', k)),
    );
  }

  test('signs method, path, body hash and ts for a PUT', () async {
    late http.Request seen;
    final c = client((r) async {
      seen = r;
      return http.Response('{"seq":4}', 200);
    });
    final body = Uint8List.fromList([1, 2, 3]);
    final seq = await c.putSlot('v1', kp, 'abcd', body, ifMatch: 3, epoch: 2);
    expect(seq, 4);
    expect(seen.url.path, '/backup/v1/vaults/v1/slots/abcd');
    expect(seen.headers['x-backup-epoch'], '2');
    expect(seen.headers['if-match'], '3');
    expect(seen.headers['content-type'], 'application/octet-stream');
    expect(await _verifies(seen, kp), isTrue);
  });

  test('first write sends no If-Match; GET signs empty body', () async {
    late http.Request seen;
    final c = client((r) async {
      seen = r;
      return r.method == 'PUT'
          ? http.Response('{"seq":1}', 200)
          : http.Response.bytes([9, 9], 200);
    });
    await c.putSlot('v1', kp, 's', Uint8List(1), ifMatch: null, epoch: 1);
    expect(seen.headers.containsKey('if-match'), isFalse);
    final bytes = await c.getSlot('v1', kp, 's');
    expect(bytes, [9, 9]);
    expect(seen.method, 'GET');
    expect(await _verifies(seen, kp), isTrue);
  });

  test('createVault and lookup are unsigned', () async {
    final seen = <http.Request>[];
    final c = client((r) async {
      seen.add(r);
      return http.Response(
        '{"vault_id":"0123456789abcdef0123456789abcdef"}',
        r.method == 'POST' ? 201 : 200,
      );
    });
    const req = CreateVaultRequest(
      vaultId: '0123456789abcdef0123456789abcdef',
      signer: [1],
      boxPub: [2],
      slotId: 'aa',
      envelope: [3],
      recoverySigner: [4],
      recoveryBoxPub: [5],
      recoverySlotId: 'bb',
      recoveryEnvelope: [6],
      lookupHash: 'cc',
    );
    expect(await c.createVault(req), '0123456789abcdef0123456789abcdef');
    expect(
      await c.lookup(Uint8List.fromList([255, 254])),
      '0123456789abcdef0123456789abcdef',
    );
    expect(seen[0].headers['content-type'], backupJsonContentType);
    expect(
      (jsonDecode(seen[0].body) as Map)['vault_id'],
      '0123456789abcdef0123456789abcdef',
    );
    expect((jsonDecode(seen[0].body) as Map)['recovery_box_pub'], 'BQ');
    // The handle travels in the body, never the URL.
    expect(seen[1].method, 'POST');
    expect(seen[1].url.path, '/backup/v1/lookup');
    expect(seen[1].url.toString(), isNot(contains('__4')));
    expect(seen[1].headers['content-type'], backupJsonContentType);
    expect(jsonDecode(seen[1].body), {'handle': '__4'});
    for (final r in seen) {
      expect(r.headers.containsKey('authorization'), isFalse);
    }
  });

  test('createVault maps a taken vault id (409) to conflict', () async {
    final c = client((r) async => _err(409, 'vault_taken'));
    await expectLater(
      c.createVault(
        const CreateVaultRequest(
          vaultId: '0123456789abcdef0123456789abcdef',
          signer: [1],
          boxPub: [2],
          slotId: 'aa',
          envelope: [3],
          recoverySigner: [4],
          recoveryBoxPub: [5],
          recoverySlotId: 'bb',
          recoveryEnvelope: [6],
          lookupHash: 'cc',
        ),
      ),
      throwsA(
        isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.conflict)
            .having((e) => e.code, 'code', 'vault_taken'),
      ),
    );
  });

  test('manifest parses, passes etag, returns null on 304', () async {
    var n = 0;
    late http.Request seen;
    final c = client((r) async {
      seen = r;
      if (n++ == 1) return http.Response('', 304);
      return http.Response(
        jsonEncode({
          'epoch': 2,
          'members': [
            {
              'signer': 'AQ',
              'box_pub': 'Ag',
              'slot_id': 'aa',
              'recovery': true,
            },
          ],
          'envelope': 'Aw',
          'recovery_signer': 'AQ',
          'slots': [
            {
              'slot_id': 'aa',
              'seq': 3,
              'epoch': 2,
              'size': 10,
              'updated_at': 5,
            },
          ],
        }),
        200,
        headers: {'etag': '"1-3"'},
      );
    });
    final m = (await c.manifest('v', kp))!;
    expect(m.epoch, 2);
    expect(m.etag, '"1-3"');
    expect(m.members.single.recovery, isTrue);
    expect(m.members.single.boxPub, [2]);
    expect(m.slots.single.seq, 3);
    expect(await c.manifest('v', kp, etag: m.etag), isNull);
    expect(seen.headers['if-none-match'], '"1-3"');
    expect(await _verifies(seen, kp), isTrue);
  });

  test('updateMembers body shape and deleteVault 204', () async {
    late http.Request seen;
    final c = client((r) async {
      seen = r;
      return r.method == 'DELETE'
          ? http.Response('', 204)
          : http.Response('{"epoch":2}', 200);
    });
    final epoch = await c.updateMembers(
      'v',
      kp,
      const MemberUpdate(
        expectedEpoch: 1,
        newEpoch: 2,
        add: [
          MemberAdd(signer: [1], boxPub: [2], slotId: 'aa'),
        ],
        remove: [
          [3],
        ],
        envelopes: {
          'AQ': [7],
        },
      ),
    );
    expect(epoch, 2);
    final j = jsonDecode(seen.body) as Map;
    expect(j['expected_epoch'], 1);
    expect(j['new_epoch'], 2);
    expect(j['remove'], ['Aw']);
    expect(j['envelopes'], {'AQ': 'Bw'});
    expect(j['recovery'], isNull);
    expect(await _verifies(seen, kp), isTrue);
    await c.deleteVault('v', kp);
    expect(seen.method, 'DELETE');
    expect(await _verifies(seen, kp), isTrue);
  });

  group('status mapping', () {
    final cases = <String, (http.Response, BackupRelayError)>{
      '403': (_err(403, 'not_member'), BackupRelayError.notMember),
      // A WAF or bot-check page in front of the relay, not a removal:
      // retried with backoff.
      '403 without a code': (http.Response('{}', 403), BackupRelayError.server),
      '403 html': (
        http.Response('<html>Just a moment...</html>', 403),
        BackupRelayError.server,
      ),
      // Not this device's removal: a write to a slot it does not own.
      '403 not_owner': (_err(403, 'not_owner'), BackupRelayError.notOwner),
      '403 other code': (_err(403, 'forbidden'), BackupRelayError.invalid),
      '404 vault': (_err(404, 'vault_not_found'), BackupRelayError.notFound),
      '404 slot': (_err(404, 'not_found'), BackupRelayError.notFound),
      '404 plain': (
        http.Response('Not found', 404),
        BackupRelayError.unavailable,
      ),
      '404 html': (
        http.Response('<html>nope</html>', 404),
        BackupRelayError.unavailable,
      ),
      '409': (_err(409, 'conflict'), BackupRelayError.conflict),
      '409 stale': (_err(409, 'stale_epoch'), BackupRelayError.conflict),
      '412': (
        _err(412, 'precondition_failed'),
        BackupRelayError.preconditionFailed,
      ),
      '413': (_err(413, 'too_large'), BackupRelayError.tooLarge),
      '422': (_err(422, 'invalid'), BackupRelayError.invalid),
      '503': (_err(503, 'storage'), BackupRelayError.server),
      '401': (_err(401, 'bad_signature'), BackupRelayError.unauthorized),
    };
    for (final e in cases.entries) {
      test(e.key, () async {
        final c = client((_) async => e.value.$1);
        await expectKind(c.deleteVault('v', kp), e.value.$2);
      });
    }
  });

  test('429 carries retryAfterMs', () async {
    final c = client(
      (_) async => _err(429, 'rate_limited', h: {'retry-after': '3600'}),
    );
    await expectLater(
      c.deleteVault('v', kp),
      throwsA(
        isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.rateLimited)
            .having((e) => e.retryAfterMs, 'ms', 3600000),
      ),
    );
  });

  test('transport failure is network', () async {
    final c = client((_) async => throw http.ClientException('down'));
    await expectKind(c.deleteVault('v', kp), BackupRelayError.network);
  });

  test('a relay that never answers times out as network', () async {
    final hang = Completer<http.Response>();
    final c = BackupRelayClient(
      client: MockClient((_) => hang.future),
      baseUrl: 'https://relay.test',
      clock: () => _now,
      requestTimeout: const Duration(milliseconds: 20),
      slotTimeout: const Duration(milliseconds: 60),
    );
    await expectKind(c.manifest('v', kp), BackupRelayError.network);

    final slot = Stopwatch()..start();
    await expectKind(c.getSlot('v', kp, 'abcd'), BackupRelayError.network);
    expect(
      slot.elapsedMilliseconds,
      greaterThanOrEqualTo(60),
      reason: 'slot transfers get the longer budget',
    );
  });

  test('the default budgets are 30 s for JSON and 120 s for slots', () {
    final c = BackupRelayClient(
      client: MockClient((_) async => http.Response('', 204)),
    );
    expect(c.requestTimeout, const Duration(seconds: 30));
    expect(c.slotTimeout, const Duration(seconds: 120));
  });

  group('skew', () {
    test('retries once with corrected ts and keeps the offset', () async {
      final serverMs = _now.millisecondsSinceEpoch + 3600 * 1000;
      final tss = <String>[];
      final c = client((r) async {
        final ts = RegExp(r'ts=(\d+)').firstMatch(r.headers['authorization']!)!;
        tss.add(ts.group(1)!);
        if (tss.length == 1) {
          return _err(401, 'skew', h: {'x-backup-server-time': '$serverMs'});
        }
        return http.Response('', 204);
      });
      await c.deleteVault('v', kp);
      expect(tss, ['${_now.millisecondsSinceEpoch}', '$serverMs']);
      expect(c.offsetMs, 3600 * 1000);
      await c.deleteVault('v', kp);
      expect(tss.last, '$serverMs');
    });

    test('a second skew 401 throws unauthorized', () async {
      var calls = 0;
      final c = client((_) async {
        calls++;
        return _err(401, 'skew', h: {'x-backup-server-time': '1'});
      });
      await expectKind(c.deleteVault('v', kp), BackupRelayError.unauthorized);
      expect(calls, 2);
    });

    test('a plain 401 is not retried', () async {
      var calls = 0;
      final c = client((_) async {
        calls++;
        return _err(401, 'bad_signature');
      });
      await expectKind(c.deleteVault('v', kp), BackupRelayError.unauthorized);
      expect(calls, 1);
    });
  });
}
