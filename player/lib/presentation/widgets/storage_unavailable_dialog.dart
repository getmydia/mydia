import 'package:flutter/material.dart';

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

    return AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, size: 32),
      title: const Text('Connection could not be saved'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'You are connected and can keep using the app, but this '
            'connection may be lost when you close it.',
          ),
          const SizedBox(height: 12),
          Text(
            'Mydia could not save your credentials because this system\'s '
            'secure storage rejected them. On Linux that usually means either '
            'no keyring service is running, or the app is sandboxed without '
            'permission to reach it.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Continue'),
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
