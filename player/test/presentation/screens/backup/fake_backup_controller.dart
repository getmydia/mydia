import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/cloud/cloud_backend.dart';
import 'package:player/core/backup/cloud/cloud_backup_service.dart';
import 'package:player/core/backup/cloud/google_auth.dart';
import 'package:player/core/backup/cloud/google_oauth_flows.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/backup/recovery_key.dart';
import 'package:player/core/backup/slot_transport.dart';
import 'package:player/presentation/screens/backup/google_device_code_sheet.dart';

import 'fake_backup_sync_service.dart';

/// A [BackupController] the widget tests set up by hand, over [relay] (a
/// [FakeBackupSyncService] unless given) and [FakeCloudBackupService]s.
/// The relay is active while it is enabled, as the real controller follows
/// it. Calls land in [calls]; anything else throws.
class FakeBackupController implements BackupController {
  FakeBackupController({
    BackupSyncService? relay,
    Set<BackupStoreKind> offered = const {BackupStoreKind.relay},
    BackupStoreKind? active,
  })  : _relay = relay ?? FakeBackupSyncService(),
        offeredNotifier = ValueNotifier(offered) {
    activeNotifier.value =
        active ?? (_relay.enabled ? BackupStoreKind.relay : null);
    for (final kind in offered) {
      final cloudKind = kind.cloudKind;
      if (cloudKind != null) {
        clouds[kind] = FakeCloudBackupService(cloudKind, calls);
      }
    }
    for (final MapEntry(:key, :value) in clouds.entries) {
      if (key == activeNotifier.value) value.isEnabled = true;
    }
  }

  final BackupSyncService _relay;
  final ValueNotifier<Set<BackupStoreKind>> offeredNotifier;
  final activeNotifier = ValueNotifier<BackupStoreKind?>(null);
  final hintNotifier = ValueNotifier<CloudStoreHint?>(null);
  final clouds = <BackupStoreKind, FakeCloudBackupService>{};
  final calls = <String>[];

  /// Makes the next [enableCloud] fail with this.
  Exception? enableError;

  @override
  ValueListenable<BackupStoreKind?> get active => activeNotifier;
  @override
  ValueListenable<Set<BackupStoreKind>> get offered => offeredNotifier;
  @override
  ValueListenable<CloudStoreHint?> get storeHint => hintNotifier;
  @override
  BackupSyncService get relay => _relay;
  @override
  late final Future<void> ready = Future<void>.value();
  @override
  GoogleAuth? get googleAuth => null;

  @override
  CloudBackupService cloud(BackupStoreKind kind) {
    final s = clouds[kind];
    if (s == null) throw StateError('${kind.name} is not offered');
    return s;
  }

  @override
  Future<void> enableCloud(BackupStoreKind kind) async {
    calls.add('enableCloud ${kind.name}');
    final error = enableError;
    if (error != null) {
      enableError = null;
      throw error;
    }
    clouds[kind]!.isEnabled = true;
    clouds[kind]!.statusNotifier.value = const BackupIdle(null);
    activeNotifier.value = kind;
  }

  @override
  Future<void> switchTo(BackupStoreKind to,
      {required bool deleteOld, RecoveryKey? relayKey}) async {
    calls.add('switchTo ${to.name} deleteOld=$deleteOld'
        '${relayKey == null ? '' : ' key'}');
    if (to == BackupStoreKind.relay && relayKey != null) {
      await _relay.confirmEnable(relayKey);
    }
    final from = activeNotifier.value;
    if (from != null && from != BackupStoreKind.relay) {
      clouds[from]!.isEnabled = false;
    }
    if (to != BackupStoreKind.relay) clouds[to]!.isEnabled = true;
    activeNotifier.value = to;
  }

  @override
  void acknowledgeHint() {
    calls.add('acknowledgeHint');
    hintNotifier.value = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'FakeBackupController: ${invocation.memberName}');
}

/// A [CloudBackupService] with listenables to drive and the calls the UI
/// made, recorded in the controller's list.
class FakeCloudBackupService implements CloudBackupService {
  FakeCloudBackupService(this.kind, this.calls);

  @override
  final CloudStoreKind kind;
  final List<String> calls;

  final statusNotifier = ValueNotifier<BackupStatus>(const BackupOff());
  final accountNotifier = ValueNotifier<String?>(null);
  final unreadableNotifier = ValueNotifier<Set<String>>(const {});
  final movedNotifier = ValueNotifier<Map<String, String>>(const {});
  final newerNotifier = ValueNotifier<bool>(false);
  final offersNotifier = ValueNotifier<List<PendingAccountOffer>>(const []);
  final slotsNotifier = ValueNotifier<List<SlotInfo>>(const []);
  Map<String, String> names = {};
  bool isEnabled = false;

