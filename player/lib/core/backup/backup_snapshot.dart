import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import '../auth/auth_storage.dart';
import '../p2p/peer_group_secret.dart';
import '../p2p/peer_sync_records.dart';
import '../p2p/peer_sync_store.dart';
import '../settings/settings_service.dart';
import '../sources/files/files_account.dart' show kFilesLocalAccountId;
import '../sources/files/index/index_records.dart' show LibraryRoot;
import '../sources/source.dart';
import '../sources/store/source_records.dart';
import '../sources/store/source_secrets.dart';
import 'backup_meta_store.dart';
import 'backup_records.dart';

/// Settings the backup carries, by `SettingsService` storage key. A setting
/// not named here (or a library sort, or [kBackupSubtitleLanguagesKey]) is
/// never collected or restored: device-shaped choices such as the glass
/// material or the stats overlay stay per install.
const kBackupSettingKeys = [
  'default_quality',
  'auto_skip_segments',
  'subtitle_size',
  'theme_preset',
  'interface_locale',
  'update_track',
];

/// Setting key of the subtitle search languages, a JSON list of language
/// codes (`SubtitleLanguagePrefs`).
const kBackupSubtitleLanguagesKey = 'subtitle_search_languages';

/// `AuthStorage` key of the per-install HMAC key fingerprints are made with.
/// Fingerprints cover secrets (share passwords among them) and sit in the
/// plain Hive box `backup_meta`; a keyed HMAC keeps them from being checked
/// against guesses offline.
const kBackupFingerprintKeyStorageKey = 'backup/fingerprint_key';

/// Extra top-level key of a share account's `recordJson`: its folder roots
/// (`LibraryRoot.toMap`). Not part of `SourceAccountRecord`.
const _rootsJsonKey = 'roots';

const _settingPrefix = 'setting:';
const _groupKey = 'group';
const _deletedFingerprint = 'deleted';

/// A secret's storage key relative to the account namespace, in one of the
/// three shapes `SourceSecrets` writes.
final _secretKeyShape = RegExp(
    r'^(account_token|[A-Za-z0-9_-]+/user_token|[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/token)$');

enum BackupApplyMode {
  /// A device already in use: watch and pins merge, accounts are offered.
  live,

  /// A device restoring from the backup: accounts, settings and the group
  /// secret are written too.
  restore,
}

class ApplyResult {
  const ApplyResult({
    required this.watchChanged,
    required this.pinsChanged,
    required this.accountsAdded,
    required this.settingsApplied,
    required this.newOffers,
  });

  final int watchChanged;
  final int pinsChanged;
  final int accountsAdded;
  final int settingsApplied;
  final List<PendingAccountOffer> newOffers;
}

/// Turns this device's stores into backup records and applies merged
/// records back. Free of Riverpod: the provider wires the stores in.
class BackupSnapshot {
  BackupSnapshot({
    required PeerSyncStore peerSync,
    required AuthStorage authStorage,
    required BackupMetaStore meta,
    required Future<SourceSnapshot> Function() loadSources,
    required Future<void> Function(SourceAccountRecord) putAccount,
    required SettingsService settings,
    required Future<List<String>?> Function() loadSubtitleLanguages,
    required Future<void> Function(List<String>) saveSubtitleLanguages,
    required Future<void> Function(Set<String> watchKeys, Set<String> pinKeys)
        onRemoteFilesChanges,
    required Future<List<LibraryRoot>> Function(String accountId) rootsFor,
    required Future<void> Function(String accountId, List<LibraryRoot> roots)
        putRoots,
  })  : _rootsFor = rootsFor,
        _putRoots = putRoots,
        _peerSync = peerSync,
        _auth = authStorage,
        _meta = meta,
        _loadSources = loadSources,
        _putAccount = putAccount,
        _settings = settings,
        _loadSubtitleLanguages = loadSubtitleLanguages,
        _saveSubtitleLanguages = saveSubtitleLanguages,
        _onRemoteFilesChanges = onRemoteFilesChanges;

  final PeerSyncStore _peerSync;
  final AuthStorage _auth;
  final BackupMetaStore _meta;
  final Future<SourceSnapshot> Function() _loadSources;
  final Future<void> Function(SourceAccountRecord) _putAccount;
  final SettingsService _settings;
  final Future<List<String>?> Function() _loadSubtitleLanguages;
  final Future<void> Function(List<String>) _saveSubtitleLanguages;
  final Future<void> Function(Set<String>, Set<String>) _onRemoteFilesChanges;
  final Future<List<LibraryRoot>> Function(String) _rootsFor;
  final Future<void> Function(String, List<LibraryRoot>) _putRoots;

  Future<Hmac>? _hmac;

