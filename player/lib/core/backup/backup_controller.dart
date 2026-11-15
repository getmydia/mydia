import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../auth/auth_storage.dart';
import '../p2p/peer_sync_service.dart' show BackupPairingHooks;
import 'backup_identity.dart';
import 'backup_meta_store.dart';
import 'backup_snapshot.dart';
import 'backup_sync_service.dart';
import 'backup_vault_state.dart';
import 'cloud/cloud_backend.dart';
import 'cloud/cloud_backup_service.dart';
import 'cloud/google_auth.dart';
import 'recovery_key.dart';
import 'slot_sync_engine.dart';

/// Where this device's backup lives. [name] is the store id written in a
/// moved stub and in `backup/store`.
enum BackupStoreKind {
  relay,
  icloud,
  gdrive;

  /// The cloud store this is, null for the relay.
  CloudStoreKind? get cloudKind => switch (this) {
        BackupStoreKind.relay => null,
        BackupStoreKind.icloud => CloudStoreKind.icloud,
        BackupStoreKind.gdrive => CloudStoreKind.gdrive,
      };

  static BackupStoreKind? parse(String? id) =>
      BackupStoreKind.values.where((k) => k.name == id).firstOrNull;
}

/// What pairing said about the group's backup: it lives in the cloud store
/// [kind], signed in as [account] (the Google email; null for iCloud).
@immutable
class CloudStoreHint {
  const CloudStoreHint(this.kind, this.account);

  final BackupStoreKind kind;
  final String? account;

  Map<String, dynamic> toJson() => {'store': kind.name, 'account': account};

  static CloudStoreHint? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = BackupStoreKind.parse(json['store'] as String?);
    final account = json['account'];
    if (kind == null || kind == BackupStoreKind.relay) return null;
    return CloudStoreHint(kind, account is String ? account : null);
  }

  @override
  bool operator ==(Object other) =>
      other is CloudStoreHint && other.kind == kind && other.account == account;

  @override
  int get hashCode => Object.hash(kind, account);

  @override
  String toString() => 'CloudStoreHint(${kind.name}, $account)';
}

/// The store [BackupController.switchTo] leaves: stop its background sync,
/// undo that, and leave it with a moved stub.
typedef _OldStore = ({
  Future<void> Function() pause,
  void Function() resume,
  Future<void> Function() leave,
});

/// Builds the [CloudBackupService] of a cloud store kind.
typedef CloudServiceBuilder = Future<CloudBackupService> Function(
    BackupStoreKind kind);

/// The stores this device offers: the relay on every native platform,
/// Google Drive where [google] (a [GoogleAuth] exists for the platform),
/// iCloud on iOS and macOS ([apple]) when this build carries it
/// ([cloudKitEnabled]); nothing on the web.
Future<Set<BackupStoreKind>> resolveOfferedStores({
  required bool web,
  required bool apple,
  required bool google,
  required Future<bool> Function() cloudKitEnabled,
}) async {
  if (web) return const {};
  return {
    BackupStoreKind.relay,
    if (apple && await cloudKitEnabled()) BackupStoreKind.icloud,
    if (google) BackupStoreKind.gdrive,
  };
}

/// A [CloudBackupService] over [backend], with its engine built the way a
/// cloud store needs it: no group record uploaded, and each upload's time
/// kept in [meta] so the status line survives a restart.
Future<CloudBackupService> buildCloudBackupService({
  required CloudBackend backend,
  required AuthStorage authStorage,
  required BackupMetaStore meta,
  required BackupSnapshot snapshot,
  required Future<String> Function() deviceName,
  required String platform,
  DateTime Function()? clock,
}) async {
  final identity = await BackupIdentity.loadOrCreate(authStorage);
  late final SlotSyncEngine engine;
  engine = SlotSyncEngine(
    meta: meta,
    snapshot: snapshot,
    deviceName: deviceName,
    platform: platform,
    clock: clock ?? DateTime.now,
    filterOwn: CloudBackupService.filterOwn,
    afterUpload: () =>
        CloudBackupService.persistLastSuccess(meta, backend.kind, engine)(),
  );
  return CloudBackupService(
    engine: engine,
    backend: backend,
    identity: identity,
    meta: meta,
    deviceName: deviceName,
    platform: platform,
    clock: clock,
  );
}

