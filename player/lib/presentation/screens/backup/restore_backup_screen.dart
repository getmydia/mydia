/// Restore from backup: enter or scan the recovery key, see what the backup
/// holds, then merge it into this device and join the backup.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/backup/backup_providers.dart';
import '../../../core/backup/backup_relay_client.dart';
import '../../../core/backup/recovery_key.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_sheet.dart';
import '../../widgets/toast/toaster.dart';
import '../connections/pair_device_sheet.dart' show qrScanSupported;

/// Where the restore screen lives.
const restoreBackupLocation = '/backup/restore';

/// Why the key did not lead to a preview, worded in `build`.
enum _RestoreFailure { malformed, notFound, unavailable, network, other }

class RestoreBackupScreen extends ConsumerStatefulWidget {
  const RestoreBackupScreen({super.key});

  @override
  ConsumerState<RestoreBackupScreen> createState() =>
      _RestoreBackupScreenState();
}

class _RestoreBackupScreenState extends ConsumerState<RestoreBackupScreen> {
  final _keyField = TextEditingController();
  RestorePreview? _preview;
  _RestoreFailure? _failure;
  bool _busy = false;

  @override
  void dispose() {
    _keyField.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final text = _keyField.text;
    try {
      RecoveryKey.parse(text);
    } on FormatException {
      setState(() => _failure = _RestoreFailure.malformed);
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final preview =
          await ref.read(backupSyncServiceProvider).previewRestore(text);
      if (mounted) setState(() => _preview = preview);
    } on BackupRelayException catch (e) {
      if (mounted) setState(() => _failure = _failureOf(e.kind));
    } catch (e) {
      debugPrint('[Backup] Restore preview failed: ${e.runtimeType}');
      if (mounted) setState(() => _failure = _RestoreFailure.other);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static _RestoreFailure _failureOf(BackupRelayError kind) => switch (kind) {
        BackupRelayError.notFound => _RestoreFailure.notFound,
        BackupRelayError.unavailable => _RestoreFailure.unavailable,
        BackupRelayError.network => _RestoreFailure.network,
        _ => _RestoreFailure.other,
      };

  Future<void> _restore(RestorePreview preview) async {
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    final router = GoRouter.maybeOf(context);
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref.read(backupSyncServiceProvider).commitRestore(preview);
      toaster.show(l10n.backupRestoreDone, kind: ToastKind.success);
      router?.go('/');
    } on BackupRelayException catch (e) {
      if (mounted) setState(() => _failure = _failureOf(e.kind));
    } catch (e) {
      debugPrint('[Backup] Restore failed: ${e.runtimeType}');
      if (mounted) setState(() => _failure = _RestoreFailure.other);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    var detected = false;
    await showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.backupRestoreScan),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(sheetContext).pop(),
          ),
        ),
        body: MobileScanner(
          onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (detected || value == null) return;
            detected = true;
            Navigator.of(sheetContext).pop();
            _keyField.text = value;
            _find();
          },
        ),
      ),
    );
  }

  String? _failureText(AppLocalizations l10n) => switch (_failure) {
        null => null,
        _RestoreFailure.malformed => l10n.backupRestoreMalformed,
        _RestoreFailure.notFound => l10n.backupRestoreNotFound,
        _RestoreFailure.unavailable => l10n.backupUnavailable,
        _RestoreFailure.network => l10n.backupErrorNetwork,
        _RestoreFailure.other => l10n.backupRestoreFailed,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final service = ref.watch(backupSyncServiceProvider);
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.backupRestoreTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              if (service.enabled)
                Text(l10n.backupRestoreAlreadyOn,
                    key: const Key('restore-already-on'))
              else if (preview == null)
                ..._keyEntry(l10n)
              else
                ..._summary(l10n, preview),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _keyEntry(AppLocalizations l10n) {
    // Only a key that never reached the relay is the field's own error.
    final malformed = _failure == _RestoreFailure.malformed;
    final other = malformed ? null : _failureText(l10n);
    return [
      Text(l10n.backupRestoreIntro),
      const SizedBox(height: 16),
      TextField(
        key: const Key('restore-key-field'),
        controller: _keyField,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        maxLines: 2,
        minLines: 1,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(fontFamily: 'monospace'),
        decoration: InputDecoration(
          labelText: l10n.backupRestoreKeyLabel,
          errorText: malformed ? l10n.backupRestoreMalformed : null,
          errorMaxLines: 3,
        ),
        onChanged: (_) {
          if (_failure != null) setState(() => _failure = null);
        },
        onSubmitted: (_) => _busy ? null : _find(),
      ),
      if (other != null) ...[
        const SizedBox(height: 12),
        Text(
          other,
          key: const Key('restore-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
      const SizedBox(height: 20),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (qrScanSupported)
            OutlinedButton.icon(
              key: const Key('restore-scan-button'),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(l10n.backupRestoreScan),
              onPressed: _busy ? null : _scan,
            ),
          FilledButton(
            key: const Key('restore-find-button'),
            onPressed: _busy ? null : _find,
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.backupRestoreFind),
          ),
        ],
      ),
    ];
  }

  List<Widget> _summary(AppLocalizations l10n, RestorePreview preview) {
    final palette = context.palette;
    final error = _failureText(l10n);
    return [
      Icon(Icons.cloud_done_rounded, size: 40, color: palette.primary),
      const SizedBox(height: 12),
      Text(
        l10n.backupRestoreSummary(
          preview.sources,
          preview.watchRecords,
          preview.payloads.length,
        ),
        key: const Key('restore-summary'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (preview.deviceNames.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          // Device names: user data, not a sentence.
          preview.deviceNames.join(', '),
          key: const Key('restore-devices'),
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.textSecondary),
        ),
      ],
      if (preview.unreadableSlots.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
          l10n.backupRestoreUnreadableCount(preview.unreadableSlots.length),
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.textSecondary),
        ),
      ],
      const SizedBox(height: 16),
      Text(l10n.backupRestoreMergeNote, textAlign: TextAlign.center),
      if (error != null) ...[
        const SizedBox(height: 12),
        Text(
          error,
          key: const Key('restore-error'),
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
      const SizedBox(height: 20),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        children: [
          TextButton(
            key: const Key('restore-back-button'),
            onPressed: _busy
                ? null
                : () => setState(() {
                      _preview = null;
                      _failure = null;
                    }),
            child: Text(l10n.commonBack),
          ),
          FilledButton(
            key: const Key('restore-confirm-button'),
            autofocus: true,
            onPressed: _busy ? null : () => _restore(preview),
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.backupRestoreConfirm),
          ),
        ],
      ),
    ];
  }
}

/// The way into [RestoreBackupScreen] on the add-server and sign-in screens.
/// Native only: the web player has no cloud backup.
class RestoreFromBackupButton extends StatelessWidget {
  const RestoreFromBackupButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return TextButton.icon(
      key: const Key('restore-from-backup'),
      onPressed: () => context.push(restoreBackupLocation),
      icon: const Icon(Icons.settings_backup_restore_rounded),
      label: Text(context.l10n.backupRestoreTitle),
    );
  }
}
