import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/backup/backup_providers.dart'
    show backupControllerProvider, backupSyncServiceProvider, CloudStoreHint;
import '../../../core/p2p/peer_sync_records.dart';
import '../../../core/p2p/peer_sync_service.dart';
import '../../../core/sources/sources_providers.dart' show isWebProvider;
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../../widgets/glass/glass_sheet.dart';
import '../../widgets/toast/toaster.dart';
import '../backup/store_picker.dart' show backupStoreName;

/// Which half of pairing the sheet opens on.
enum PairSheetMode {
  /// Show this device's pairing code and QR code for another device to use.
  show,

  /// Type the code another device shows, or scan its QR code.
  enter,
}

/// Window width below which the sheet rises from the bottom instead of
/// opening as a dialog.
const double _compactWidth = 600;

/// Opens the pair device sheet: a bottom sheet on compact widths, otherwise a
/// dialog around the same content.
///
/// [onOpenBackup] is the action of the one-time "now backed up with your
/// group" notice a join can raise: it shows Backup & sync.
Future<void> showPairDeviceSheet(
  BuildContext context, {
  required PairSheetMode mode,
  VoidCallback? onOpenBackup,
}) {
  final sheet = PairDeviceSheet(mode: mode, onOpenBackup: onOpenBackup);
  if (MediaQuery.sizeOf(context).width < _compactWidth) {
    return showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => sheet,
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => GlassDialog(content: SizedBox(width: 420, child: sheet)),
  );
}

/// What failed, kept as a value and worded in `build` so the text follows the
/// language.
enum _PairingFailure { offer, pairing }

/// Whether `mobile_scanner` can scan on this platform: Android, iOS and
/// macOS. The web build cannot open the scanner and the Windows and Linux
/// ones have no camera plugin for it.
bool get qrScanSupported =>
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);

/// The offer's payload (address and claim code) as a QR code, which another
/// device scans to pair. Black on white whatever the theme, which scanners
/// need.
class PairingQrCode extends StatelessWidget {
  const PairingQrCode({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) => QrImageView(
    data: data,
    size: 160,
    backgroundColor: Colors.white,
    eyeStyle: const QrEyeStyle(color: Colors.black),
    dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
  );
}

class PairDeviceSheet extends ConsumerStatefulWidget {
  const PairDeviceSheet({super.key, required this.mode, this.onOpenBackup});

  final PairSheetMode mode;
  final VoidCallback? onOpenBackup;

  @override
  ConsumerState<PairDeviceSheet> createState() => _PairDeviceSheetState();
}

class _PairDeviceSheetState extends ConsumerState<PairDeviceSheet> {
  final _codeController = TextEditingController();
  // Held so `dispose` can cancel the offer without touching `ref`.
  late final PeerSyncService _service;
  StreamSubscription<PeerMember>? _pairedSub;
  StreamSubscription<void>? _stateSub;
  bool _isLoading = false;
  _PairingFailure? _failure;

  /// Set once the pairing is announced, so a host-side [onPeerPaired] and
  /// a joiner's own success cannot both toast.
  bool _announced = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(peerSyncServiceProvider);
    // Fires only on the side that showed the code.
    _pairedSub = _service.onPeerPaired.listen(
      (peer) => _announcePaired(peer.deviceName),
    );
    _stateSub = _service.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
    if (widget.mode == PairSheetMode.show) {
      unawaited(_handleStartOffer());
    }
  }

  @override
  void dispose() {
    _pairedSub?.cancel();
    _stateSub?.cancel();
    _codeController.dispose();
    if (_service.activeOffer != null) {
      unawaited(_service.cancelPairingOffer());
    }
    super.dispose();
  }

