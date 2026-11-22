import 'dart:convert';
import 'dart:typed_data';

import '../auth/auth_storage.dart';

/// Persisted state of the vault this device belongs to.
class BackupVaultState {
  BackupVaultState({
    required this.vaultId,
    required this.epoch,
    required Map<int, Uint8List> keysByEpoch,
    required this.recoveryKeyText,
    required this.ownSeq,
    this.lastSuccessMs,
    this.manifestEtag,
    this.pendingRecoveryKeyText,
    this.recoveryKeyUnacknowledged = false,
  }) : keysByEpoch = Map.unmodifiable({
         for (final e in keysByEpoch.entries)
           e.key: Uint8List.fromList(e.value),
       });

  final String vaultId;
  final int epoch;
  final Map<int, Uint8List> keysByEpoch;

  /// Null on a device that joined through pairing: the recovery key never
  /// travels over p2p, and this device has not replaced it since.
  final String? recoveryKeyText;
  final int ownSeq;
  final int? lastSuccessMs;
  final String? manifestEtag;

  /// A recovery key being swapped in: saved before the relay call so a
  /// crash after the relay accepted it cannot lose it. Promoted to
  /// [recoveryKeyText] once the manifest shows its signer, else dropped.
  final String? pendingRecoveryKeyText;

  /// [recoveryKeyText] replaced the old key, and the viewer has not pressed
  /// Done on the sheet showing it: set when a replacement lands (or a
  /// pending one is promoted after a lost reply), cleared only by that
  /// Done.
  final bool recoveryKeyUnacknowledged;

  /// Nullable fields take a closure so they can be set to null explicitly.
  BackupVaultState copyWith({
    String? vaultId,
    int? epoch,
    Map<int, Uint8List>? keysByEpoch,
    String? recoveryKeyText,
    int? ownSeq,
    int? Function()? lastSuccessMs,
    String? Function()? manifestEtag,
    String? Function()? pendingRecoveryKeyText,
    bool? recoveryKeyUnacknowledged,
  }) => BackupVaultState(
    vaultId: vaultId ?? this.vaultId,
    epoch: epoch ?? this.epoch,
    keysByEpoch: keysByEpoch ?? this.keysByEpoch,
    recoveryKeyText: recoveryKeyText ?? this.recoveryKeyText,
    ownSeq: ownSeq ?? this.ownSeq,
    lastSuccessMs: lastSuccessMs != null ? lastSuccessMs() : this.lastSuccessMs,
    manifestEtag: manifestEtag != null ? manifestEtag() : this.manifestEtag,
    pendingRecoveryKeyText: pendingRecoveryKeyText != null
        ? pendingRecoveryKeyText()
        : this.pendingRecoveryKeyText,
    recoveryKeyUnacknowledged:
        recoveryKeyUnacknowledged ?? this.recoveryKeyUnacknowledged,
  );

  /// Keeps only the two highest epochs of [keysByEpoch].
  Map<int, Uint8List> get _prunedKeys {
    final epochs = keysByEpoch.keys.toList()..sort();
    final keep = epochs.length > 2 ? epochs.sublist(epochs.length - 2) : epochs;
    return {for (final e in keep) e: keysByEpoch[e]!};
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'vaultId': vaultId,
    'epoch': epoch,
    'keys': {
      for (final e in _prunedKeys.entries)
        '${e.key}': base64Url.encode(e.value).replaceAll('=', ''),
    },
    'recoveryKey': recoveryKeyText,
    'ownSeq': ownSeq,
    'lastSuccessMs': lastSuccessMs,
    'manifestEtag': manifestEtag,
    if (pendingRecoveryKeyText != null)
      'pendingRecoveryKey': pendingRecoveryKeyText,
    if (recoveryKeyUnacknowledged) 'recoveryKeyUnacknowledged': true,
  };

  /// Throws [FormatException] on a wrong version or missing/mistyped fields.
  factory BackupVaultState.fromJson(Map<String, dynamic> json) {
    if (json['v'] != 1) {
      throw const FormatException('unsupported backup vault state version');
    }
    final vaultId = json['vaultId'];
    final epoch = json['epoch'];
    final keys = json['keys'];
    final recovery = json['recoveryKey'];
    final ownSeq = json['ownSeq'];
    final lastSuccess = json['lastSuccessMs'];
    final etag = json['manifestEtag'];
    final pending = json['pendingRecoveryKey'];
    final unacknowledged = json['recoveryKeyUnacknowledged'] ?? false;
    if (vaultId is! String ||
        unacknowledged is! bool ||
        epoch is! int ||
        keys is! Map ||
        (recovery != null && recovery is! String) ||
        ownSeq is! int ||
        (lastSuccess != null && lastSuccess is! int) ||
        (etag != null && etag is! String) ||
        (pending != null && pending is! String)) {
      throw const FormatException('malformed backup vault state');
    }
    final decoded = <int, Uint8List>{};
    for (final e in keys.entries) {
      final k = e.key;
      final v = e.value;
      final epochKey = k is String ? int.tryParse(k) : null;
      if (epochKey == null || v is! String) {
        throw const FormatException('malformed backup vault keys');
      }
      final bytes = base64Url.decode(base64.normalize(v));
      if (bytes.length != 32) {
        throw const FormatException('vault key must be 32 bytes');
      }
      decoded[epochKey] = Uint8List.fromList(bytes);
    }
    if (!decoded.containsKey(epoch)) {
      throw const FormatException('vault keys lack the current epoch');
    }
    return BackupVaultState(
      vaultId: vaultId,
      epoch: epoch,
      keysByEpoch: decoded,
      recoveryKeyText: recovery as String?,
      ownSeq: ownSeq,
      lastSuccessMs: lastSuccess as int?,
      manifestEtag: etag as String?,
      pendingRecoveryKeyText: pending as String?,
      recoveryKeyUnacknowledged: unacknowledged,
    );
  }
}

/// Reads and writes [BackupVaultState] in [AuthStorage].
class BackupVaultStateStore {
  BackupVaultStateStore(this._storage);

  static const storageKey = 'backup/vault';

  final AuthStorage _storage;

  /// Returns null when nothing is stored. Propagates [FormatException] when
  /// stored data is unreadable (no silent reset).
  Future<BackupVaultState?> load() async {
    final raw = await _storage.read(storageKey);
    if (raw == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Its message quotes the stored JSON, keys included.
      throw const FormatException('malformed backup vault state');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('malformed backup vault state');
    }
    return BackupVaultState.fromJson(decoded);
  }

  /// Throws [StateError] if the write did not reach durable storage.
  Future<void> save(BackupVaultState state) async {
    await _storage.write(storageKey, jsonEncode(state.toJson()));
    if (_storage.degraded) {
      throw StateError('backup state not durable');
    }
  }

  Future<void> clear() => _storage.delete(storageKey);
}
