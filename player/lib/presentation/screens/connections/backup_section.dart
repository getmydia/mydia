/// Backup & sync on the Servers & devices hub: the end-to-end encrypted cloud
/// backup's switch and status, the devices in it, the recovery key, and
/// deleting it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/backup_providers.dart';
import '../../../core/backup/backup_relay_client.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../../widgets/toast/toaster.dart';
import '../backup/pending_sources_row.dart';
import '../backup/recovery_key_sheet.dart';
import '../backup/vault_choice_dialog.dart';
import 'connections_hub_cards.dart';

class BackupSection extends ConsumerStatefulWidget {
  const BackupSection({super.key});

  @override
  ConsumerState<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<BackupSection> {
  late final BackupSyncService _service;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(backupSyncServiceProvider);
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
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        destructive: true,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            key: key,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Runs [op], toasting a failure. The section rebuilds after, since the
  /// service's plain getters (enabled, the recovery key) may have changed.
  Future<T?> _run<T>(Future<T> Function() op) async {
    final toaster = Toaster.of(context);
    final failed = context.l10n.backupActionFailed;
    setState(() => _busy = true);
    try {
      return await op();
    } catch (e) {
      debugPrint('[Backup] Action failed: ${e.runtimeType}');
      toaster.show(failed, kind: ToastKind.error);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool on) async {
    if (on) {
      await showEnableBackupSheet(context, _service);
      if (mounted) setState(() {});
      return;
    }
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
    return ListenableBuilder(
      listenable: Listenable.merge([
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
        final status = s.status.value;
        final unavailable = status is BackupUnavailable;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HubSectionHeader(
              title: l10n.backupSectionTitle,
              hint: l10n.backupSectionHint,
            ),
            HubCardSurface(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s.joinedNotice.value)
                    _Notice(
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
                    _Notice(
                      key: const Key('backup-vault-choice-row'),
                      icon: Icons.call_split_rounded,
                      text: l10n.backupVaultChoicePending,
                      action: TextButton(
                        key: const Key('backup-vault-choice-open'),
                        onPressed: _openVaultChoice,
                        child: Text(l10n.backupVaultChoiceOpen),
                      ),
                    ),
                  if (unavailable)
                    _Line(
                      key: const Key('backup-unavailable'),
                      icon: Icons.cloud_off_rounded,
                      text: l10n.backupUnavailable,
                    )
                  else
                    SwitchListTile(
                      key: const Key('backup-switch'),
                      value: s.enabled,
                      onChanged: _busy ? null : _toggle,
                      title: Text(l10n.backupSwitchLabel),
                      subtitle: _status(l10n, status),
                    ),
                  if (s.enabled && !unavailable) ..._enabledBody(l10n),
                  if (!unavailable)
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

  /// The status under the switch: an error keeps the last success in view.
  Widget? _status(AppLocalizations l10n, BackupStatus status) {
    String last(int? ms) => ms == null
        ? l10n.backupStatusNever
        : l10n.backupStatusLastBackedUp(_ago(l10n, ms));
    final lines = switch (status) {
      BackupOff() || BackupUnavailable() => const <String>[],
      BackupRemoved() => [l10n.backupRemoved],
      BackupIdle(:final lastSuccessMs) => [last(lastSuccessMs)],
      BackupUploading() => [l10n.backupStatusUploading],
      BackupError(:final kind, :final lastSuccessMs) => [
          switch (kind) {
            BackupRelayError.network => l10n.backupErrorNetwork,
            BackupRelayError.rateLimited => l10n.backupErrorRateLimited,
            BackupRelayError.tooLarge => l10n.backupErrorTooLarge,
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

  static String _ago(AppLocalizations l10n, int ms) =>
      l10n.relativeTime(DateTime.fromMillisecondsSinceEpoch(ms));

  List<Widget> _enabledBody(AppLocalizations l10n) {
    final s = _service;
    final names = s.slotDeviceNames;
    final keyText = s.recoveryKeyText;
    String nameOf(BackupMemberInfo m) =>
        m.deviceName ??
        (m.isThisDevice ? l10n.backupThisDevice : l10n.backupUnknownDevice);
    return [
      if (s.unsavedRecoveryKey.value && keyText != null)
        _Notice(
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
        _Line(
          key: const Key('backup-key-mismatch'),
          icon: Icons.warning_amber_rounded,
          text: l10n.backupKeyMismatch,
          warning: true,
        ),
      for (final r in s.pendingRemovals.value)
        _Notice(
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
        _Line(
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
            final ms => l10n.backupMemberLastUpload(_ago(l10n, ms)),
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
        _Line(
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

/// A row that asks for the viewer's attention, with one action.
class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.text,
    required this.action,
    this.warning = false,
  });

  final IconData icon;
  final String text;
  final Widget action;

  /// Drawn in the error colour: something is wrong until acted on.
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: warning ? error : palette.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: warning ? error : palette.textPrimary)),
          ),
          action,
        ],
      ),
    );
  }
}

/// An icon and a line of text: the unavailable copy, a warning.
class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.icon,
    required this.text,
    this.warning = false,
  });

  final IconData icon;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning
        ? Theme.of(context).colorScheme.error
        : context.palette.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(color: color))),
        ],
      ),
    );
  }
}
