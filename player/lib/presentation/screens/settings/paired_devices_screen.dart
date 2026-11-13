import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/p2p/peer_sync_service.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../connections/connections_overview.dart';
import '../connections/pair_device_sheet.dart';
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
  StreamSubscription<void>? _stateSub;

  @override
  void initState() {
    super.initState();
    final service = ref.read(peerSyncServiceProvider);
    _stateSub = service.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _confirmLeaveGroup() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassDialog(
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

        FilledButton.icon(
          key: const Key('connections-show-code'),
          icon: const Icon(Icons.share),
          label: Text(l10n.connectionsShowCode),
          onPressed: () =>
              showPairDeviceSheet(context, mode: PairSheetMode.show),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('connections-enter-code'),
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(l10n.connectionsEnterCode),
          onPressed: () =>
              showPairDeviceSheet(context, mode: PairSheetMode.enter),
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
                  icon: connectionPlatformIcon(member.platform),
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
