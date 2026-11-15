import 'package:flutter/foundation.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_sync_service.dart';
import 'package:player/core/backup/recovery_key.dart';

/// A [BackupSyncService] the widget tests set up by hand: listenables to
/// drive, and the calls the UI made. Anything else throws.
class FakeBackupSyncService implements BackupSyncService {
  final statusNotifier = ValueNotifier<BackupStatus>(const BackupOff());
  final joinedNoticeNotifier = ValueNotifier<bool>(false);
  final vaultChoiceNotifier = ValueNotifier<VaultChoice?>(null);
  final unreadableNotifier = ValueNotifier<Set<String>>(const {});
  final mismatchNotifier = ValueNotifier<bool>(false);
  final unsavedKeyNotifier = ValueNotifier<bool>(false);
  final membersNotifier = ValueNotifier<List<BackupMemberInfo>>(const []);
  final offersNotifier = ValueNotifier<List<PendingAccountOffer>>(const []);
  final removalsNotifier = ValueNotifier<List<PendingRemoval>>(const []);
  final movedNotifier = ValueNotifier<Map<String, String>>(const {});
  final newerNotifier = ValueNotifier<bool>(false);

  final calls = <String>[];

  bool isEnabled = false;
  bool isDormant = false;
  String? keyText;
  Map<String, String> names = {};

  /// Keys handed out by [prepareEnable], in order; a fresh one when empty.
  final keys = <RecoveryKey>[];

  /// Makes the next [confirmEnable] fail with this.
  Exception? confirmError;

  /// When true, a failing [confirmEnable] marks [isEnabled] true first to
  /// mimic a post-enable persistence failure.
  bool enableBeforeConfirmError = false;

  @override
  ValueListenable<BackupStatus> get status => statusNotifier;
  @override
  ValueListenable<bool> get joinedNotice => joinedNoticeNotifier;
  @override
  bool get showJoinedNotice => joinedNoticeNotifier.value;
  @override
  ValueListenable<VaultChoice?> get pendingVaultChoice => vaultChoiceNotifier;
  @override
  ValueListenable<Set<String>> get unreadableSlots => unreadableNotifier;
  @override
  ValueListenable<bool> get recoveryKeyMismatch => mismatchNotifier;
  @override
  ValueListenable<bool> get unsavedRecoveryKey => unsavedKeyNotifier;
  @override
  ValueListenable<List<BackupMemberInfo>> get members => membersNotifier;
  @override
  ValueListenable<List<PendingAccountOffer>> get pendingOffers =>
      offersNotifier;
  @override
  ValueListenable<List<PendingRemoval>> get pendingRemovals => removalsNotifier;
  @override
  ValueListenable<Map<String, String>> get movedSlots => movedNotifier;
  @override
  ValueListenable<bool> get newerVersionSeen => newerNotifier;
  @override
  bool get dormant => isDormant;
  @override
  bool get enabled => isEnabled;
  @override
  String? get recoveryKeyText => keyText;
  @override
  Map<String, String> get slotDeviceNames => names;

  @override
  Future<RecoveryKey> prepareEnable() async {
    calls.add('prepareEnable');
    return keys.isEmpty ? RecoveryKey.generate() : keys.removeAt(0);
  }

  @override
  Future<void> confirmEnable(RecoveryKey key) async {
    calls.add('confirmEnable ${key.display}');
    final error = confirmError;
    if (error != null) {
      if (enableBeforeConfirmError) {
        isEnabled = true;
        keyText = key.display;
      }
      confirmError = null;
      throw error;
    }
    isEnabled = true;
    keyText = key.display;
    statusNotifier.value = const BackupIdle(null);
  }

  @override
  void acknowledgeJoinedNotice() {
    calls.add('acknowledgeJoinedNotice');
    joinedNoticeNotifier.value = false;
  }

  @override
  Future<void> resolveVaultChoice({required bool keepOffered}) async {
    calls.add('resolveVaultChoice $keepOffered');
    vaultChoiceNotifier.value = null;
  }

  @override
  Future<RecoveryKey> removeMember(String slotId) async {
    calls.add('removeMember $slotId');
    membersNotifier.value = [
      for (final m in membersNotifier.value)
        if (m.slotId != slotId) m,
    ];
    removalsNotifier.value = [
      for (final r in removalsNotifier.value)
        if (r.slotId != slotId) r,
    ];
    final key = RecoveryKey.generate();
    keyText = key.display;
    unsavedKeyNotifier.value = true;
    return key;
  }

  @override
  Future<RecoveryKey> regenerateRecoveryKey() async {
    calls.add('regenerateRecoveryKey');
    final key = RecoveryKey.generate();
    keyText = key.display;
    unsavedKeyNotifier.value = true;
    return key;
  }

  @override
  Future<void> acknowledgeNewRecoveryKey() async {
    calls.add('acknowledgeNewRecoveryKey');
    unsavedKeyNotifier.value = false;
  }

  @override
  Future<void> deleteBackup() async {
    calls.add('deleteBackup');
    isEnabled = false;
    statusNotifier.value = const BackupOff();
  }

  @override
  Future<void> disable() async {
    calls.add('disable');
    isEnabled = false;
    statusNotifier.value = const BackupOff();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'FakeBackupSyncService: ${invocation.memberName}');
}
