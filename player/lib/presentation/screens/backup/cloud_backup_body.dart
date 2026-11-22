/// Backup & sync while backup is on in iCloud or Google Drive: the switch
/// and status and pending sources, with the devices in the store, moving
/// and deleting the backup under Manage backup. There is no recovery key:
/// the account is the membership.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/backup/backup_providers.dart';
import '../../../core/backup/backup_relay_client.dart';
import '../../../core/backup/cloud/cloud_backup_service.dart';
import '../../../core/backup/slot_transport.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../../widgets/toast/toaster.dart';
import '../connections/connections_hub_cards.dart' show HubChip;
import 'backup_manage_disclosure.dart';
import 'google_device_code_sheet.dart';
import 'pending_sources_row.dart';
import 'store_picker.dart';

/// Where a Google account's access granted to apps is removed.
final Uri googleConnectionsUrl = Uri.parse(
  'https://myaccount.google.com/connections',
);

/// Asks before a destructive backup action. True when confirmed. [extra]
/// goes under [body].
Future<bool> showBackupConfirm(
  BuildContext context, {
  String? title,
  required String body,
  required String action,
  required Key key,
  Widget? extra,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => GlassDialog(
      destructive: true,
      title: title == null ? null : Text(title),
      content: extra == null
          ? Text(body)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(body), const SizedBox(height: 12), extra],
            ),
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

/// What a failed cloud store operation tells the viewer: how to fix an
/// unusable iCloud, else that it did not work.
String cloudFailureText(
  AppLocalizations l10n,
  BackupStoreKind kind,
  Object error,
) => switch (error) {
  BackupRelayException(
    kind: BackupRelayError.cloudUnavailable || BackupRelayError.signedOut,
  )
      when kind == BackupStoreKind.icloud =>
    l10n.backupICloudUnavailable,
  _ => l10n.backupActionFailed,
};

/// The relative time of [ms] since the epoch, "3 minutes ago".
String backupAgo(AppLocalizations l10n, int ms) =>
    l10n.relativeTime(DateTime.fromMillisecondsSinceEpoch(ms));

class CloudBackupBody extends ConsumerStatefulWidget {
  const CloudBackupBody({
    super.key,
    required this.kind,
    required this.service,
    this.move,
  });

  /// iCloud or Google Drive.
  final BackupStoreKind kind;
  final CloudBackupService service;

  /// The other stores to move the backup to, shown under Manage backup;
  /// null when there are none.
  final Widget? move;

  @override
  ConsumerState<CloudBackupBody> createState() => _CloudBackupBodyState();
}

class _CloudBackupBodyState extends ConsumerState<CloudBackupBody> {
  bool _busy = false;

  CloudBackupService get _s => widget.service;
  String get _store => backupStoreName(context.l10n, widget.kind);

  /// Runs [op], toasting a failure.
  Future<bool> _run(Future<void> Function() op) async {
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      await op();
      return true;
    } catch (e) {
      debugPrint('[Backup] Cloud action failed: ${e.runtimeType}');
      toaster.show(
        cloudFailureText(l10n, widget.kind, e),
        kind: ToastKind.error,
      );
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    final l10n = context.l10n;
    if (await showBackupConfirm(
      context,
      title: l10n.backupTurnOffTitle,
      body: l10n.backupTurnOffBody,
      action: l10n.backupTurnOff,
      key: const Key('backup-turn-off-confirm'),
    )) {
      await _run(_s.disable);
    }
  }

  /// Signs in again where that is ours to do (Google), then lifts the
  /// pause. iCloud is signed in to in the system Settings.
  Future<void> _reconnect() async {
    if (widget.kind == BackupStoreKind.gdrive) {
      final method = ref.read(googleSignInMethodProvider);
      if (!await signInToGoogle(context, method, force: true)) return;
      if (!mounted) return;
    }
    await _run(_s.reconnect);
  }

  Future<void> _remove(String slotId, String name) async {
    final l10n = context.l10n;
    if (!await showBackupConfirm(
      context,
      body: l10n.backupRemoveCloudDeviceConfirm(name, _store),
      action: l10n.commonRemove,
      key: const Key('backup-remove-member-confirm'),
      extra: widget.kind == BackupStoreKind.gdrive
          ? TextButton.icon(
              key: const Key('backup-google-connections'),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(l10n.backupGoogleConnectionsLink),
              onPressed: () => unawaited(
                launchUrl(
                  googleConnectionsUrl,
                  mode: LaunchMode.externalApplication,
                ),
              ),
            )
          : null,
    )) {
      return;
    }
    await _run(() => _s.removeDevice(slotId));
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    if (await showBackupConfirm(
      context,
      title: l10n.backupDeleteConfirmTitle,
      body: l10n.backupCloudDeleteConfirm(_store),
      action: l10n.backupDelete,
      key: const Key('backup-delete-confirm'),
    )) {
      await _run(_s.deleteBackup);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _s.status,
        _s.accountLabel,
        _s.unreadableSlots,
        _s.slots,
      ]),
      builder: (context, _) {
        final status = _s.status.value;
        final names = _s.slotDeviceNames;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('backup-switch'),
              value: true,
              onChanged: _busy ? null : (_) => _turnOff(),
              title: Text(l10n.backupSwitchLabel),
              subtitle: _status(l10n, status),
            ),
            if (status case BackupError(kind: BackupRelayError.signedOut))
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: TextButton.icon(
                    key: const Key('backup-reconnect'),
                    icon: const Icon(Icons.login_rounded, size: 18),
                    label: Text(l10n.backupReconnect),
                    onPressed: _busy ? null : _reconnect,
                  ),
                ),
              ),
            for (final slot in _s.unreadableSlots.value)
              BackupLine(
                key: Key('backup-unreadable-$slot'),
                icon: Icons.error_outline_rounded,
                text: l10n.backupUnreadable(
                  names[slot] ?? l10n.backupUnknownDevice,
                ),
                warning: true,
              ),
            PendingSourcesRow.cloud(service: _s),
            BackupManageDisclosure(
              deviceCount: _s.slots.value.length,
              children: [
                for (final slot in _s.slots.value) _device(l10n, slot, names),
                ?widget.move,
                const Divider(height: 20),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      key: const Key('backup-delete'),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: Text(l10n.backupDelete),
                      onPressed: _busy ? null : _delete,
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _device(
    AppLocalizations l10n,
    SlotInfo slot,
    Map<String, String> names,
  ) {
    final own = slot.slotId == _s.ownSlotId;
    final name =
        names[slot.slotId] ??
        slot.deviceName ??
        (own ? l10n.backupThisDevice : l10n.backupUnknownDevice);
    return ListTile(
      key: Key('backup-cloud-device-${slot.slotId}'),
      dense: true,
      leading: Icon(
        own ? Icons.smartphone_rounded : Icons.devices_other_rounded,
      ),
      title: Text(name),
      subtitle: Text(switch (slot.updatedAtMs) {
        null => l10n.backupStatusNever,
        final ms => l10n.backupMemberLastUpload(backupAgo(l10n, ms)),
      }),
      trailing: own
          ? (name == l10n.backupThisDevice
                ? null
                : HubChip(label: l10n.backupThisDevice))
          : IconButton(
              key: Key('backup-cloud-device-remove-${slot.slotId}'),
              tooltip: l10n.commonRemove,
              icon: const Icon(Icons.remove_circle_outline_rounded),
              onPressed: _busy ? null : () => _remove(slot.slotId, name),
            ),
    );
  }

  /// Where the backup goes, then how it went: an error keeps the last
  /// success in view.
  Widget? _status(AppLocalizations l10n, BackupStatus status) {
    final account = _s.accountLabel.value;
    final where = account == null
        ? l10n.backupCloudActiveNoAccount(_store)
        : l10n.backupCloudActive(_store, account);
    String last(int? ms) => ms == null
        ? l10n.backupStatusNever
        : l10n.backupStatusLastBackedUp(backupAgo(l10n, ms));
    final icloud = widget.kind == BackupStoreKind.icloud;
    final lines = switch (status) {
      BackupOff() || BackupUnavailable() || BackupRemoved() => const <String>[],
      BackupIdle(:final lastSuccessMs) => [where, last(lastSuccessMs)],
      BackupUploading() => [where, l10n.backupStatusUploading],
      BackupError(kind: BackupRelayError.signedOut) => [
        l10n.backupSignedOut(_store),
      ],
      BackupError(kind: BackupRelayError.quotaFull) when !icloud => [
        l10n.backupQuotaFull,
      ],
      BackupError(kind: BackupRelayError.cloudUnavailable) when icloud => [
        l10n.backupICloudUnavailable,
      ],
      BackupError(:final kind, :final lastSuccessMs) => [
        switch (kind) {
          BackupRelayError.network => l10n.backupErrorNetwork,
          BackupRelayError.rateLimited => l10n.backupErrorRateLimited,
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
}

/// A row that asks for the viewer's attention, with an action.
class BackupNotice extends StatelessWidget {
  const BackupNotice({
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
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: warning ? error : palette.textPrimary,
              ),
            ),
          ),
          action,
        ],
      ),
    );
  }
}

/// An icon and a line of text: the unavailable copy, a warning.
class BackupLine extends StatelessWidget {
  const BackupLine({
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
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}