/// The one active backup store (relay, iCloud or Google Drive) and the
/// triggers forwarded to it. Free of Riverpod: `backupControllerProvider`
/// wires the stores and the triggers.
///
/// The active store is kept in [AuthStorage] under [storeKey] (`relay`,
/// `icloud`, `gdrive` or `off`). An install from before the key, with a
/// relay vault, is the relay. The relay's own screens still enable and
/// disable it directly, so the controller follows the relay's status too:
/// a relay that comes up while nothing is active becomes active, and one
/// turned off stops being. Cloud stores likewise.
///
/// Leaving the relay for a cloud store keeps its vault dormant on disk
/// (see [BackupSyncService.switchAway]); only switching back wakes it.
class BackupController {
  BackupController({
    required BackupSyncService relay,
    required AuthStorage authStorage,
    required CloudServiceBuilder buildCloud,
    required Future<Set<BackupStoreKind>> Function() resolveOffered,
    Set<BackupStoreKind> initialOffered = const {},
    this.googleAuth,
  })  : _relay = relay,
        _auth = authStorage,
        _buildCloud = buildCloud,
        _resolveOffered = resolveOffered,
        _offered = ValueNotifier(initialOffered) {
    ready = _init();
    // Reported through [start]; never an unhandled error.
    unawaited(ready.catchError((Object _) {}));
  }

  /// Where the active store is kept.
  static const storeKey = 'backup/store';

  /// Where the pairing hint is kept.
  static const hintKey = 'backup/storeHint';

  static const _off = 'off';

  final BackupSyncService _relay;
  final AuthStorage _auth;
  final CloudServiceBuilder _buildCloud;
  final Future<Set<BackupStoreKind>> Function() _resolveOffered;

  /// The signed-in Google account for Drive, null where Drive is not
  /// offered. Task-level sign-in UI drives it: `GoogleSignInAuth.signIn`
  /// directly, or `LoopbackPkceFlow` / `DeviceCodeFlow` (in
  /// `google_oauth_flows.dart`) over a `GoogleTokenAuth` by its
  /// `clientKind`.
  final GoogleAuth? googleAuth;

  final ValueNotifier<Set<BackupStoreKind>> _offered;
  final _active = ValueNotifier<BackupStoreKind?>(null);
  final _hint = ValueNotifier<CloudStoreHint?>(null);
  final _cloud = <BackupStoreKind, CloudBackupService>{};
  final _unlisten = <VoidCallback>[];

  /// Completes once the active store, the hint and the offered stores are
  /// known and the cloud services are built. Every operation waits on it.
  late final Future<void> ready;

  /// While above zero the controller is changing stores itself, so the
  /// status of a store it is leaving or entering is not followed.
  int _switching = 0;
  bool _initialized = false;
  bool _disposed = false;

  /// The active store; null while backup is off (and until [ready]).
  ValueListenable<BackupStoreKind?> get active => _active;

  /// The cloud store pairing said the group uses, until [acknowledgeHint]
  /// or until this device backs up there.
  ValueListenable<CloudStoreHint?> get storeHint => _hint;

  /// The stores this device can use. Starts with what is known without
  /// asking the platform, and settles once [ready] (iCloud needs an async
  /// check of the build).
  ValueListenable<Set<BackupStoreKind>> get offered => _offered;

  /// The #1414 relay service.
  BackupSyncService get relay => _relay;

  /// The service of the offered cloud store [kind]. Throws [StateError]
  /// before [ready], or for a store not offered here.
  CloudBackupService cloud(BackupStoreKind kind) {
    final s = _cloud[kind];
    if (s == null) {
      throw StateError('${kind.name} is not offered on this device');
    }
    return s;
  }

