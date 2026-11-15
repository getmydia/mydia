/// Asks a device that pairing offered its group's backup, while it was
/// already in its own, which one to keep.
library;

import 'package:flutter/material.dart';

import '../../../core/backup/backup_sync_service.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../../widgets/toast/toaster.dart';

/// Shows the choice and settles it on [service]. Closing the dialog without
/// picking leaves the choice pending.
Future<void> showVaultChoiceDialog(
    BuildContext context, BackupSyncService service) async {
  final l10n = context.l10n;
  final toaster = Toaster.of(context);
  final keepOffered = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => GlassDialog(
      title: Text(l10n.backupVaultChoiceTitle),
      content: Text(l10n.backupVaultChoiceBody),
      actions: [
        TextButton(
          key: const Key('backup-vault-keep-current'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.backupVaultChoiceKeepCurrent),
        ),
        FilledButton(
          key: const Key('backup-vault-switch'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.backupVaultChoiceSwitch),
        ),
      ],
    ),
  );
  if (keepOffered == null) return;
  try {
    await service.resolveVaultChoice(keepOffered: keepOffered);
  } catch (e) {
    debugPrint('[Backup] Vault choice failed: ${e.runtimeType}');
    toaster.show(l10n.backupActionFailed, kind: ToastKind.error);
  }
}
