import 'dart:convert';
import 'dart:typed_data';

import '../auth/auth_storage.dart';

/// Persisted state of the vault this device belongs to.
class BackupVaultState {
  const BackupVaultState({
    required this.vaultId,
    required this.epoch,
    required this.keysByEpoch,
    required this.recoveryKeyText,
    required this.ownSeq,
    this.lastSuccessMs,
    this.manifestEtag,
  });

  final String vaultId;
  final int epoch;
  final Map<int, Uint8List> keysByEpoch;
  final String recoveryKeyText;
  final int ownSeq;
  final int? lastSuccessMs;
  final String? manifestEtag;

  /// Nullable fields take a closure so they can be set to null explicitly.
  BackupVaultState copyWith({
    String? vaultId,
    int? epoch,
    Map<int, Uint8List>? keysByEpoch,
    String? recoveryKeyText,
    int? ownSeq,
    int? Function()? lastSuccessMs,
    String? Function()? manifestEtag,
  }) =>
      BackupVaultState(
        vaultId: vaultId ?? this.vaultId,
        epoch: epoch ?? this.epoch,
        keysByEpoch: keysByEpoch ?? this.keysByEpoch,
        recoveryKeyText: recoveryKeyText ?? this.recoveryKeyText,
        ownSeq: ownSeq ?? this.ownSeq,
        lastSuccessMs:
            lastSuccessMs != null ? lastSuccessMs() : this.lastSuccessMs,
        manifestEtag: manifestEtag != null ? manifestEtag() : this.manifestEtag,
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
      };

  /// Throws [FormatException] on a wrong version or missing/mistyped fields.
  factory BackupVaultState.fromJson(Map<String, dynamic> json) {
    if (json['v'] != 1) {
      throw FormatException('unsupported backup vault state: ${json['v']}');
    }
    final vaultId = json['vaultId'];
    final epoch = json['epoch'];
    final keys = json['keys'];
    final recovery = json['recoveryKey'];
    final ownSeq = json['ownSeq'];
    final lastSuccess = json['lastSuccessMs'];
    final etag = json['manifestEtag'];
    if (vaultId is! String ||
        epoch is! int ||
        keys is! Map ||
        recovery is! String ||
        ownSeq is! int ||
        (lastSuccess != null && lastSuccess is! int) ||
        (etag != null && etag is! String)) {
      throw const FormatException('malformed backup vault state');
    }
    return BackupVaultState(
      vaultId: vaultId,
      epoch: epoch,
      keysByEpoch: {
        for (final e in keys.entries)
          int.parse(e.key as String): Uint8List.fromList(
            base64Url.decode(base64.normalize(e.value as String)),
          ),
      },
      recoveryKeyText: recovery,
      ownSeq: ownSeq,
      lastSuccessMs: lastSuccess as int?,
      manifestEtag: etag as String?,
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
    final decoded = jsonDecode(raw);
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