  /// Toasts the pairing and closes the sheet. [deviceName] is null when the
  /// other device is not in the roster yet.
  void _announcePaired(String? deviceName) {
    if (!mounted || _announced) return;
    _announced = true;
    final l10n = context.l10n;
    showToast(
      context,
      deviceName == null || deviceName.isEmpty
          ? l10n.pairedDevicesPairedToast
          : l10n.pairedDevicesConnectedToast(deviceName),
    );
    // The scanner sheet may be on top; only close this sheet's own route.
    if (ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).maybePop();
    }
  }

  /// The joining side hears no [onPeerPaired]: name the newest other member
  /// of the group it just joined.
  void _announceJoined({CloudStoreHint? hintBefore}) {
    if (!mounted) return;
    if (_announceBackupJoined()) return;
    if (_announceStoreHint(hintBefore)) return;
    final newest = ref
        .read(peerGroupRosterProvider)
        .activeMembers()
        .fold<PeerMember?>(
          null,
          (latest, m) =>
              latest == null || m.updatedAt > latest.updatedAt ? m : latest,
        );
    _announcePaired(newest?.deviceName);
  }

  /// When the join also put this device in the group's cloud backup, says
  /// so (one toast replaces the other, and this one implies the pairing),
  /// with an action to Backup & sync, and marks the notice seen. The banner
  /// in Backup & sync covers a toast that never showed.
  bool _announceBackupJoined() {
    if (ref.read(isWebProvider)) return false;
    final backup = ref.read(backupSyncServiceProvider);
    if (!backup.showJoinedNotice || _announced) return false;
    _announced = true;
    final l10n = context.l10n;
    final open = widget.onOpenBackup;
    showToast(
      context,
      l10n.backupJoinedNotice,
      kind: ToastKind.success,
      action: open == null
          ? null
          : ToastAction(label: l10n.backupJoinedNoticeOpen, onPressed: open),
    );
    backup.acknowledgeJoinedNotice();
    if (ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).maybePop();
    }
    return true;
  }

  /// The cloud store hint as it stands, null on the web.
  CloudStoreHint? _storeHint() => ref.read(isWebProvider)
      ? null
      : ref.read(backupControllerProvider).storeHint.value;

  /// When the join brought a cloud store hint (the group backs up to iCloud
  /// or Google Drive, which this device must sign in to), says where, with
  /// an action to Backup & sync. The hint stays there until answered.
  bool _announceStoreHint(CloudStoreHint? before) {
    final hint = _storeHint();
    if (hint == null || hint == before || _announced) return false;
    _announced = true;
    final l10n = context.l10n;
    final open = widget.onOpenBackup;
    showToast(
      context,
      l10n.backupStoreHint(backupStoreName(l10n, hint.kind)),
      kind: ToastKind.success,
      action: open == null
          ? null
          : ToastAction(label: l10n.backupJoinedNoticeOpen, onPressed: open),
    );
    if (ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).maybePop();
    }
    return true;
  }

  String _formatCode(String raw) {
    final clean = raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (clean.length > 3) {
      return '${clean.substring(0, 3)}-${clean.substring(3)}';
    }
    return clean;
  }

  Future<void> _handleStartOffer() async {
    setState(() {
      _isLoading = true;
      _failure = null;
    });
    try {
      final offer = await _service.startPairingOffer();
      // Closed while the offer was pending: `dispose` saw no offer to
      // cancel, so withdraw this one, unless a newer one has replaced it.
      if (!mounted && identical(_service.activeOffer, offer)) {
        unawaited(_service.cancelPairingOffer());
      }
    } catch (e) {
      debugPrint('[PairDeviceSheet] Could not start an offer: $e');
      if (mounted) setState(() => _failure = _PairingFailure.offer);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleSubmitCode() async {
    final cleanCode = _codeController.text
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toUpperCase();
    if (cleanCode.isEmpty) return;

    setState(() {
      _isLoading = true;
      _failure = null;
    });
    try {
      final hint = _storeHint();
      await _service.pairWithCode(cleanCode);
      // The viewer may have left while pairing was pending; a disposed
      // controller must not be notified.
      if (mounted) _codeController.clear();
      _announceJoined(hintBefore: hint);
    } catch (e) {
      if (mounted) setState(() => _failure = _PairingFailure.pairing);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleScanQr() async {
    if (!qrScanSupported) return;
    var detected = false;
    await showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (bottomSheetContext) => Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.pairedDevicesScanQrButton),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(bottomSheetContext).pop(),
          ),
        ),
        body: MobileScanner(
          onDetect: (capture) {
            if (detected) return;
            final barcode = capture.barcodes.firstOrNull;
            if (barcode?.rawValue != null) {
              detected = true;
              Navigator.of(bottomSheetContext).pop();
              _pairWithQr(barcode!.rawValue!);
            }
          },
        ),
      ),
    );
  }

  Future<void> _pairWithQr(String qrJson) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _failure = null;
    });
    try {
      final hint = _storeHint();
      await _service.pairWithQr(qrJson);
      _announceJoined(hintBefore: hint);
    } catch (e) {
      if (mounted) setState(() => _failure = _PairingFailure.pairing);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final offer = _service.activeOffer;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Says what kind of device this is for and which button the
            // other side needs, since "pair" alone reads as casting or
            // adding a server.
            Text(
              l10n.connectionsPairCta,
              key: const Key('pair-sheet-title'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.mode == PairSheetMode.show
                  ? l10n.pairedDevicesShowSteps
                  : l10n.pairedDevicesEnterSteps,
              key: const Key('pair-sheet-steps'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            if (_failure != null) ...[
              Container(
                key: const Key('pair-failure-banner'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(switch (_failure!) {
                  _PairingFailure.offer => l10n.pairedDevicesOfferFailed,
                  _PairingFailure.pairing => l10n.pairedDevicesPairingFailed,
                }, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.mode == PairSheetMode.show)
              ..._offerSection(context, offer)
            else
              ..._enterSection(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _offerSection(BuildContext context, ActivePairingOffer? offer) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (offer == null) {
      return [
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          FilledButton.icon(
            key: const Key('pair-show-code-button'),
            icon: const Icon(Icons.share),
            label: Text(l10n.pairedDevicesShowCodeButton),
            onPressed: _handleStartOffer,
          ),
      ];
    }
    return [
      Text(
        offer.publishedToRelay
            ? l10n.pairedDevicesActiveOfferInstructions
            : l10n.pairedDevicesQrOnlyInstructions,
        style: theme.textTheme.bodyMedium,
        textAlign: TextAlign.center,
      ),
      // A code the relay does not hold cannot be looked up, so it is shown
      // only when it was published.
      if (offer.publishedToRelay) ...[
        const SizedBox(height: 12),
        SelectableText(
          key: const Key('pair-active-code'),
          _formatCode(offer.code),
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
      ],
      const SizedBox(height: 12),
      Center(
        child: Container(
          key: const Key('pair-active-qr'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: PairingQrCode(
            key: const Key('pair-active-qr-image'),
            data: offer.qrJson,
          ),
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const Key('pair-cancel-offer-button'),
        icon: const Icon(Icons.close),
        label: Text(l10n.pairedDevicesCancelOfferButton),
        // Closing the sheet cancels the offer in `dispose`.
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    ];
  }

  List<Widget> _enterSection(BuildContext context) {
    final l10n = context.l10n;
    return [
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('pair-code-input'),
              controller: _codeController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.pairedDevicesCodeInputLabel,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              textCapitalization: TextCapitalization.characters,
              onSubmitted: (_) => _isLoading ? null : _handleSubmitCode(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('pair-submit-code-button'),
            onPressed: _isLoading ? null : _handleSubmitCode,
            child: Text(l10n.pairedDevicesSubmitCodeButton),
          ),
        ],
      ),
      if (qrScanSupported) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('pair-scan-qr-button'),
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(l10n.pairedDevicesScanQrButton),
          onPressed: _isLoading ? null : _handleScanQr,
        ),
      ],
    ];
  }
}
