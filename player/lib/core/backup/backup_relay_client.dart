import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../relay/relay_api_client.dart' show metadataRelayBaseUrl;

/// Content type of JSON requests. Not `+json`: the relay's JSON parser would
/// consume the body before the signature over its exact bytes can be checked.
const String backupJsonContentType = 'application/vnd.mydia.backup';

/// Base64url without padding, the wire encoding of every binary JSON value.
String backupB64(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url, with or without padding.
Uint8List backupUnb64(String s) {
  final padded = s.padRight((s.length + 3) ~/ 4 * 4, '=');
  return Uint8List.fromList(base64Url.decode(padded));
}

enum BackupRelayError {
  /// The relay has no `/backup/v1` routes (404 whose body is not relay JSON).
  unavailable,
  notFound,
  notMember,
  conflict,
  preconditionFailed,
  tooLarge,
  rateLimited,
  invalid,
  unauthorized,
  network,
  server,
}

class BackupRelayException implements Exception {
  const BackupRelayException(this.kind, {this.retryAfterMs, this.code});

  final BackupRelayError kind;
  final int? retryAfterMs;

  /// The relay's `error` string when it sent one, e.g. `lookup_taken`.
  final String? code;

  @override
  String toString() => 'BackupRelayException($kind, code: $code)';
}

class CreateVaultRequest {
  const CreateVaultRequest({
    required this.vaultId,
    required this.signer,
    required this.boxPub,
    required this.slotId,
    required this.envelope,
    required this.recoverySigner,
    required this.recoveryBoxPub,
    required this.recoverySlotId,
    required this.recoveryEnvelope,
    required this.lookupHash,
  });

  /// 32 lowercase hex chars, chosen by the client before sealing so every
  /// envelope binds it. A taken id is a [BackupRelayError.conflict].
  final String vaultId;
  final List<int> signer;
  final List<int> boxPub;
  final String slotId;
  final List<int> envelope;
  final List<int> recoverySigner;
  final List<int> recoveryBoxPub;
  final String recoverySlotId;
  final List<int> recoveryEnvelope;

  /// 64 hex chars, sha256 of the lookup handle.
  final String lookupHash;

  Map<String, dynamic> toJson() => {
        'vault_id': vaultId,
        'signer': backupB64(signer),
        'slot_id': slotId,
        'envelope': backupB64(envelope),
        'box_pub': backupB64(boxPub),
        'recovery_signer': backupB64(recoverySigner),
        'recovery_slot_id': recoverySlotId,
        'recovery_envelope': backupB64(recoveryEnvelope),
        'recovery_box_pub': backupB64(recoveryBoxPub),
        'lookup_hash': lookupHash,
      };
}

class ManifestMember {
  const ManifestMember({
    required this.signer,
    required this.boxPub,
    required this.slotId,
    required this.recovery,
  });

  factory ManifestMember.fromJson(Map<String, dynamic> j) => ManifestMember(
        signer: backupUnb64(j['signer'] as String),
        boxPub: backupUnb64(j['box_pub'] as String),
        slotId: j['slot_id'] as String,
        recovery: j['recovery'] == true,
      );

  final Uint8List signer;
  final Uint8List boxPub;
  final String slotId;
  final bool recovery;
}

class ManifestSlot {
  const ManifestSlot({
    required this.slotId,
    required this.seq,
    required this.epoch,
    required this.size,
    required this.updatedAt,
  });

  factory ManifestSlot.fromJson(Map<String, dynamic> j) => ManifestSlot(
        slotId: j['slot_id'] as String,
        seq: j['seq'] as int,
        epoch: j['epoch'] as int,
        size: j['size'] as int,
        updatedAt: j['updated_at'] as int,
      );

  final String slotId;
  final int seq;
  final int epoch;
  final int size;

  /// Unix milliseconds.
  final int updatedAt;
}

class BackupManifest {
  const BackupManifest({
    required this.epoch,
    required this.members,
    required this.envelope,
    required this.recoverySigner,
    required this.slots,
    this.etag,
  });

  factory BackupManifest.fromJson(Map<String, dynamic> j, {String? etag}) =>
      BackupManifest(
        epoch: j['epoch'] as int,
        members: [
          for (final m in j['members'] as List)
            ManifestMember.fromJson(m as Map<String, dynamic>),
        ],
        envelope: backupUnb64(j['envelope'] as String),
        recoverySigner: backupUnb64(j['recovery_signer'] as String),
        slots: [
          for (final s in j['slots'] as List)
            ManifestSlot.fromJson(s as Map<String, dynamic>),
        ],
        etag: etag,
      );

  final int epoch;
  final List<ManifestMember> members;

  /// The requester's own envelope.
  final Uint8List envelope;
  final Uint8List recoverySigner;
  final List<ManifestSlot> slots;

  /// Opaque; pass back as `etag:` to get null when nothing changed.
  final String? etag;
}

class MemberAdd {
  const MemberAdd({
    required this.signer,
    required this.boxPub,
    required this.slotId,
  });

  final List<int> signer;
  final List<int> boxPub;
  final String slotId;

  Map<String, dynamic> toJson() => {
        'signer': backupB64(signer),
        'slot_id': slotId,
        'box_pub': backupB64(boxPub),
      };
}

class RecoveryReplacement {
  const RecoveryReplacement({
    required this.signer,
    required this.boxPub,
    required this.slotId,
    required this.envelope,
    required this.lookupHash,
  });

  final List<int> signer;
  final List<int> boxPub;
  final String slotId;
  final List<int> envelope;
  final String lookupHash;

  Map<String, dynamic> toJson() => {
        'signer': backupB64(signer),
        'slot_id': slotId,
        'envelope': backupB64(envelope),
        'box_pub': backupB64(boxPub),
        'lookup_hash': lookupHash,
      };
}

class MemberUpdate {
  const MemberUpdate({
    required this.expectedEpoch,
    required this.newEpoch,
    this.add = const [],
    this.remove = const [],
    this.envelopes = const {},
    this.recovery,
  });

  final int expectedEpoch;

  /// Equal to [expectedEpoch] (no rotation) or `expectedEpoch + 1`.
  final int newEpoch;
  final List<MemberAdd> add;
  final List<List<int>> remove;

  /// Keyed by base64url signer (see [backupB64]).
  final Map<String, List<int>> envelopes;
  final RecoveryReplacement? recovery;

  Map<String, dynamic> toJson() => {
        'expected_epoch': expectedEpoch,
        'new_epoch': newEpoch,
        'add': [for (final a in add) a.toJson()],
        'remove': [for (final r in remove) backupB64(r)],
        'envelopes': {
          for (final e in envelopes.entries) e.key: backupB64(e.value),
        },
        'recovery': recovery?.toJson(),
      };
}

/// Signed client for metadata-relay's `/backup/v1` API. Wire format:
/// `metadata-relay/docs/backup.md`.
class BackupRelayClient {
  BackupRelayClient({
    http.Client? client,
    String baseUrl = metadataRelayBaseUrl,
    DateTime Function()? clock,
    this.requestTimeout = const Duration(seconds: 30),
    this.slotTimeout = const Duration(seconds: 120),
  })  : _client = client ?? http.Client(),
        _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _clock = clock ?? DateTime.now;

  static const _api = '/backup/v1';

  /// How long a JSON call may take before it fails as
  /// [BackupRelayError.network].
  final Duration requestTimeout;

  /// The same for a slot upload or download, which can carry 4 MB.
  final Duration slotTimeout;

  final http.Client _client;
  final String _baseUrl;
  final DateTime Function() _clock;
  int _offsetMs = 0;

  /// Clock correction learned from a skew 401.
  int get offsetMs => _offsetMs;

  /// Returns the vault id (the one [request] carries). Throws
  /// [BackupRelayError.conflict] when that id is taken.
  Future<String> createVault(CreateVaultRequest request) async {
    final r = await _send(
      'POST',
      '$_api/vaults',
      body: utf8.encode(jsonEncode(request.toJson())),
      contentType: backupJsonContentType,
    );
    return _json(r)['vault_id'] as String;
  }

  Future<String> lookup(Uint8List handle) async {
    final r = await _send('GET', '$_api/lookup/${backupB64(handle)}');
    return _json(r)['vault_id'] as String;
  }

  /// Null when [etag] still matches (304).
  Future<BackupManifest?> manifest(
    String vaultId,
    SimpleKeyPair signer, {
    String? etag,
  }) async {
    final r = await _send(
      'GET',
      '$_api/vaults/$vaultId',
      signer: signer,
      headers: {if (etag != null) 'if-none-match': etag},
      accept304: true,
    );
    if (r.statusCode == 304) return null;
    return BackupManifest.fromJson(_json(r), etag: r.headers['etag']);
  }

  /// Returns the new seq. [ifMatch] is the seq last seen, null for a first
  /// write.
  Future<int> putSlot(
    String vaultId,
    SimpleKeyPair signer,
    String slotId,
    Uint8List body, {
    required int? ifMatch,
    required int epoch,
  }) async {
    final r = await _send(
      'PUT',
      '$_api/vaults/$vaultId/slots/$slotId',
      signer: signer,
      body: body,
      contentType: 'application/octet-stream',
      headers: {
        'x-backup-epoch': '$epoch',
        if (ifMatch != null) 'if-match': '$ifMatch',
      },
      slot: true,
    );
    return _json(r)['seq'] as int;
  }

  Future<Uint8List> getSlot(
    String vaultId,
    SimpleKeyPair signer,
    String slotId,
  ) async {
    final r = await _send(
      'GET',
      '$_api/vaults/$vaultId/slots/$slotId',
      signer: signer,
      slot: true,
    );
    return r.bodyBytes;
  }

  Future<int> updateMembers(
    String vaultId,
    SimpleKeyPair signer,
    MemberUpdate update,
  ) async {
    final r = await _send(
      'POST',
      '$_api/vaults/$vaultId/members',
      signer: signer,
      body: utf8.encode(jsonEncode(update.toJson())),
      contentType: backupJsonContentType,
    );
    return _json(r)['epoch'] as int;
  }

  Future<void> deleteVault(String vaultId, SimpleKeyPair signer) async {
    await _send('DELETE', '$_api/vaults/$vaultId', signer: signer);
  }

  Map<String, dynamic> _json(http.Response r) {
    try {
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } on Object {
      throw const BackupRelayException(BackupRelayError.server);
    }
  }

  Future<String> _authorization(
    SimpleKeyPair signer,
    String method,
    String path,
    List<int> body,
  ) async {
    final ts = (_clock().millisecondsSinceEpoch + _offsetMs).toString();
    final hash = await Sha256().hash(body);
    final hex = [
      for (final b in hash.bytes) b.toRadixString(16).padLeft(2, '0'),
    ].join();
    final sig = await Ed25519().sign(
      utf8.encode('$method\n$path\n$hex\n$ts'),
      keyPair: signer,
    );
    final pub = await signer.extractPublicKey();
    return 'MydiaSig signer=${backupB64(pub.bytes)}, ts=$ts, '
        'sig=${backupB64(sig.bytes)}';
  }

  Future<http.Response> _send(
    String method,
    String path, {
    SimpleKeyPair? signer,
    List<int> body = const [],
    String? contentType,
    Map<String, String> headers = const {},
    bool accept304 = false,
    bool slot = false,
  }) async {
    for (var attempt = 0;; attempt++) {
      final request = http.Request(method, Uri.parse('$_baseUrl$path'));
      request.headers.addAll(headers);
      if (contentType != null) request.headers['content-type'] = contentType;
      if (body.isNotEmpty) request.bodyBytes = Uint8List.fromList(body);
      if (signer != null) {
        request.headers['authorization'] =
            await _authorization(signer, method, request.url.path, body);
      }

      final http.Response response;
      try {
        // A relay that never answers is a network failure, not a hang.
        response = await _client
            .send(request)
            .then(http.Response.fromStream)
            .timeout(slot ? slotTimeout : requestTimeout);
      } on Object {
        throw const BackupRelayException(BackupRelayError.network);
      }

      final status = response.statusCode;
      if (status >= 200 && status < 300) return response;
      if (status == 304 && accept304) return response;

      final serverTime = int.tryParse(
        response.headers['x-backup-server-time'] ?? '',
      );
      if (status == 401 &&
          serverTime != null &&
          attempt == 0 &&
          signer != null) {
        _offsetMs = serverTime - _clock().millisecondsSinceEpoch;
        continue;
      }
      throw _errorFor(response);
    }
  }

  BackupRelayException _errorFor(http.Response r) {
    String? code;
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map && j['error'] is String) code = j['error'] as String;
    } on Object {
      code = null;
    }
    BackupRelayException e(BackupRelayError k, {int? retryAfterMs}) =>
        BackupRelayException(k, retryAfterMs: retryAfterMs, code: code);

    switch (r.statusCode) {
      case 401:
        return e(BackupRelayError.unauthorized);
      case 403:
        return e(BackupRelayError.notMember);
      case 404:
        return code == null
            ? e(BackupRelayError.unavailable)
            : e(BackupRelayError.notFound);
      case 409:
        return e(BackupRelayError.conflict);
      case 412:
        return e(BackupRelayError.preconditionFailed);
      case 413:
        return e(BackupRelayError.tooLarge);
      case 422:
        return e(BackupRelayError.invalid);
      case 429:
        final secs = int.tryParse(r.headers['retry-after'] ?? '');
        return e(
          BackupRelayError.rateLimited,
          retryAfterMs: secs == null ? null : secs * 1000,
        );
      default:
        return e(BackupRelayError.server);
    }
  }
}
