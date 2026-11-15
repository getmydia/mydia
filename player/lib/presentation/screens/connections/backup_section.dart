/// Backup & sync, on the main Settings screen and in the desktop settings
/// dialog's own category: where the backup lives (the end-to-end encrypted
/// relay, iCloud or Google Drive), its switch and status, the devices in it,
/// the relay's recovery key, and deleting it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/backup_providers.dart';
import '../../../core/backup/backup_relay_client.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../../widgets/toast/toaster.dart';
import '../backup/cloud_backup_body.dart';
import '../backup/google_device_code_sheet.dart';
import '../backup/pending_sources_row.dart';
import '../backup/recovery_key_sheet.dart';
import '../backup/store_picker.dart';
import '../backup/vault_choice_dialog.dart';
import 'connections_hub_cards.dart';

class BackupSection extends ConsumerStatefulWidget {
  const BackupSection({super.key});

  @override
  ConsumerState<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<BackupSection> {
  late final BackupController _controller;
  late final BackupSyncService _service;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(backupControllerProvider);
    _service = _controller.relay;
    _service.pendingVaultChoice.addListener(_onVaultChoice);
  }

  @override
  void dispose() {
    _service.pendingVaultChoice.removeListener(_onVaultChoice);
    super.dispose();
  }

  /// Pairing just offered the group's backup to a device already in its
  /// own: ask at once. The row below stays until it is answered.
  void _onVaultChoice() {
    if (_service.pendingVaultChoice.value == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _service.pendingVaultChoice.value != null) {
        _openVaultChoice();
      }
    });
  }

  /// Set while the vault choice dialog is up, so a second change of the
  /// choice (or the row's button) does not stack another.
  bool _vaultChoiceOpen = false;

  Future<void> _openVaultChoice() async {
    if (_vaultChoiceOpen) return;
    _vaultChoiceOpen = true;
    try {
      await showVaultChoiceDialog(context, _service);
    } finally {
      _vaultChoiceOpen = false;
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    required Key key,
  }) =>
      showBackupConfirm(context,
          title: title, body: body, action: action, key: key);

  /// Runs [op], toasting a failure. The section rebuilds after, since the
  /// service's plain getters (enabled, the recovery key) may have changed.
  /// [store] words a failure for the store it was about.
  Future<T?> _run<T>(Future<T> Function() op, {BackupStoreKind? store}) async {
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      return await op();
    } catch (e) {
      debugPrint('[Backup] Action failed: ${e.runtimeType}');
      toaster.show(
          store == null
              ? l10n.backupActionFailed
              : cloudFailureText(l10n, store, e),
          kind: ToastKind.error);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool on) async {
    if (on) return _pick(BackupStoreKind.relay);
    final l10n = context.l10n;
    if (await _confirm(
      title: l10n.backupTurnOffTitle,
      body: l10n.backupTurnOffBody,
      action: l10n.backupTurnOff,
      key: const Key('backup-turn-off-confirm'),
    )) {
      await _run(_service.disable);
    }
  }

  // Choosing a store

  /// Signs in to Google when [kind] is Drive. True when [kind] can be used
  /// now.
  Future<bool> _signInFor(BackupStoreKind kind) async {
    if (kind != BackupStoreKind.gdrive) return true;
    final ok =
        await signInToGoogle(context, ref.read(googleSignInMethodProvider));
    return ok && mounted;
  }

  /// Turns backup on in [kind] while it is off. The relay shows a new
  /// recovery key first, unless its vault is only dormant.
  Future<void> _pick(BackupStoreKind kind) async {
    if (kind == BackupStoreKind.relay) {
      if (_service.dormant) {
        await _run(() =>
            _controller.switchTo(BackupStoreKind.relay, deleteOld: false));
      } else {
        await showEnableBackupSheet(context, _service,
            confirm: (key) => _controller.switchTo(BackupStoreKind.relay,
                deleteOld: false, relayKey: key));
      }
      if (mounted) setState(() {});
      return;
    }
    if (!await _signInFor(kind)) return;
    await _run(() => _controller.enableCloud(kind), store: kind);
  }

  /// Moves the backup from the active store to [to], after asking (and
  /// whether to delete the old one) unless [ask] is false.
  Future<void> _switch(BackupStoreKind to, {bool ask = true}) async {
    final from = _controller.active.value;
    if (from == null) return _pick(to);
    var deleteOld = false;
    if (ask) {
      final answer = await _askSwitch(from, to);
      if (answer == null || !mounted) return;
      deleteOld = answer;
    }
    if (to == BackupStoreKind.relay && !_service.dormant) {
      await showEnableBackupSheet(context, _service,
          confirm: (key) => _controller.switchTo(BackupStoreKind.relay,
              deleteOld: deleteOld, relayKey: key));
      if (mounted) setState(() {});
      return;
    }
    if (!await _signInFor(to)) return;
    await _run(() => _controller.switchTo(to, deleteOld: deleteOld), store: to);
  }

  /// Whether to switch from [from] to [to]: null when cancelled, else
  /// whether to delete the backup left behind.
  Future<bool?> _askSwitch(BackupStoreKind from, BackupStoreKind to) =>
      showDialog<bool>(
        context: context,
        builder: (_) => _SwitchDialog(from: from, to: to),
      );

  // Relay members and key

  /// Removes the device owning [slotId], which also replaces the recovery
  /// key: the new one is shown until the viewer acknowledges it.
  Future<void> _removeMember(String slotId, String name) async {
    final l10n = context.l10n;
    if (!await _confirm(
      title: l10n.backupRemoveMemberTitle(name),
      body: l10n.backupRemoveMemberBody,
      action: l10n.commonRemove,
      key: const Key('backup-remove-member-confirm'),
    )) {
      return;
    }
    final key = await _run(() => _service.removeMember(slotId));
    if (key != null) await _showNewKey(key.display);
  }

  /// Shows the recovery key that replaced the old one until Done, which
  /// alone acknowledges it.
  Future<void> _showNewKey(String keyText) async {
    if (!mounted) return;
    await showReplacedRecoveryKeySheet(context, keyText,
        onDone: () => unawaited(_service.acknowledgeNewRecoveryKey()));
  }

  Future<void> _regenerate() async {
    final l10n = context.l10n;
    if (!await _confirm(
      title: l10n.backupRegenerateConfirmTitle,
      body: l10n.backupRegenerateConfirmBody,
      action: l10n.backupRegenerateKey,
      key: const Key('backup-regenerate-confirm'),
    )) {
      return;
    }
    final key = await _run(_service.regenerateRecoveryKey);
    if (key != null) await _showNewKey(key.display);
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    if (await _confirm(
      title: l10n.backupDeleteConfirmTitle,
      body: l10n.backupDeleteConfirmBody,
      action: l10n.backupDelete,
      key: const Key('backup-delete-confirm'),
    )) {
      await _run(_service.deleteBackup);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = _service;
    final c = _controller;
    return ListenableBuilder(
      listenable: Listenable.merge([
        c.active,
        c.offered,
        c.storeHint,
        s.status,
        s.joinedNotice,
        s.pendingVaultChoice,
        s.unreadableSlots,
        s.recoveryKeyMismatch,
        s.unsavedRecoveryKey,
        s.members,
        s.pendingRemovals,
      ]),
      builder: (context, _) {
        final active = c.active.value;
        final offered = c.offered.value;
        // A cloud store is only usable once its service is built, which
        // `offered` says.
        final cloud = active != null &&
            active != BackupStoreKind.relay &&
            offered.contains(active);
        final status = s.status.value;
        final unavailable = !cloud && status is BackupUnavailable;
        // Only the relay is offered: its switch, as before cloud stores.
        final relayOnly = !offered.any((k) => k != BackupStoreKind.relay);
        final picking = active == null && !relayOnly;
        final others = {
          for (final k in offered)
            if (k != active && !(unavailable && k == BackupStoreKind.relay)) k,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HubSectionHeader(
              title: l10n.backupSectionTitle,
              // The relay's promise; the picker words each store's.
              hint: cloud || picking ? null : l10n.backupSectionHint,
            ),
            HubCardSurface(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s.joinedNotice.value)
                    BackupNotice(
                      key: const Key('backup-joined-notice'),
                      icon: Icons.cloud_done_rounded,
                      text: l10n.backupJoinedNotice,
                      action: TextButton(
                        key: const Key('backup-joined-notice-dismiss'),
                        onPressed: s.acknowledgeJoinedNotice,
                        child: Text(l10n.backupJoinedNoticeDismiss),
                      ),
                    ),
                  if (s.pendingVaultChoice.value != null)
                    BackupNotice(
                      key: const Key('backup-vault-choice-row'),
                      icon: Icons.call_split_rounded,
                      text: l10n.backupVaultChoicePending,
                      action: TextButton(
                        key: const Key('backup-vault-choice-open'),
                        onPressed: _openVaultChoice,
                        child: Text(l10n.backupVaultChoiceOpen),
                      ),
                    ),
                  if (_hint(l10n, c.storeHint.value, active, offered)
                      case final hint?)
                    hint,
                  if (unavailable)
                    BackupLine(
                      key: const Key('backup-unavailable'),
                      icon: Icons.cloud_off_rounded,
                      text: l10n.backupUnavailable,
                    ),
                  if (picking)
                    StorePicker(
                      stores: others,
                      enabled: !_busy,
                      onPick: _pick,
                    )
                  else if (cloud) ...[
                    _StoreNotices(
                      moved: c.cloud(active).movedSlots,
                      newer: c.cloud(active).newerVersionSeen,
                      names: () => c.cloud(active).slotDeviceNames,
                      offered: offered,
                      dormantRelay: () => s.dormant,
                      onSwitch: _busy ? null : (to) => _switch(to, ask: false),
                    ),
                    CloudBackupBody(
                      key: ValueKey(active),
                      kind: active,
                      service: c.cloud(active),
                    ),
                  ] else if (!unavailable) ...[
                    SwitchListTile(
                      key: const Key('backup-switch'),
                      value: s.enabled,
                      onChanged: _busy ? null : _toggle,
                      title: Text(l10n.backupSwitchLabel),
                      subtitle: _status(l10n, status),
                    ),
                    if (s.enabled) ...[
                      _StoreNotices(
                        moved: s.movedSlots,
                        newer: s.newerVersionSeen,
                        names: () => s.slotDeviceNames,
                        offered: offered,
                        dormantRelay: () => false,
                        onSwitch:
                            _busy ? null : (to) => _switch(to, ask: false),
                      ),
                      ..._enabledBody(l10n),
                    ],
                  ],
                  if (active != null && others.isNotEmpty) ...[
                    const Divider(height: 20),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        l10n.backupSwitchStoreHeader,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: context.palette.textSecondary),
                      ),
                    ),
                    StorePicker(
                      stores: others,
                      enabled: !_busy,
                      onPick: _switch,
                    ),
                  ],
                  if (!unavailable && !cloud && !picking)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        l10n.backupIdleNotice,
                        key: const Key('backup-idle-notice'),
                        style: TextStyle(
                            fontSize: 12, color: context.palette.textDisabled),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Pairing said the group backs up to a cloud store this device offers
  /// and does not use: join it, or dismiss.
  Widget? _hint(AppLocalizations l10n, CloudStoreHint? hint,
      BackupStoreKind? active, Set<BackupStoreKind> offered) {
    if (hint == null || hint.kind == active || !offered.contains(hint.kind)) {
      return null;
    }
    return BackupNotice(
      key: const Key('backup-hint'),
      icon: Icons.cloud_sync_rounded,
      text: l10n.backupStoreHint(backupStoreName(l10n, hint.kind)),
      action: Wrap(
        spacing: 4,
        children: [
          TextButton(
            key: const Key('backup-hint-dismiss'),
            onPressed: _controller.acknowledgeHint,
            child: Text(l10n.backupJoinedNoticeDismiss),
          ),
          FilledButton.tonal(
            key: const Key('backup-hint-join'),
            onPressed: _busy ? null : () => _switch(hint.kind),
            child: Text(l10n.backupStoreHintJoin),
          ),
        ],
      ),
    );
  }

  /// The status under the switch: an error keeps the last success in view.
  Widget? _status(AppLocalizations l10n, BackupStatus status) {
    String last(int? ms) => ms == null
        ? l10n.backupStatusNever
        : l10n.backupStatusLastBackedUp(backupAgo(l10n, ms));
    final lines = switch (status) {
      BackupOff() || BackupUnavailable() => const <String>[],
      BackupRemoved() => [l10n.backupRemoved],
      BackupIdle(:final lastSuccessMs) => [last(lastSuccessMs)],
      BackupUploading() => [l10n.backupStatusUploading],
      BackupError(:final kind, :final lastSuccessMs) => [
          switch (kind) {
            BackupRelayError.network => l10n.backupErrorNetwork,
            BackupRelayError.rateLimited => l10n.backupErrorRateLimited,
            BackupRelayError.tooLarge ||
            BackupRelayError.quotaFull =>
              l10n.backupErrorTooLarge,
            _ => l10n.backupErrorGeneric,
          },
          last(lastSuccessMs),
        ],
    };
    if (lines.isEmpty) return null;
    return Column(
      key: const Key('backup-status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final line in lines) Text(line)],
    );
  }

  List<Widget> _enabledBody(AppLocalizations l10n) {
    final s = _service;
    final names = s.slotDeviceNames;
    final keyText = s.recoveryKeyText;
    String nameOf(BackupMemberInfo m) =>
        m.deviceName ??
        (m.isThisDevice ? l10n.backupThisDevice : l10n.backupUnknownDevice);
    return [
      if (s.unsavedRecoveryKey.value && keyText != null)
        BackupNotice(
          key: const Key('backup-unsaved-key'),
          icon: Icons.key_rounded,
          warning: true,
          text: l10n.backupUnsavedKey,
          action: TextButton(
            key: const Key('backup-unsaved-key-show'),
            onPressed: _busy ? null : () => _showNewKey(keyText),
            child: Text(l10n.backupUnsavedKeyShow),
          ),
        ),
      if (s.recoveryKeyMismatch.value)
        BackupLine(
          key: const Key('backup-key-mismatch'),
          icon: Icons.warning_amber_rounded,
          text: l10n.backupKeyMismatch,
          warning: true,
        ),
      for (final r in s.pendingRemovals.value)
        BackupNotice(
          key: Key('backup-pending-removal-${r.slotId}'),
          icon: Icons.warning_amber_rounded,
          warning: true,
          text: l10n
              .backupPendingRemoval(r.deviceName ?? l10n.backupUnknownDevice),
          action: TextButton(
            key: Key('backup-pending-removal-remove-${r.slotId}'),
            onPressed: _busy
                ? null
                : () => _removeMember(
                    r.slotId, r.deviceName ?? l10n.backupUnknownDevice),
            child: Text(l10n.commonRemove),
          ),
        ),
      for (final slot in s.unreadableSlots.value)
        BackupLine(
          key: Key('backup-unreadable-$slot'),
          icon: Icons.error_outline_rounded,
          text: l10n.backupUnreadable(names[slot] ?? l10n.backupUnknownDevice),
          warning: true,
        ),
      for (final m in s.members.value)
        ListTile(
          key: Key('backup-member-${m.slotId}'),
          dense: true,
          leading: Icon(m.isThisDevice
              ? Icons.smartphone_rounded
              : Icons.devices_other_rounded),
          title: Text(nameOf(m)),
          subtitle: Text(switch (m.lastUploadMs) {
            null => l10n.backupStatusNever,
            final ms => l10n.backupMemberLastUpload(backupAgo(l10n, ms)),
          }),
          trailing: m.isThisDevice
              ? HubChip(label: l10n.backupThisDevice)
              : IconButton(
                  key: Key('backup-member-remove-${m.slotId}'),
                  tooltip: l10n.commonRemove,
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  onPressed:
                      _busy ? null : () => _removeMember(m.slotId, nameOf(m)),
                ),
        ),
      PendingSourcesRow(service: s),
      const Divider(height: 20),
      if (keyText == null)
        BackupLine(
          key: const Key('backup-no-key'),
          icon: Icons.key_off_rounded,
          text: l10n.backupNoKeyOnDevice,
        ),
      Wrap(
        spacing: 4,
        children: [
          if (keyText != null)
            TextButton.icon(
              key: const Key('backup-show-key'),
              icon: const Icon(Icons.key_rounded, size: 18),
              label: Text(l10n.backupShowRecoveryKey),
              onPressed:
                  _busy ? null : () => showRecoveryKeySheet(context, keyText),
            ),
          TextButton.icon(
            key: const Key('backup-regenerate-key'),
            icon: const Icon(Icons.autorenew_rounded, size: 18),
            label: Text(l10n.backupRegenerateKey),
            onPressed: _busy ? null : _regenerate,
          ),
          TextButton.icon(
            key: const Key('backup-delete'),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(l10n.backupDelete),
            onPressed: _busy ? null : _delete,
          ),
        ],
      ),
    ];
  }
}

/// Asks before moving the backup from [from] to [to]; pops whether to
/// delete the backup left in [from], or null when cancelled.
class _SwitchDialog extends StatefulWidget {
  const _SwitchDialog({required this.from, required this.to});

  final BackupStoreKind from;
  final BackupStoreKind to;

  @override
  State<_SwitchDialog> createState() => _SwitchDialogState();
}

class _SwitchDialogState extends State<_SwitchDialog> {
  bool _deleteOld = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return GlassDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.backupSwitchConfirm(backupStoreName(l10n, widget.to))),
          const SizedBox(height: 12),
          CheckboxListTile(
            key: const Key('backup-switch-delete-old'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _deleteOld,
            onChanged: (v) => setState(() => _deleteOld = v ?? false),
            title: Text(
                l10n.backupSwitchDeleteOld(backupStoreName(l10n, widget.from))),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('backup-switch-confirm'),
          onPressed: () => Navigator.of(context).pop(_deleteOld),
          child: Text(l10n.backupSwitch),
        ),
      ],
    );
  }
}

