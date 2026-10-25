import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'glass/glass_dialog.dart';

/// Warns that credentials were accepted but could not be saved.
///
/// Shown after a successful pairing or login when the platform's secure
/// storage rejected the writes. The session works, so this is a warning rather
/// than an error, but the user needs to know before they rely on it.
class StorageUnavailableDialog extends StatelessWidget {
  const StorageUnavailableDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return GlassDialog(
      icon: const Icon(Icons.warning_amber_rounded, size: 32),
      title: Text(l10n.storageUnavailableTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.storageUnavailableConnected),
          const SizedBox(height: 12),
          Text(
            l10n.storageUnavailableDetail,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonContinue),
        ),
      ],
    );
  }
}

/// Shows the storage warning and waits for the user to acknowledge it.
///
/// Not dismissible by tapping outside: the user is about to be taken into the
/// app, and this is the only moment they are told the connection is temporary.
Future<void> showStorageUnavailableDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const StorageUnavailableDialog(),
  );
}
