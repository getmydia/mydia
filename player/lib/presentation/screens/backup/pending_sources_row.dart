/// Accounts other devices backed up that this one does not have yet: one row
/// per device, "2 sources added on Living Room TV", with Add and Dismiss.
library;

import 'package:flutter/material.dart';

import '../../../core/backup/backup_meta_store.dart';
import '../../../core/backup/backup_sync_service.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/toast/toaster.dart';

class PendingSourcesRow extends StatelessWidget {
  const PendingSourcesRow({super.key, required this.service});

  final BackupSyncService service;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<PendingAccountOffer>>(
        valueListenable: service.pendingOffers,
        builder: (context, offers, _) {
          if (offers.isEmpty) return const SizedBox.shrink();
          final byDevice = <String, List<PendingAccountOffer>>{};
          for (final o in offers) {
            (byDevice[o.fromDevice] ??= []).add(o);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final MapEntry(key: device, value: group)
                  in byDevice.entries)
                _DeviceOffers(
                  key: Key('backup-pending-$device'),
                  service: service,
                  device: device,
                  offers: group,
                ),
            ],
          );
        },
      );
}

class _DeviceOffers extends StatefulWidget {
  const _DeviceOffers({
    super.key,
    required this.service,
    required this.device,
    required this.offers,
  });

  final BackupSyncService service;
  final String device;
  final List<PendingAccountOffer> offers;

  @override
  State<_DeviceOffers> createState() => _DeviceOffersState();
}

class _DeviceOffersState extends State<_DeviceOffers> {
  bool _busy = false;

  Future<void> _run(Future<void> Function(String accountId) op) async {
    final toaster = Toaster.of(context);
    final failed = context.l10n.backupActionFailed;
    setState(() => _busy = true);
    try {
      for (final o in widget.offers) {
        await op(o.accountId);
      }
    } catch (e) {
      debugPrint('[Backup] Pending source not handled: ${e.runtimeType}');
      toaster.show(failed, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(Icons.dns_rounded, size: 20, color: palette.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.backupPendingSources(
                      widget.offers.length, widget.device),
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: palette.textPrimary),
                ),
                Text(
                  // Account names: user data, not a sentence.
                  widget.offers.map((o) => o.displayName).join(', '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 12.5, color: palette.textSecondary),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('backup-pending-dismiss'),
            onPressed:
                _busy ? null : () => _run(widget.service.dismissPendingAccount),
            child: Text(l10n.commonDismiss),
          ),
          FilledButton.tonal(
            key: const Key('backup-pending-add'),
            onPressed:
                _busy ? null : () => _run(widget.service.acceptPendingAccount),
            child: Text(l10n.backupPendingAdd),
          ),
        ],
      ),
    );
  }
}