/// The active store's word from other devices: a device moved the backup
/// elsewhere (with Switch, when this device can follow), or a device runs a
/// newer Mydia.
class _StoreNotices extends StatelessWidget {
  const _StoreNotices({
    required this.moved,
    required this.newer,
    required this.names,
    required this.offered,
    required this.dormantRelay,
    required this.onSwitch,
  });

  /// Slot id to the store id it moved to.
  final ValueListenable<Map<String, String>> moved;
  final ValueListenable<bool> newer;
  final Map<String, String> Function() names;
  final Set<BackupStoreKind> offered;

  /// Following a move to the relay needs this device's dormant vault: a
  /// new one would not be the group's.
  final bool Function() dormantRelay;
  final ValueChanged<BackupStoreKind>? onSwitch;

  bool _canFollow(BackupStoreKind? to) =>
      to != null &&
      offered.contains(to) &&
      (to != BackupStoreKind.relay || dormantRelay());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([moved, newer]),
      builder: (context, _) {
        final deviceNames = names();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final MapEntry(key: slot, value: storeId)
                in moved.value.entries)
              if (BackupStoreKind.parse(storeId) case final to?)
                BackupNotice(
                  key: Key('backup-moved-$slot'),
                  icon: Icons.drive_file_move_rounded,
                  text: l10n.backupMovedNotice(
                      deviceNames[slot] ?? l10n.backupUnknownDevice,
                      backupStoreName(l10n, to)),
                  action: switch (onSwitch) {
                    final follow? when _canFollow(to) => TextButton(
                        key: Key('backup-moved-switch-$slot'),
                        onPressed: () => follow(to),
                        child: Text(l10n.backupSwitch),
                      ),
                    _ => const SizedBox.shrink(),
                  },
                ),
            if (newer.value)
              BackupLine(
                key: const Key('backup-newer-version'),
                icon: Icons.system_update_rounded,
                text: l10n.backupNewerVersion,
                warning: true,
              ),
          ],
        );
      },
    );
  }
}
