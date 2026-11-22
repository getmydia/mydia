/// Restore from backup: pick where the backup lives (iCloud, Google Drive,
/// or the relay with its recovery key), see what it holds, then merge it
/// into this device and join it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/backup/backup_providers.dart';
import '../../../core/backup/backup_records.dart';
import '../../../core/backup/backup_relay_client.dart';
import '../../../core/backup/cloud/cloud_backup_service.dart';
import '../../../core/backup/recovery_key.dart';
import '../../../core/player/platform_features.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_sheet.dart';
import '../../widgets/toast/toaster.dart';
import '../connections/pair_device_sheet.dart' show qrScanSupported;
import 'google_device_code_sheet.dart';
import 'store_picker.dart';

/// Where the restore screen lives.
const restoreBackupLocation = '/backup/restore';

/// Whether this device can back up to iCloud at all: iOS and macOS.
final Provider<bool> appleBackupPlatformProvider = Provider<bool>(
  (_) => !kIsWeb && (PlatformFeatures.isIOS || PlatformFeatures.isMacOS),
);

/// Whether iCloud holds a backup this device could restore, asked once per
/// app run and given up on after 5 s. Never asked off Apple platforms, or
/// where this build has no iCloud.
final FutureProvider<bool> iCloudRestoreAvailableProvider =
    FutureProvider<bool>((ref) async {
      if (!ref.watch(appleBackupPlatformProvider)) return false;
      final controller = ref.read(backupControllerProvider);
      Future<bool> probe() async {
        await controller.ready;
        if (!controller.offered.value.contains(BackupStoreKind.icloud) ||
            controller.active.value != null) {
          return false;
        }
        final preview = await controller
            .cloud(BackupStoreKind.icloud)
            .previewRestore();
        return preview.payloads.isNotEmpty;
      }

      try {
        return await probe().timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('[Backup] No iCloud backup to offer: ${e.runtimeType}');
        return false;
      }
    });

/// Why a restore did not lead to a preview, worded in `build`.
enum _RestoreFailure {
  malformed,
  notFound,
  unavailable,
  iCloudUnavailable,
  network,
  alreadyOn,
  other,
}

class RestoreBackupScreen extends ConsumerStatefulWidget {
  const RestoreBackupScreen({super.key, this.initialStore});

  /// A cloud store to open straight on, as the sign-in screen's "Restore
  /// from iCloud" does.
  final BackupStoreKind? initialStore;

  @override
  ConsumerState<RestoreBackupScreen> createState() =>
      _RestoreBackupScreenState();
}

class _RestoreBackupScreenState extends ConsumerState<RestoreBackupScreen> {
  late final BackupController _controller;
  final _keyField = TextEditingController();

  /// The store being restored from; null while choosing one.
  BackupStoreKind? _source;
  RestorePreview? _preview;
  CloudRestorePreview? _cloudPreview;
  _RestoreFailure? _failure;
  bool _busy = false;
  int _opToken = 0;

  /// The cloud stores this device offers, in picker order.
  List<BackupStoreKind> get _clouds => [
    for (final k in BackupStoreKind.values)
      if (k != BackupStoreKind.relay && _controller.offered.value.contains(k))
        k,
  ];