  // Lifecycle

  Future<void> _init() async {
    Set<BackupStoreKind> offered;
    try {
      offered = await _resolveOffered();
    } catch (e) {
      debugPrint('[Backup] Offered stores not resolved: ${e.runtimeType}');
      offered = _offered.value;
    }
    if (_disposed) return;
    // One store that cannot be built (a broken backend, an unreadable
    // identity) is left out; the others still work.
    for (final kind in offered) {
      if (kind == BackupStoreKind.relay) continue;
      final CloudBackupService service;
      try {
        service = await _buildCloud(kind);
      } catch (e) {
        debugPrint('[Backup] ${kind.name} not available: ${e.runtimeType}');
        continue;
      }
      if (_disposed) {
        service.dispose();
        return;
      }
      _cloud[kind] = service;
    }
    _offered.value = Set.unmodifiable({
      for (final kind in offered)
        if (kind == BackupStoreKind.relay || _cloud.containsKey(kind)) kind,
    });

    void follow(BackupStoreKind kind, ValueListenable<BackupStatus> status) {
      void listener() => _follow(kind, status.value);
      status.addListener(listener);
      _unlisten.add(() => status.removeListener(listener));
    }

    follow(BackupStoreKind.relay, _relay.status);
    for (final MapEntry(:key, :value) in _cloud.entries) {
      follow(key, value.status);
    }

    final raw = await _auth.read(storeKey);
    final hasVault = await _auth.read(BackupVaultStateStore.storageKey) != null;
    BackupStoreKind? active;
    if (raw == null) {
      // An install from before the key: a relay vault means the relay.
      active = hasVault ? BackupStoreKind.relay : null;
      if (active != null) await _auth.write(storeKey, active.name);
    } else {
      active = BackupStoreKind.parse(raw);
      // The key outlived the vault (it was cleared elsewhere).
      if (active == BackupStoreKind.relay && !hasVault) active = null;
    }
    if (active != null &&
        active != BackupStoreKind.relay &&
        !_cloud.containsKey(active)) {
      // The stored cloud store could not be built (or is no longer offered):
      // off for this run, so the viewer gets the picker instead of a relay
      // switch that throws. The key is kept, and nothing in that store or
      // in the meta store is touched, so a later launch that builds it
      // picks the backup up again; enabling another store overwrites it.
      debugPrint('[Backup] Active store ${active.name} unavailable; off');
      active = null;
    }
    final hint = await _auth.read(hintKey);
    if (_disposed) return;
    _active.value = active;
    if (hint != null) {
      try {
        _hint.value = CloudStoreHint.fromJson(jsonDecode(hint));
      } on FormatException {
        _hint.value = null;
      }
    }
    _initialized = true;
  }

  /// Starts the active store, as on app start. Never throws: a failure
  /// lands in that store's status.
  ///
  /// A controller that could not read which store is active falls back to
  /// the relay, as before cloud stores existed: the relay becomes active
  /// (so the triggers reach it) unless its vault is dormant, and stays so
  /// only if it comes up in a vault.
  Future<void> start() async {
    try {
      await ready;
    } catch (e) {
      debugPrint('[Backup] Store not read, starting the relay: '
          '${e.runtimeType}');
      if (_disposed) return;
      final relayActive = !_relay.dormant;
      if (relayActive) _active.value = BackupStoreKind.relay;
      _initialized = true;
      await _relay.start();
      if (relayActive && !_relay.enabled && !_disposed) _active.value = null;
      return;
    }
    if (_disposed) return;
    switch (_active.value) {
      case null:
        return;
      case BackupStoreKind.relay:
        await _relay.start();
      case final kind:
        await _cloud[kind]?.start();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final u in _unlisten) {
      u();
    }
    for (final s in _cloud.values) {
      s.dispose();
    }
    _active.dispose();
    _hint.dispose();
    _offered.dispose();
  }

  // Triggers: the active store only.

