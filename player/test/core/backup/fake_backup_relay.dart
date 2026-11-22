import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/backup/backup_relay_client.dart';

/// One member of a [FakeVault], keyed by base64url signer.
class FakeMember {
  FakeMember({
    required this.signer,
    required this.boxPub,
    required this.slotId,
    required this.envelope,
  });

  final String signer;
  final String boxPub;
  final String slotId;
  String envelope;
}

class FakeSlot {
  FakeSlot(this.seq, this.epoch, this.body, this.updatedAt);

  int seq;
  int epoch;
  Uint8List body;
  int updatedAt;
}

class FakeVault {
  FakeVault(this.id, this.lookupHash, this.recoverySigner);

  final String id;
  String lookupHash;
  String recoverySigner;
  int epoch = 1;
  int version = 0;
  final members = <String, FakeMember>{};
  final slots = <String, FakeSlot>{};
}

/// The `/backup/v1` API of `metadata-relay/docs/backup.md`, in memory, behind
/// a [MockClient], so tests drive the real [BackupRelayClient]: signatures
/// are verified, `seq` and `epoch` are compare-and-swapped, the recovery
/// signer never owns a slot and removing a member deletes its slot.
class FakeBackupRelay {
  FakeBackupRelay({this.now});

  /// Slot size cap; tests lower it to provoke a 413.
  int maxSlotBytes = 4194304;
  static const baseUrl = 'https://relay.test';

  /// When false the relay has no backup routes: every request is a plain
  /// 404 whose body is not JSON.
  bool available = true;

  /// Clock of slot `updated_at`.
  final int Function()? now;

  final vaults = <String, FakeVault>{};

  /// Successful slot writes, by slot id.
  final slotWrites = <String, int>{};

  /// Every request path, in order, as `METHOD path`.
  final requests = <String>[];

  /// While set, `POST /members` requests wait until this many are waiting,
  /// then run in arrival order. Lets two rotations race on one epoch.
  int? holdMembersUntil;
  final _heldMembers = <Completer<void>>[];

  /// Called before each request is handled; may throw to fail it.
  void Function(http.Request request)? onRequest;

  /// When it returns a response, that is sent instead of handling the
  /// request.
  http.Response? Function(http.Request request)? override;

  /// When set, the next member change is applied and then its response is
  /// lost (the client sees a network error), as in a crash right after the
  /// relay accepted it.
  bool dropNextMembersResponse = false;

  /// Requests it matches get no answer until [releaseHung].
  bool Function(http.Request request)? hangWhen;
  final _hung = Completer<void>();

  void releaseHung() {
    if (!_hung.isCompleted) _hung.complete();
  }

  late final http.Client client = MockClient(_handle);

  BackupRelayClient relayClient() =>
      BackupRelayClient(client: client, baseUrl: baseUrl);

  FakeVault vault(String id) => vaults[id]!;

  FakeVault get onlyVault => vaults.values.single;

  /// Flips one byte of [slotId]'s stored ciphertext.
  void corruptSlot(String vaultId, String slotId) {
    final slot = vaults[vaultId]!.slots[slotId]!;
    final body = Uint8List.fromList(slot.body);
    body[body.length - 1] ^= 0xff;
    slot.body = body;
  }

  Future<http.Response> _handle(http.Request r) async {
    requests.add('${r.method} ${r.url.path}');
    if (hangWhen?.call(r) ?? false) await _hung.future;
    onRequest?.call(r);
    final replaced = override?.call(r);
    if (replaced != null) return replaced;
    if (!available) return http.Response('Not found', 404);
    final path = r.url.path;
    if (!path.startsWith('/backup/v1/')) return http.Response('Not found', 404);
    final parts = path.substring('/backup/v1/'.length).split('/');

    if (r.method == 'POST' && parts.length == 1 && parts[0] == 'vaults') {
      return _create(r);
    }
    if (r.method == 'POST' && parts.length == 1 && parts[0] == 'lookup') {
      final handle = (jsonDecode(r.body) as Map)['handle'];
      if (handle is! String) return _err(422, 'invalid');
      return _lookup(handle);
    }
    if (parts.length < 2 || parts[0] != 'vaults') {
      return http.Response('Not found', 404);
    }
    final vault = vaults[parts[1]];
    final signer = await _authenticate(r);
    if (signer == null) return _err(401, 'bad_signature');
    if (vault == null) return _err(404, 'vault_not_found');
    if (!vault.members.containsKey(signer)) return _err(403, 'not_member');

    if (parts.length == 2) {
      if (r.method == 'GET') return _manifest(r, vault, signer);
      if (r.method == 'DELETE') {
        vaults.remove(vault.id);
        return http.Response('', 204);
      }
    }
    if (parts.length == 3 && parts[2] == 'members' && r.method == 'POST') {
      await _holdMembers();
      final response = _members(r, vault, signer);
      if (dropNextMembersResponse) {
        dropNextMembersResponse = false;
        throw http.ClientException('connection lost');
      }
      return response;
    }
    if (parts.length == 4 && parts[2] == 'slots') {
      if (r.method == 'PUT') return _putSlot(r, vault, signer, parts[3]);
      if (r.method == 'GET') {
        final slot = vault.slots[parts[3]];
        if (slot == null) return _err(404, 'not_found');
        return http.Response.bytes(
          slot.body,
          200,
          headers: {'etag': '"${slot.seq}"'},
        );
      }
    }
    return http.Response('Not found', 404);
  }

