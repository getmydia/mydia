import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_service.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/models/download.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';

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
  String? title,
  String? confirmLabel,
}) async {
  final footprint = await accountDownloadFootprint(ref, account.id);
  if (!context.mounted) return false;
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      destructive: true,
      title: Text(title ?? l10n.sourcesRemoveAccountTitle),
      content: Text(
        footprint.count == 0
            ? l10n.sourcesRemoveAccountBody(account.displayName)
            : l10n.sourcesRemoveAccountBodyWithDownloads(
                account.displayName,
                footprint.count,
                DownloadTask.formatBytes(footprint.bytes),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          key: const Key('manage-remove-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel ?? l10n.commonRemove),
        ),
      ],
    ),
  );
  return confirmed == true;
}