  /// HMAC-SHA256 hex of [value]'s canonical JSON (keys sorted at every
  /// level) under the per-install key, created on first use.
  Future<String> _fingerprint(Map<String, dynamic> value) async {
    final Hmac hmac;
    try {
      hmac = await (_hmac ??= _loadHmac());
    } catch (_) {
      // Not cached: the next call tries storage again.
      _hmac = null;
      rethrow;
    }
    return hmac.convert(utf8.encode(jsonEncode(_sorted(value)))).toString();
  }

  Future<Hmac> _loadHmac() async {
    var encoded = await _auth.read(kBackupFingerprintKeyStorageKey);
    if (encoded == null) {
      final random = Random.secure();
      encoded = base64Url.encode([
        for (var i = 0; i < 32; i++) random.nextInt(256)
      ]).replaceAll('=', '');
      await _auth.write(kBackupFingerprintKeyStorageKey, encoded);
    }
    return Hmac(sha256, base64Url.decode(base64.normalize(encoded)));
  }

  // Collect

  Future<List<BackupRecord>> collect({required int nowMs}) async => [
        ..._collectWatch(),
        ..._collectPins(),
        ...await _collectAccounts(nowMs),
        ...await _collectSettings(nowMs),
        ...await _collectGroup(nowMs),
      ];

  Iterable<BackupRecord> _collectWatch() => [
        for (final MapEntry(:key, :value)
            in _peerSync.allWatchRecords().entries)
          WatchBackupRecord(
            key: key,
            watched: value.watched,
            positionSeconds: value.positionSeconds,
            durationSeconds: value.durationSeconds,
            updatedAt: value.updatedAt,
          ),
      ];

  Iterable<BackupRecord> _collectPins() => [
        for (final MapEntry(:key, :value) in _peerSync.allPinRecords().entries)
          PinBackupRecord(
            key: key,
            groupKey: value.groupKey,
            isShow: value.isShow,
            tmdbId: value.tmdbId,
            pinned: value.pinned,
            updatedAt: value.updatedAt,
          ),
      ];

  Future<List<BackupRecord>> _collectAccounts(int nowMs) async {
    final out = <BackupRecord>[];
    final present = <String>{};
    for (final record in (await _loadSources()).accounts) {
      if (!_backedUp(record.account)) continue;
      final id = record.account.id;
      present.add(id);
      final json = _sanitizedRecordJson(record);
      if (record.account.kind == SourceKind.files) {
        json[_rootsJsonKey] = _rootsJson(await _rootsFor(id));
      }
      final secrets = record.account.kind == SourceKind.mydia
          ? const <String, String>{}
          : await _readSecrets(record);
      final key = '${AccountBackupRecord.keyPrefix}$id';
      out.add(AccountBackupRecord(
        key: key,
        recordJson: json,
        secrets: secrets,
        updatedAt: await _meta.stamp(
            key,
            await _fingerprint({'recordJson': json, 'secrets': secrets}),
            nowMs),
      ));
    }
    for (final key in _meta.stampedKeys(AccountBackupRecord.keyPrefix)) {
      if (present
          .contains(key.substring(AccountBackupRecord.keyPrefix.length))) {
        continue;
      }
      out.add(AccountBackupRecord(
        key: key,
        recordJson: const {},
        secrets: const {},
        updatedAt: await _meta.stamp(key, _deletedFingerprint, nowMs),
        deleted: true,
      ));
    }
    return out;
  }

