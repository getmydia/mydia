import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_service.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/models/download.dart';

/// The downloads removing [accountId] deletes. Best effort: a lookup that
/// fails or times out reads as none, so the dialog still opens.
Future<({int count, int bytes})> accountDownloadFootprint(
  WidgetRef ref,
  String accountId,
) async {
  if (!isDownloadSupported) return (count: 0, bytes: 0);
  try {
    return (await ref
            .read(downloadManagerProvider.future)
            .timeout(downloadLookupTimeout))
        .accountDownloads(accountId);
  } catch (_) {
    return (count: 0, bytes: 0);
  }
}

/// Asks whether to remove [account] from this device, saying how many
/// downloads go with it. True when confirmed.
Future<bool> confirmRemoveAccount(
  BuildContext context,
  WidgetRef ref,
  ProviderAccount account, {
  String title = 'Remove this account?',
  String confirmLabel = 'Remove',
}) async {
  final footprint = await accountDownloadFootprint(ref, account.id);
  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text('${account.displayName} and its servers are '
          'removed from this device. Nothing changes on the server.'
          '${footprint.count == 0 ? '' : '\n\nThis also deletes ${footprint.count} '
              'download${footprint.count == 1 ? '' : 's'} '
              '(${DownloadTask.formatBytes(footprint.bytes)}).'}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('manage-remove-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}