  /// What [previewRestore] returns (a preview, or a [Completer] of one),
  /// or throws when an exception. Nothing means an empty store.
  Object? preview;

  /// Makes the next [reconnect] fail with this.
  Exception? reconnectError;

  String get _name => kind.name;

  @override
  bool get enabled => isEnabled;
  @override
  String get ownSlotId => 'own';
  @override
  ValueListenable<String?> get accountLabel => accountNotifier;
  @override
  ValueListenable<BackupStatus> get status => statusNotifier;
  @override
  ValueListenable<Set<String>> get unreadableSlots => unreadableNotifier;
  @override
  ValueListenable<Map<String, String>> get movedSlots => movedNotifier;
  @override
  ValueListenable<bool> get newerVersionSeen => newerNotifier;
  @override
  ValueListenable<List<PendingAccountOffer>> get pendingOffers =>
      offersNotifier;
  @override
  ValueListenable<List<SlotInfo>> get slots => slotsNotifier;
  @override
  Map<String, String> get slotDeviceNames => names;

  @override
  Future<CloudRestorePreview> previewRestore() async {
    calls.add('previewRestore $_name');
    final p = preview;
    if (p is Exception) throw p;
    if (p is CloudRestorePreview) return p;
    if (p is Completer<CloudRestorePreview>) return p.future;
    throw const BackupRelayException(BackupRelayError.notFound);
  }

  @override
  Future<ApplyResult> commitRestore(CloudRestorePreview preview) async {
    calls.add('commitRestore $_name');
    isEnabled = true;
    statusNotifier.value = const BackupIdle(null);
    return const ApplyResult(
        watchChanged: 0,
        pinsChanged: 0,
        accountsAdded: 0,
        settingsApplied: 0,
        newOffers: []);
  }

  @override
  Future<void> reconnect() async {
    calls.add('reconnect $_name');
    final error = reconnectError;
    if (error != null) {
      reconnectError = null;
      throw error;
    }
    statusNotifier.value = const BackupIdle(null);
  }

  @override
  Future<void> removeDevice(String slotId) async {
    calls.add('removeDevice $slotId');
    slotsNotifier.value = [
      for (final s in slotsNotifier.value)
        if (s.slotId != slotId) s,
    ];
  }

  @override
  Future<void> disable() async {
    calls.add('disable $_name');
    isEnabled = false;
    statusNotifier.value = const BackupOff();
  }

  @override
  Future<void> deleteBackup() async {
    calls.add('deleteBackup $_name');
    isEnabled = false;
    statusNotifier.value = const BackupOff();
  }

  @override
  Future<void> acceptPendingAccount(String accountId) async =>
      calls.add('acceptPendingAccount $accountId');

  @override
  Future<void> dismissPendingAccount(String accountId) async =>
      calls.add('dismissPendingAccount $accountId');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'FakeCloudBackupService: ${invocation.memberName}');
}

/// A cloud restore preview of one device holding [records].
CloudRestorePreview fakeCloudPreview(List<BackupRecord> records,
        {String device = 'Living Room TV',
        Set<String> unreadable = const {}}) =>
    CloudRestorePreview(
      payloads: {
        if (records.isNotEmpty)
          'tv': BackupPayload(
            deviceName: device,
            platform: 'android',
            createdAt: 1000,
            records: records,
          ),
      },
      unreadableSlots: unreadable,
    );

/// A Google sign-in the tests script: signed in as [email] (null when
/// out), signing in records a call and signs in as [signInAs]; with
/// [deviceCode] the sign-in is the TV's device code flow instead.
class FakeGoogleSignIn {
  FakeGoogleSignIn(this.calls, {this.email, this.signInAs = 'ana@example.com'});

  final List<String> calls;
  String? email;
  final String signInAs;

  /// Makes the next sign-in fail with this.
  Exception? signInError;

  /// When set, [method.signIn] waits on this before completing.
  Completer<void>? signInWaiter;

  /// The device code flow's states, for a TV sign-in. The test owns it.
  // ignore: close_sinks
  StreamController<DeviceCodeState>? deviceCode;

  GoogleSignInMethod get method => GoogleSignInMethod(
        currentEmail: () async => email,
        signIn: deviceCode == null
            ? () async {
                calls.add('signIn');
                final waiter = signInWaiter;
                if (waiter != null && !waiter.isCompleted) {
                  await waiter.future;
                }
                final error = signInError;
                if (error != null) {
                  signInError = null;
                  throw error;
                }
                email = signInAs;
              }
            : null,
        deviceCode: deviceCode == null
            ? null
            : () {
                calls.add('deviceCode');
                return deviceCode!.stream;
              },
      );
}