  Future<void> _holdMembers() async {
    final n = holdMembersUntil;
    if (n == null) return;
    final gate = Completer<void>();
    _heldMembers.add(gate);
    if (_heldMembers.length >= n) {
      holdMembersUntil = null;
      final release = List.of(_heldMembers);
      _heldMembers.clear();
      for (final g in release) {
        g.complete();
      }
    }
    await gate.future;
  }

  http.Response _create(http.Request r) {
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final id = j['vault_id'];
    if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      return _err(422, 'invalid');
    }
    if (vaults.containsKey(id)) return _err(409, 'vault_taken');
    final lookup = j['lookup_hash'] as String;
    if (vaults.values.any((v) => v.lookupHash == lookup)) {
      return _err(422, 'lookup_taken');
    }
    final v = FakeVault(id, lookup, j['recovery_signer'] as String);
    v.members[j['signer'] as String] = FakeMember(
      signer: j['signer'] as String,
      boxPub: j['box_pub'] as String,
      slotId: j['slot_id'] as String,
      envelope: j['envelope'] as String,
    );
    v.members[v.recoverySigner] = FakeMember(
      signer: v.recoverySigner,
      boxPub: j['recovery_box_pub'] as String,
      slotId: j['recovery_slot_id'] as String,
      envelope: j['recovery_envelope'] as String,
    );
    vaults[id] = v;
    return _json(201, {'vault_id': id});
  }

  Future<http.Response> _lookup(String handleB64) async {
    final hash = await Sha256().hash(backupUnb64(handleB64));
    final hex = _hex(hash.bytes);
    for (final v in vaults.values) {
      if (v.lookupHash == hex) return _json(200, {'vault_id': v.id});
    }
    return _err(404, 'not_found');
  }

  http.Response _manifest(http.Request r, FakeVault v, String signer) {
    final etag = '"${v.epoch}-${v.version}"';
    if (r.headers['if-none-match'] == etag) {
      return http.Response('', 304, headers: {'etag': etag});
    }
    final members = v.members.values.toList()
      ..sort((a, b) => a.slotId.compareTo(b.slotId));
    final slots = v.slots.keys.toList()..sort();
    return _json(
      200,
      {
        'epoch': v.epoch,
        'members': [
          for (final m in members)
            {
              'signer': m.signer,
              'box_pub': m.boxPub,
              'slot_id': m.slotId,
              'recovery': m.signer == v.recoverySigner,
            },
        ],
        'envelope': v.members[signer]!.envelope,
        'recovery_signer': v.recoverySigner,
        'slots': [
          for (final id in slots)
            {
              'slot_id': id,
              'seq': v.slots[id]!.seq,
              'epoch': v.slots[id]!.epoch,
              'size': v.slots[id]!.body.length,
              'updated_at': v.slots[id]!.updatedAt,
            },
        ],
      },
      headers: {'etag': etag},
    );
  }

  http.Response _putSlot(
    http.Request r,
    FakeVault v,
    String signer,
    String slotId,
  ) {
    final m = v.members[signer]!;
    if (m.slotId != slotId || signer == v.recoverySigner) {
      return _err(403, 'not_owner');
    }
    if (r.bodyBytes.length > maxSlotBytes) return _err(413, 'too_large');
    final epoch = int.tryParse(r.headers['x-backup-epoch'] ?? '');
    if (epoch == null) return _err(422, 'invalid');
    if (epoch != v.epoch) return _err(409, 'stale_epoch');
    final ifMatch = int.tryParse(r.headers['if-match'] ?? '');
    final current = v.slots[slotId];
    if ((ifMatch == null && current != null) ||
        (ifMatch != null && current?.seq != ifMatch)) {
      return _err(412, 'precondition_failed');
    }
    final seq = (ifMatch ?? 0) + 1;
    v.slots[slotId] = FakeSlot(
      seq,
      epoch,
      Uint8List.fromList(r.bodyBytes),
      now?.call() ?? DateTime.now().millisecondsSinceEpoch,
    );
    v.version++;
    slotWrites[slotId] = (slotWrites[slotId] ?? 0) + 1;
    return _json(200, {'seq': seq}, headers: {'etag': '"$seq"'});
  }

  http.Response _members(http.Request r, FakeVault v, String signer) {
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final expected = j['expected_epoch'] as int;
    final newEpoch = (j['new_epoch'] as int?) ?? expected;
    if (expected != v.epoch) return _err(409, 'conflict');
    if (newEpoch != expected && newEpoch != expected + 1) {
      return _err(422, 'invalid');
    }
    final rotate = newEpoch == expected + 1;
    final add = [for (final a in (j['add'] as List? ?? [])) a as Map];
    final remove = [for (final s in (j['remove'] as List? ?? [])) s as String];
    final envelopes = (j['envelopes'] as Map? ?? {}).cast<String, String>();
    final recovery = j['recovery'] as Map?;

    if (remove.any((s) => !v.members.containsKey(s))) {
      return _err(422, 'invalid');
    }
    if (remove.contains(v.recoverySigner)) return _err(422, 'invalid');
    if ((remove.isNotEmpty || recovery != null) && !rotate) {
      return _err(422, 'invalid');
    }
    if (recovery != null && recovery['signer'] == v.recoverySigner) {
      return _err(422, 'invalid');
    }
    final survivors = {
      for (final s in v.members.keys)
        if (!remove.contains(s) && !(recovery != null && s == v.recoverySigner))
          s,
    };
    final added = {for (final a in add) a['signer'] as String};
    if (added.any(survivors.contains)) return _err(422, 'invalid');
    final expectedKeys = rotate ? {...survivors, ...added} : added;
    if (!_sameSet(envelopes.keys.toSet(), expectedKeys)) {
      return _err(422, 'invalid');
    }

    v.epoch = newEpoch;
    v.version++;
    for (final s in remove) {
      final m = v.members.remove(s)!;
      v.slots.remove(m.slotId);
    }
    for (final a in add) {
      final s = a['signer'] as String;
      v.members[s] = FakeMember(
        signer: s,
        boxPub: a['box_pub'] as String,
        slotId: a['slot_id'] as String,
        envelope: envelopes[s]!,
      );
    }
    if (rotate) {
      for (final e in envelopes.entries) {
        v.members[e.key]?.envelope = e.value;
      }
    }
    if (recovery != null) {
      v.members.remove(v.recoverySigner);
      final s = recovery['signer'] as String;
      v.recoverySigner = s;
      v.lookupHash = recovery['lookup_hash'] as String;
      v.members[s] = FakeMember(
        signer: s,
        boxPub: recovery['box_pub'] as String,
        slotId: recovery['slot_id'] as String,
        envelope: recovery['envelope'] as String,
      );
    }
    return _json(200, {'epoch': v.epoch});
  }

  /// Returns the base64url signer when the signature verifies.
  Future<String?> _authenticate(http.Request r) async {
    final auth = r.headers['authorization'];
    if (auth == null || !auth.startsWith('MydiaSig ')) return null;
    final f = {
      for (final p in auth.substring(9).split(', '))
        p.substring(0, p.indexOf('=')): p.substring(p.indexOf('=') + 1),
    };
    final signer = f['signer'];
    final ts = f['ts'];
    final sig = f['sig'];
    if (signer == null || ts == null || sig == null) return null;
    final hash = await Sha256().hash(r.bodyBytes);
    final ok = await Ed25519().verify(
      utf8.encode('${r.method}\n${r.url.path}\n${_hex(hash.bytes)}\n$ts'),
      signature: Signature(
        backupUnb64(sig),
        publicKey: SimplePublicKey(
          backupUnb64(signer),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    return ok ? signer : null;
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static String _hex(List<int> bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

  static http.Response _json(
    int status,
    Object body, {
    Map<String, String> headers = const {},
  }) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json', ...headers},
  );

  static http.Response _err(int status, String code) =>
      _json(status, {'error': code});
}