  void markDirty() {
    switch (_active.value) {
      case null:
        return;
      case BackupStoreKind.relay:
        _relay.markDirty();
      case final kind:
        _cloud[kind]?.markDirty();
    }
  }

  Future<void> flush() async {
    switch (_active.value) {
      case null:
        return;
      case BackupStoreKind.relay:
        await _relay.flush();
      case final kind:
        await _cloud[kind]?.flush();
    }
  }

  Future<void> poll() async {
    switch (_active.value) {
      case null:
        return;
      case BackupStoreKind.relay:
        await _relay.poll();
      case final kind:
        await _cloud[kind]?.poll();
    }
  }

  // Changing stores

  /// Turns backup on in the cloud store [kind] while it is off. Its backend
  /// must be signed in already (sign-in is the caller's): throws
  /// `BackupRelayException(signedOut)` otherwise, touching nothing. Throws
  /// [StateError] while another store is active; use [switchTo].
  Future<void> enableCloud(BackupStoreKind kind) async {
    await ready;
    if (kind == BackupStoreKind.relay) {
      throw ArgumentError.value(kind, 'kind', 'is not a cloud store');
    }
    final service = cloud(kind);
    if (_active.value != null) {
      throw StateError('backup is on in ${_active.value!.name}');
    }
    _switching++;
    try {
      await service.enable();
      await _setActive(kind);
    } finally {
      _switching--;
    }
  }

  /// Moves the backup from the active store to [to], or turns it on there
  /// when off.
  ///
  /// [to] comes up first: a cloud [to] must be signed in already, and an
  /// account that is not usable throws (`BackupRelayException`) with the old
  /// store untouched and still active. Only then does the old store get a
  /// moved stub naming [to] (and lose every other device's backup when
  /// [deleteOld]). A failure leaving the old store is rethrown with [to]
  /// already active: the backup lives there, and the old store just never
  /// learned of the move. It still stops syncing (a relay vault goes
  /// dormant), so switching back to it works as after a clean leave.
  ///
  /// The relay resumes its dormant vault when there is one, else creates a
  /// vault with [relayKey], which the caller made with
  /// `relay.prepareEnable()` and showed: without one this throws
  /// [ArgumentError] before touching anything.
  Future<void> switchTo(BackupStoreKind to,
      {required bool deleteOld, RecoveryKey? relayKey}) async {
    await ready;
    final from = _active.value;
    if (from == to) return;
    final target = to == BackupStoreKind.relay ? null : cloud(to);
    if (to == BackupStoreKind.relay && !_relay.dormant && relayKey == null) {
      throw ArgumentError.notNull('relayKey');
    }
    final old = switch (from) {
      null => null,
      BackupStoreKind.relay => (
          pause: _relay.pauseSync,
          resume: _relay.resumeSync,
          leave: () => _relay.switchAway(to.name, deleteOld: deleteOld),
        ),
      final kind => _storeOps(cloud(kind), to, deleteOld),
    };
    _switching++;
    try {
      // The old store stops syncing in the background (it stays joined)
      // while the new one comes up, so two stores never poll at once; it
      // syncs again if the new one does not come up.
      await old?.pause();
      try {
        if (target != null) {
          await target.enable();
        } else if (_relay.dormant) {
          await _relay.resumeDormant();
          if (!_relay.enabled) {
            throw StateError('the dormant relay vault could not be resumed');
          }
        } else {
          await _relay.confirmEnable(relayKey!);
        }
      } catch (_) {
        old?.resume();
        rethrow;
      }
      await _setActive(to);
      await old?.leave();
    } finally {
      _switching--;
    }
  }

  /// What [switchTo] does to the cloud store [s] it leaves for [to].
  static _OldStore _storeOps(
          CloudBackupService s, BackupStoreKind to, bool deleteOld) =>
      (
        pause: s.pauseSync,
        resume: s.resumeSync,
        leave: () => s.switchAway(to.name, deleteOld: deleteOld),
      );