  @override
  void initState() {
    super.initState();
    _controller = ref.read(backupControllerProvider);
    final initial = widget.initialStore;
    if (initial != null && initial != BackupStoreKind.relay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_findCloud(initial));
      });
    }
  }

  @override
  void dispose() {
    _keyField.dispose();
    super.dispose();
  }

  /// With only the relay offered there is nothing to choose: the key entry.
  BackupStoreKind? get _shownSource =>
      _source ?? (_clouds.isEmpty ? BackupStoreKind.relay : null);

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
      final preview = await _controller.relay.previewRestore(text);
      if (mounted) setState(() => _preview = preview);
    } on BackupRelayException catch (e) {
      if (mounted) setState(() => _failure = _failureOf(e.kind, null));
    } catch (e) {
      debugPrint('[Backup] Restore preview failed: ${e.runtimeType}');
      if (mounted) setState(() => _failure = _RestoreFailure.other);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reads the backup in the cloud store [kind], signing in to Google
  /// first when needed.
  Future<void> _findCloud(BackupStoreKind kind) async {
    if (_busy) return;
    final token = ++_opToken;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      if (kind == BackupStoreKind.gdrive &&
          !await signInToGoogle(
            context,
            ref.read(googleSignInMethodProvider),
          )) {
        return;
      }
      if (!mounted || _opToken != token) return;
      await _controller.ready;
      if (!mounted || _opToken != token) return;
      final preview = await _controller.cloud(kind).previewRestore();
      if (!mounted || _opToken != token) return;
      setState(() {
        _source = kind;
        _cloudPreview = preview;
      });
    } on BackupRelayException catch (e) {
      if (mounted && _opToken == token) {
        setState(() => _failure = _failureOf(e.kind, kind));
      }
    } catch (e) {
      debugPrint('[Backup] Cloud restore preview failed: ${e.runtimeType}');
      if (mounted && _opToken == token) {
        setState(() => _failure = _RestoreFailure.other);
      }
    } finally {
      if (mounted && _opToken == token) setState(() => _busy = false);
    }
  }

  static _RestoreFailure _failureOf(
    BackupRelayError kind,
    BackupStoreKind? store,
  ) => switch (kind) {
    BackupRelayError.notFound => _RestoreFailure.notFound,
    BackupRelayError.unavailable => _RestoreFailure.unavailable,
    BackupRelayError.network => _RestoreFailure.network,
    BackupRelayError.cloudUnavailable || BackupRelayError.signedOut
        when store == BackupStoreKind.icloud =>
      _RestoreFailure.iCloudUnavailable,
    _ => _RestoreFailure.other,
  };

  /// Applies the shown preview: the relay's or the cloud store's.
  Future<void> _restore() async {
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    final router = GoRouter.maybeOf(context);
    final source = _shownSource;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final relayPreview = _preview;
      final cloudPreview = _cloudPreview;
      if (source == BackupStoreKind.relay && relayPreview != null) {
        await _controller.relay.commitRestore(relayPreview);
      } else if (source != null && cloudPreview != null) {
        await _controller.cloud(source).commitRestore(cloudPreview);
      } else {
        return;
      }
      toaster.show(l10n.backupRestoreDone, kind: ToastKind.success);
      router?.go('/');
    } on BackupAlreadyOnException {
      if (mounted) setState(() => _failure = _RestoreFailure.alreadyOn);
    } on BackupRelayException catch (e) {
      if (mounted) setState(() => _failure = _failureOf(e.kind, source));
    } catch (e) {
      debugPrint('[Backup] Restore failed: ${e.runtimeType}');
      if (mounted) setState(() => _failure = _RestoreFailure.other);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() => setState(() {
    _opToken++;
    _busy = false;
    _preview = null;
    _cloudPreview = null;
    _failure = null;
    _source = null;
  });

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
    _RestoreFailure.iCloudUnavailable => l10n.backupICloudUnavailable,
    _RestoreFailure.network => l10n.backupErrorNetwork,
    _RestoreFailure.alreadyOn => l10n.backupRestoreAlreadyOn,
    _RestoreFailure.other => l10n.backupRestoreFailed,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final relay = _controller.relay;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.backupRestoreTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          // Backup can turn on while this screen is up (pairing joins the
          // group's vault): the status change brings up the explanation.
          child: ListenableBuilder(
            listenable: Listenable.merge([
              relay.status,
              _controller.active,
              _controller.offered,
            ]),
            builder: (context, _) {
              final relayPreview = _preview;
              final cloudPreview = _cloudPreview;
              final source = _shownSource;
              return ListView(
                padding: const EdgeInsets.all(24),
                shrinkWrap: true,
                children: [
                  if (relay.enabled || _controller.active.value != null)
                    Text(
                      l10n.backupRestoreAlreadyOn,
                      key: const Key('restore-already-on'),
                    )
                  else if (source == null)
                    ..._entries(l10n)
                  else if (source == BackupStoreKind.relay &&
                      relayPreview != null)
                    RestorePreviewBody(
                      records: relayPreview.records,
                      unreadable: relayPreview.unreadableSlots.length,
                      deviceNames: relayPreview.deviceNames,
                      busy: _busy,
                      error: _failureText(l10n),
                      onBack: _back,
                      onRestore: _restore,
                    )
                  else if (source != BackupStoreKind.relay &&
                      cloudPreview != null)
                    RestorePreviewBody(
                      records: cloudPreview.records,
                      unreadable: cloudPreview.unreadableSlots.length,
                      deviceNames: cloudPreview.deviceNames,
                      busy: _busy,
                      error: _failureText(l10n),
                      onBack: _back,
                      onRestore: _restore,
                    )
                  else
                    ..._keyEntry(l10n),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// One way in per store this device offers, the recovery key last.
  List<Widget> _entries(AppLocalizations l10n) {
    final error = _failureText(l10n);
    Widget entry(
      Key key,
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool first = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton.icon(
        key: key,
        autofocus: first,
        icon: Icon(icon),
        label: Text(label),
        onPressed: _busy ? null : onTap,
      ),
    );
    final clouds = _clouds;
    return [
      for (final kind in clouds)
        entry(
          Key('restore-entry-${kind.name}'),
          backupStoreIcon(kind),
          kind == BackupStoreKind.icloud
              ? l10n.restoreFromICloud
              : l10n.restoreFromGoogleDrive,
          () => _findCloud(kind),
          first: kind == clouds.first,
        ),
      entry(
        const Key('restore-entry-key'),
        Icons.key_rounded,
        l10n.restoreWithRecoveryKey,
        () => setState(() {
          _source = BackupStoreKind.relay;
          _failure = null;
        }),
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (error != null) ...[
        const SizedBox(height: 12),
        Text(
          error,
          key: const Key('restore-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    ];
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
          if (_clouds.isNotEmpty)
            TextButton(
              key: const Key('restore-key-back'),
              onPressed: _busy ? null : _back,
              child: Text(l10n.commonBack),
            ),
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
}

/// What a backup holds before it is restored: the relay's and a cloud
/// store's alike. When no device's part could be read there is nothing to
/// apply, so Restore is not offered.
class RestorePreviewBody extends StatelessWidget {
  const RestorePreviewBody({
    super.key,
    required this.records,
    required this.unreadable,
    required this.deviceNames,
    required this.busy,
    required this.onBack,
    required this.onRestore,
    this.error,
  });

  /// Every readable device's records, merged.
  final List<BackupRecord> records;

  /// How many devices' parts could not be read.
  final int unreadable;

  /// The devices whose parts were read.
  final List<String> deviceNames;

  final bool busy;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final error = this.error;
    final sources = records
        .whereType<AccountBackupRecord>()
        .where((r) => !r.deleted)
        .length;
    final watched = records
        .whereType<WatchBackupRecord>()
        .where((r) => !r.deleted)
        .length;
    // No device's part could be read (all unreadable or gone). A device
    // read with no records still has a backup to join.
    final nothing = records.isEmpty && deviceNames.isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          nothing ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
          size: 40,
          color: palette.primary,
        ),
        const SizedBox(height: 12),
        Text(
          l10n.backupRestoreSummary(sources, watched, deviceNames.length),
          key: const Key('restore-summary'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (deviceNames.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            // Device names: user data, not a sentence.
            deviceNames.join(', '),
            key: const Key('restore-devices'),
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.textSecondary),
          ),
        ],
        if (unreadable > 0) ...[
          const SizedBox(height: 12),
          Text(
            l10n.backupRestoreUnreadableCount(unreadable),
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.textSecondary),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          nothing ? l10n.restoreNothingToApply : l10n.backupRestoreMergeNote,
          key: nothing ? const Key('restore-nothing') : null,
          textAlign: TextAlign.center,
        ),
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
            // Focus starts on Back: a stray OK press on a TV remote must not
            // restore.
            TextButton(
              key: const Key('restore-back-button'),
              autofocus: true,
              onPressed: busy ? null : onBack,
              child: Text(l10n.commonBack),
            ),
            if (!nothing)
              FilledButton(
                key: const Key('restore-confirm-button'),
                onPressed: busy ? null : onRestore,
                child: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.backupRestoreConfirm),
              ),
          ],
        ),
      ],
    );
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

/// On iOS and macOS, a direct way to the iCloud backup when iCloud holds
/// one ([iCloudRestoreAvailableProvider]); nothing otherwise.
class RestoreFromICloudButton extends ConsumerWidget {
  const RestoreFromICloudButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(iCloudRestoreAvailableProvider).value != true) {
      return const SizedBox.shrink();
    }
    return TextButton.icon(
      key: const Key('restore-from-icloud'),
      onPressed: () => context.push(
        Uri(
          path: restoreBackupLocation,
          queryParameters: {'store': BackupStoreKind.icloud.name},
        ).toString(),
      ),
      icon: const Icon(Icons.cloud_download_rounded),
      label: Text(context.l10n.restoreFromICloud),
    );
  }
}
