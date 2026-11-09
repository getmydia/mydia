import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/p2p/peer_sync_records.dart';
import '../../../core/p2p/peer_sync_service.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/toast/toaster.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import 'widgets/settings_row.dart';
import 'widgets/settings_section.dart';

class PairedDevicesScreen extends StatelessWidget {
  const PairedDevicesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return WindowChromeInsets.removeBand(
      child: Builder(
        builder: (context) => Scaffold(
          appBar: WindowTitleBar(
            height: WindowTitleRow.heightOf(context),
            leading: const BackButton(),
            title: Text(
              context.l10n.settingsPairedDevicesTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            showCast: false,
            decorate: (row) => ColoredBox(
              color: Theme.of(context).appBarTheme.backgroundColor ??
                  Theme.of(context).colorScheme.surface,
              child: row,
            ),
          ),
          body: const PairedDevicesBody(),
        ),
      ),
    );
  }
}

class PairedDevicesBody extends ConsumerStatefulWidget {
  const PairedDevicesBody({super.key, this.padding = const EdgeInsets.all(16)});

  final EdgeInsets padding;

  @override
  ConsumerState<PairedDevicesBody> createState() => _PairedDevicesBodyState();
}

class _PairedDevicesBodyState extends ConsumerState<PairedDevicesBody> {
  final _codeController = TextEditingController();
  StreamSubscription<PeerMember>? _pairedSub;
  StreamSubscription<void>? _stateSub;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final service = ref.read(peerSyncServiceProvider);
    _pairedSub = service.onPeerPaired.listen((peer) {
      if (!mounted) return;
      showToast(
        context,
        context.l10n.pairedDevicesConnectedToast(peer.deviceName),
      );
    });
    _stateSub = service.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pairedSub?.cancel();
    _stateSub?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  IconData _platformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'macos':
        return Icons.laptop_mac;
      case 'windows':
        return Icons.desktop_windows;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
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
      _errorMessage = null;
    });
    try {
      await ref.read(peerSyncServiceProvider).startPairingOffer();
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleCancelOffer() async {
    await ref.read(peerSyncServiceProvider).cancelPairingOffer();
    if (mounted) setState(() {});
  }

  Future<void> _handleSubmitCode() async {
    final input = _codeController.text.trim();
    final cleanCode =
        input.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (cleanCode.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ref.read(peerSyncServiceProvider).pairWithCode(cleanCode);
      _codeController.clear();
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = context.l10n.pairedDevicesPairingFailed);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleScanQr() async {
    if (kIsWeb) return;
    await showModalBottomSheet<void>(
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
            final barcode = capture.barcodes.firstOrNull;
            if (barcode?.rawValue != null) {
              Navigator.of(bottomSheetContext).pop();
              _pairWithQr(barcode!.rawValue!);
            }
          },
        ),
      ),
    );
  }

  Future<void> _pairWithQr(String qrJson) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await ref.read(peerSyncServiceProvider).pairWithQr(qrJson);
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = context.l10n.pairedDevicesPairingFailed);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _confirmLeaveGroup() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.pairedDevicesLeaveGroupConfirmTitle),
        content: Text(l10n.pairedDevicesLeaveGroupConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const Key('paired-leave-group-confirm-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.pairedDevicesLeaveGroupButton),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(peerSyncServiceProvider).leaveGroup();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(peerSyncServiceProvider);
    final store = ref.watch(peerSyncStoreProvider);
    final roster = ref.watch(peerGroupRosterProvider);
    final l10n = context.l10n;
    final localNodeId = roster.localNodeId() ?? '';

    final activeOffer = service.activeOffer;
    final members = store.members().values.toList();
    final nonLocalMembers = members
        .where(
          (m) =>
              m.nodeId.toLowerCase() != localNodeId.toLowerCase() && !m.revoked,
        )
        .toList();

    final isPaired = service.isPaired || nonLocalMembers.isNotEmpty;

    return ListView(
      padding: widget.padding,
      children: [
        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Header / Intro
        if (!isPaired) ...[
          Text(
            l10n.pairedDevicesIntroTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.pairedDevicesIntroBody,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
        ],

        // Active offer section OR Show code button
        if (activeOffer != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    l10n.pairedDevicesActiveOfferInstructions,
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    key: const Key('pair-active-code'),
                    _formatCode(activeOffer.code),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    key: const Key('pair-active-qr'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.qr_code_2,
                      size: 140,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('pair-cancel-offer-button'),
                    icon: const Icon(Icons.close),
                    label: Text(l10n.pairedDevicesCancelOfferButton),
                    onPressed: _handleCancelOffer,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ] else ...[
          FilledButton.icon(
            key: const Key('pair-show-code-button'),
            icon: const Icon(Icons.share),
            label: Text(l10n.pairedDevicesShowCodeButton),
            onPressed: _isLoading ? null : _handleStartOffer,
          ),
          const SizedBox(height: 16),
        ],

        // Code input and QR scan
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('pair-code-input'),
                controller: _codeController,
                decoration: InputDecoration(
                  labelText: l10n.pairedDevicesCodeInputLabel,
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                textCapitalization: TextCapitalization.characters,
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
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('pair-scan-qr-button'),
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(l10n.pairedDevicesScanQrButton),
          onPressed: _isLoading ? null : _handleScanQr,
        ),
        const SizedBox(height: 24),

        // Paired devices list
        if (nonLocalMembers.isNotEmpty) ...[
          SettingsSection(
            label: l10n.pairedDevicesListSection,
            children: [
              for (final member in nonLocalMembers)
                SettingsRow.action(
                  key: Key('paired-device-${member.nodeId}'),
                  icon: _platformIcon(member.platform),
                  title: member.deviceName,
                  subtitle: member.revoked
                      ? l10n.pairedDevicesStatusRevoked
                      : l10n.pairedDevicesStatusActive,
                  trailing: IconButton(
                    key: Key('remove-peer-${member.nodeId}'),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l10n.pairedDevicesRemovePeerButton,
                    onPressed: () async {
                      await service.revokePeer(member.nodeId);
                      if (mounted) setState(() {});
                    },
                  ),
                  onTap: () {},
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],

        // Paired action buttons: Sync now & Leave group
        if (isPaired) ...[
          OutlinedButton.icon(
            key: const Key('paired-sync-now-button'),
            icon: const Icon(Icons.sync),
            label: Text(l10n.pairedDevicesSyncNowButton),
            onPressed: () async {
              await service.syncAll(ignoreCooldown: true);
            },
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const Key('paired-leave-group-button'),
            icon: const Icon(Icons.link_off),
            label: Text(l10n.pairedDevicesLeaveGroupButton),
            onPressed: _confirmLeaveGroup,
          ),
        ],
      ],
    );
  }
}