  /// Dismisses [storeHint], here and across restarts.
  void acknowledgeHint() {
    if (_disposed) return;
    _hint.value = null;
    unawaited(_auth.delete(hintKey).catchError((Object e) {
      debugPrint('[Backup] Store hint not cleared: ${e.runtimeType}');
    }));
  }

  // Pairing

  /// Joiner: the relay keys to send with `Pair`, so a relay host adds this
  /// device to its vault. None while this device backs up to a cloud store:
  /// joining the host's vault would move its backup silently.
  Future<({String signer, String box})?> pairKeys() async {
    try {
      await ready;
    } catch (_) {
      // Unknown store: as before cloud stores existed.
    }
    final kind = _active.value;
    if (kind != null && kind != BackupStoreKind.relay) return null;
    return _relay.pairKeys();
  }

  /// Host: the cloud store to send a joiner, null with the relay or off.
  Future<({String store, String? account})?> cloudStoreForPair() async {
    try {
      await ready;
    } catch (_) {
      return null;
    }
    final kind = _active.value;
    if (kind == null || kind == BackupStoreKind.relay) return null;
    String? account;
    if (kind == BackupStoreKind.gdrive) {
      account = _cloud[kind]?.accountLabel.value;
      if (account == null) {
        try {
          account = await googleAuth?.currentEmail();
        } catch (_) {
          account = null;
        }
      }
    }
    return (store: kind.name, account: account);
  }

  /// Joiner: the host backs up to [store] as [account]. Kept as
  /// [storeHint]; nothing is joined. Ignored for a store this device does
  /// not know, or already backs up to.
  Future<void> noteStoreHint(String store, String? account) async {
    final kind = BackupStoreKind.parse(store);
    if (kind == null || kind == BackupStoreKind.relay) return;
    await ready;
    if (_disposed || _active.value == kind) return;
    final hint = CloudStoreHint(kind, account);
    _hint.value = hint;
    await _auth.write(hintKey, jsonEncode(hint.toJson()));
  }

  // State

  /// Follows a store turned on or off outside [enableCloud] and [switchTo]
  /// (the relay's own screens, a restore, a removal).
  void _follow(BackupStoreKind kind, BackupStatus status) {
    if (_switching > 0 || !_initialized || _disposed) return;
    final on = kind == BackupStoreKind.relay
        ? _relay.enabled
        : (_cloud[kind]?.enabled ?? false);
    final active = _active.value;
    if (on &&
        active == null &&
        (status is BackupIdle || status is BackupUploading)) {
      unawaited(_setActive(kind));
    } else if (!on &&
        active == kind &&
        (status is BackupOff || status is BackupRemoved)) {
      unawaited(_setActive(null));
    }
  }

  Future<void> _setActive(BackupStoreKind? kind) async {
    if (_disposed) return;
    _active.value = kind;
    if (kind != null && _hint.value?.kind == kind) acknowledgeHint();
    try {
      await _auth.write(storeKey, kind?.name ?? _off);
    } catch (e) {
      debugPrint('[Backup] Active store not saved: ${e.runtimeType}');
    }
  }
}

/// What [PeerSyncService] takes for pairing, over the controller [of]: the
/// relay's #1414 hooks, plus the cloud store hint. [of] is read only when a
/// hook runs, so a provider can hand this over without a cycle.
BackupPairingHooks backupPairingHooksFor(BackupController Function() of) =>
    BackupPairingHooks(
      backupKeysForPair: () => of().pairKeys(),
      onJoinerBackupKeys: (nodeId, signer, box, deadline) => of()
          .relay
          .addMemberForPair(signer, box, nodeId: nodeId, deadline: deadline),
      onJoinedVault: (vaultId) => of().relay.adoptVault(vaultId),
      onPeerRevoked: (nodeId, name) =>
          of().relay.notePeerRevoked(nodeId, deviceName: name),
      cloudStoreForPair: () => of().cloudStoreForPair(),
      onCloudStoreHint: (store, account) => of().noteStoreHint(store, account),
    );
