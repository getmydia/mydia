/// The backup stores this device offers, each with who can read it: picked
/// to turn backup on, or to move it somewhere else.
library;

import 'package:flutter/material.dart';

import '../../../core/backup/backup_providers.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';

/// The store's name, as the picker and every message naming it show it.
String backupStoreName(AppLocalizations l10n, BackupStoreKind kind) =>
    switch (kind) {
      BackupStoreKind.relay => l10n.backupStoreRelay,
      BackupStoreKind.icloud => l10n.backupStoreICloud,
      BackupStoreKind.gdrive => l10n.backupStoreGoogleDrive,
    };

/// Who can read a backup kept in [kind].
String backupStorePrivacy(AppLocalizations l10n, BackupStoreKind kind) =>
    switch (kind) {
      BackupStoreKind.relay => l10n.backupStoreRelayPrivacy,
      BackupStoreKind.icloud => l10n.backupStoreICloudPrivacy,
      BackupStoreKind.gdrive => l10n.backupStoreGoogleDrivePrivacy,
    };

IconData backupStoreIcon(BackupStoreKind kind) => switch (kind) {
  BackupStoreKind.relay => Icons.lock_rounded,
  BackupStoreKind.icloud => Icons.cloud_rounded,
  BackupStoreKind.gdrive => Icons.add_to_drive_rounded,
};

/// One row per store in [stores], in the order relay, iCloud, Google
/// Drive. Tapping one calls [onPick]; nothing is tappable while [enabled]
/// is false.
class StorePicker extends StatelessWidget {
  const StorePicker({
    super.key,
    required this.stores,
    required this.onPick,
    this.enabled = true,
  });

  final Set<BackupStoreKind> stores;
  final ValueChanged<BackupStoreKind> onPick;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final kind in BackupStoreKind.values)
          if (stores.contains(kind))
            ListTile(
              key: Key('backup-store-${kind.name}'),
              leading: Icon(backupStoreIcon(kind), color: palette.primary),
              title: Text(backupStoreName(l10n, kind)),
              subtitle: Text(backupStorePrivacy(l10n, kind)),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: enabled,
              onTap: () => onPick(kind),
            ),
      ],
    );
  }
}