  /// Roots in id order, so the fingerprint does not depend on index order.
  static List<Map<String, dynamic>> _rootsJson(List<LibraryRoot> roots) => [
        for (final r in roots) r.toMap()
      ]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));

  /// The local folders account names paths on this device only.
  static bool _backedUp(ProviderAccount a) =>
      !(a.kind == SourceKind.files && a.id == kFilesLocalAccountId);

  /// The record as stored, without lock modes (a restore must never unlock
  /// anything) and, for Mydia, flagged to sign in again: its credentials
  /// are never backed up.
  static Map<String, dynamic> _sanitizedRecordJson(SourceAccountRecord r) {
    final json = r.copyWith(serverLocks: const {}).toJson()
      ..remove('serverLocks');
    if (r.account.kind == SourceKind.mydia) {
      json['account'] = r.account.copyWith(needsReauth: true).toJson();
    }
    return json;
  }

  /// Every token the account owns, by key relative to its namespace: the
  /// account token, each profile's user token, and each profile x server
  /// token, the same keys `SourceSecrets.deleteAll` covers.
  Future<Map<String, String>> _readSecrets(SourceAccountRecord r) async {
    final serverIds = {...r.chosenServers, for (final s in r.servers) s.id};
    final keys = <String>{
      'account_token',
      for (final p in r.profiles) '${p.id}/user_token',
      for (final p in r.profiles)
        for (final s in serverIds) '${p.id}/$s/token',
      for (final s in r.servers) '${s.profileId}/${s.id}/token',
    };
    final secrets = <String, String>{};
    for (final k in keys) {
      final v = await _auth.read('${r.account.storageNamespace}/$k');
      if (v != null) secrets[k] = v;
    }
    return secrets;
  }

  Future<List<BackupRecord>> _collectSettings(int nowMs) async {
    final values = <String, String?>{
      for (final k in [
        ...kBackupSettingKeys,
        ...await _settings.librarySortStorageKeys(),
      ])
        k: await _settings.readStoredValue(k),
    };
    final languages = await _loadSubtitleLanguages();
    values[kBackupSubtitleLanguagesKey] =
        languages == null ? null : jsonEncode(languages);

    final out = <BackupRecord>[];
    for (final MapEntry(:key, :value) in values.entries) {
      final recordKey = '$_settingPrefix$key';
      // A setting never set is skipped; one cleared after it was backed up
      // is carried as null, so the clear wins over older copies.
      if (value == null && !_meta.hasStamp(recordKey)) continue;
      out.add(SettingBackupRecord(
        key: recordKey,
        settingKey: key,
        value: value,
        updatedAt: await _meta.stamp(
            recordKey, await _fingerprint({'value': value}), nowMs),
      ));
    }
    return out;
  }

  Future<List<BackupRecord>> _collectGroup(int nowMs) async {
    final secret = await _auth.read(PeerGroupSecret.storageKey);
    if (secret == null) return const [];
    final nodes = _meta.nodeToSlot();
    return [
      GroupBackupRecord(
        key: _groupKey,
        groupSecretB64: secret,
        nodeToSlot: nodes,
        updatedAt: await _meta.stamp(_groupKey,
            await _fingerprint({'secret': secret, 'nodeToSlot': nodes}), nowMs),
      ),
    ];
  }

  // Apply

  Future<ApplyResult> apply(
    List<BackupRecord> merged, {
    required BackupApplyMode mode,
    required String fromDevice,
    required int nowMs,
  }) async {
    final changes = await _peerSync.mergeRemote(
      watchRecords: [
        for (final r in merged.whereType<WatchBackupRecord>())
          if (!r.deleted)
            WireWatchRecord(
              key: r.key,
              watched: r.watched,
              positionSeconds: r.positionSeconds == null
                  ? null
                  : PlatformInt64Util.from(r.positionSeconds!),
              durationSeconds: r.durationSeconds == null
                  ? null
                  : PlatformInt64Util.from(r.durationSeconds!),
              updatedAtMs: PlatformInt64Util.from(r.updatedAt),
            ),
      ],
      pinRecords: [
        for (final r in merged.whereType<PinBackupRecord>())
          if (!r.deleted)
            WirePinRecord(
              key: pinSyncKey(isShow: r.isShow, groupKey: r.groupKey),
              groupKey: r.groupKey,
              isShow: r.isShow,
              tmdbId:
                  r.tmdbId == null ? null : PlatformInt64Util.from(r.tmdbId!),
              pinned: r.pinned,
              updatedAtMs: PlatformInt64Util.from(r.updatedAt),
            ),
      ],
      nowMs: nowMs,
    );
    if (changes.changedWatchKeys.isNotEmpty ||
        changes.changedPinKeys.isNotEmpty) {
      await _onRemoteFilesChanges(
          changes.changedWatchKeys, changes.changedPinKeys);
    }

    var accountsAdded = 0;
    final newOffers = <PendingAccountOffer>[];
    final local = {
      for (final a in (await _loadSources()).accounts) a.account.id,
    };
    // Tombstones are never applied: removing an account stays local.
    for (final r in merged.whereType<AccountBackupRecord>()) {
      if (r.deleted) continue;
      if (local.contains(r.accountId)) {
        if (_meta.pendingAccount(r.accountId) != null) {
          await _meta.removePending(r.accountId);
        }
        continue;
      }
      if (mode == BackupApplyMode.restore) {
        if (await addAccount(r)) {
          accountsAdded++;
          local.add(r.accountId);
        }
      } else {
        final offer = _offerFor(r, fromDevice);
        if (offer == null || _meta.isDismissed(r.accountId, r.updatedAt)) {
          continue;
        }
        if (_meta.pendingAccount(r.accountId)?.updatedAt == r.updatedAt) {
          continue;
        }
        await _meta.putPending(offer);
        newOffers.add(offer);
      }
    }

    var settingsApplied = 0;
    if (mode == BackupApplyMode.restore) {
      for (final r in merged.whereType<SettingBackupRecord>()) {
        if (await _applySetting(r)) settingsApplied++;
      }
      final group = merged.whereType<GroupBackupRecord>().firstOrNull;
      if (group != null && !group.deleted) await _applyGroup(group);
    }

    return ApplyResult(
      watchChanged: changes.changedWatchKeys.length,
      pinsChanged: changes.changedPinKeys.length,
      accountsAdded: accountsAdded,
      settingsApplied: settingsApplied,
      newOffers: newOffers,
    );
  }

  static PendingAccountOffer? _offerFor(AccountBackupRecord r, String from) {
    try {
      final account = ProviderAccount.fromJson(
          (r.recordJson['account'] as Map).cast<String, dynamic>());
      if (account.id != r.accountId) return null;
      return PendingAccountOffer(
        accountId: r.accountId,
        kind: account.kind.name,
        displayName: account.displayName,
        fromDevice: from,
        updatedAt: r.updatedAt,
      );
    } catch (e) {
      debugPrint('[Backup] Unreadable account record ${r.accountId}: '
          '${e.runtimeType}');
      return null;
    }
  }

  /// Writes [r]'s secrets, then its record with no locks, then a share
  /// account's folder roots. Returns false and writes nothing when the
  /// record is malformed. A Mydia account gets no secrets and is flagged to
  /// sign in again. Used by a restore and to accept a pending offer.
  Future<bool> addAccount(AccountBackupRecord r) async {
    final SourceAccountRecord parsed;
    final List<LibraryRoot> roots;
    try {
      final json = Map<String, dynamic>.of(r.recordJson);
      final rawRoots = json.remove(_rootsJsonKey) as List?;
      parsed = SourceAccountRecord.fromJson(json);
      roots = parsed.account.kind == SourceKind.files
          ? [
              for (final m in rawRoots ?? const [])
                LibraryRoot.fromMap(m as Map),
            ]
          : const [];
    } catch (e) {
      debugPrint('[Backup] Unreadable account record ${r.accountId}: '
          '${e.runtimeType}');
      return false;
    }
    final account = parsed.account;
    if (account.id != r.accountId ||
        account.storageNamespace !=
            SourceSecrets.newStorageNamespace(account.id)) {
      debugPrint('[Backup] Account record ${r.accountId} names another id');
      return false;
    }
    final mydia = account.kind == SourceKind.mydia;
    final record = parsed.copyWith(
      serverLocks: const {},
      account: mydia ? account.copyWith(needsReauth: true) : null,
    );
    final secrets = <String, String>{
      if (!mydia)
        for (final MapEntry(:key, :value) in r.secrets.entries)
          if (_secretKeyShape.hasMatch(key)) key: value,
    };
    // Tokens before the record, as the sources layer writes them.
    for (final MapEntry(:key, :value) in secrets.entries) {
      await _auth.write('${account.storageNamespace}/$key', value);
    }
    await _putAccount(record);
    if (roots.isNotEmpty) await _putRoots(account.id, roots);
    await _meta.removePending(account.id);
    final stamped = _sanitizedRecordJson(record);
    if (account.kind == SourceKind.files) {
      stamped[_rootsJsonKey] = _rootsJson(roots);
    }
    await _meta.setStamp(
        r.key,
        await _fingerprint({'recordJson': stamped, 'secrets': secrets}),
        r.updatedAt);
    return true;
  }

  static bool _allowedSetting(String key) =>
      kBackupSettingKeys.contains(key) ||
      key == kBackupSubtitleLanguagesKey ||
      SettingsService.isLibrarySortKey(key);

  Future<bool> _applySetting(SettingBackupRecord r) async {
    final key = r.settingKey;
    if (r.deleted || !_allowedSetting(key) || r.key != '$_settingPrefix$key') {
      return false;
    }
    final value = r.value;
    try {
      if (key == kBackupSubtitleLanguagesKey) {
        if (value == null) return false;
        final languages = List<String>.from(jsonDecode(value) as List);
        if (languages.isEmpty) return false;
        await _saveSubtitleLanguages(languages);
      } else {
        await _settings.writeStoredValue(key, value);
      }
    } catch (e) {
      debugPrint('[Backup] Could not restore setting $key: ${e.runtimeType}');
      return false;
    }
    await _meta.setStamp(
        r.key, await _fingerprint({'value': value}), r.updatedAt);
    return true;
  }

  Future<void> _applyGroup(GroupBackupRecord r) async {
    if (await _auth.read(PeerGroupSecret.storageKey) != null) return;
    try {
      PeerGroupSecret.fromBase64Url(r.groupSecretB64);
    } catch (_) {
      debugPrint('[Backup] Group secret in the backup is malformed');
      return;
    }
    // The node map is not taken from here: the merged record has lost which
    // slot sent it, and a node is believed only from its own slot (see
    // `BackupSyncService._apply`).
    await _auth.write(PeerGroupSecret.storageKey, r.groupSecretB64);
  }
}

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k as String).toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return [for (final e in v) _sorted(e)];
  return v;
}
