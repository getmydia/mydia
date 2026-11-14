/// The Servers & devices hub: this device, every saved server, every paired
/// device, and the ways to add more of either.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/p2p/peer_sync_service.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../settings/settings_nav.dart';
import '../sources/source_lock_sheet.dart' show ShowHiddenSourcesRow;
import 'account_detail_page.dart' show AddServerButton;
import 'connections_constellation_card.dart';
import 'connections_hub_cards.dart';
import 'connections_overview.dart';
import 'connections_route_scaffold.dart';
import 'pair_device_sheet.dart';

/// Past this the cards stop stretching and the column centres.
const double _maxWidth = 720;
const double _sectionGap = 28;
const double _cardGap = 10;

/// The hub's content without a `Scaffold`: the phone route and the desktop
/// settings dialog both host it.
class ConnectionsHubBody extends ConsumerStatefulWidget {
  const ConnectionsHubBody({
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.initialSection,
    this.wideHeader = false,
  });

  final EdgeInsets padding;

  /// `'devices'` scrolls the paired devices into view once laid out.
  final String? initialSection;

  /// Head the hub with the wide constellation instead of the This device
  /// card, as the desktop dialog does.
  final bool wideHeader;

  @override
  ConsumerState<ConnectionsHubBody> createState() => _ConnectionsHubBodyState();
}

class _ConnectionsHubBodyState extends ConsumerState<ConnectionsHubBody> {
  final _devicesKey = GlobalKey();

  /// A devices scroll asked for while the servers were still loading: their
  /// cards arrive later and push the devices back down, so it runs again
  /// once they have.
  bool _rescrollWhenLoaded = false;

  @override
  void initState() {
    super.initState();
    _requestSection(widget.initialSection);
  }

  /// The desktop dialog keeps the hub mounted and asks for a section again
  /// each time Paired devices is opened.
  @override
  void didUpdateWidget(ConnectionsHubBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSection != oldWidget.initialSection) {
      _requestSection(widget.initialSection);
    }
  }

  void _requestSection(String? section) {
    if (section != 'devices') return;
    _rescrollWhenLoaded = ref.read(connectionsOverviewProvider).serversLoading;
    _scrollToDevicesAfterFrame();
  }

  void _scrollToDevicesAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _devicesKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _confirmLeaveGroup() async {
    final l10n = context.l10n;
    // Taken before the dialog: the hub can unmount while it is open, and a
    // confirmed leave must still reach the service.
    final service = ref.read(peerSyncServiceProvider);
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
      await service.leaveGroup();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      connectionsOverviewProvider.select((o) => o.serversLoading),
      (was, loading) {
        if (was == true && !loading && _rescrollWhenLoaded) {
          _rescrollWhenLoaded = false;
          _scrollToDevicesAfterFrame();
        }
      },
    );
    final overview = ref.watch(connectionsOverviewProvider);
    final nav = SettingsNavScope.of(context);
    final showServers = !kIsWeb;

    return SingleChildScrollView(
      padding: widget.padding,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A failed read leaves the wide card with nothing to draw, so the
              // pane keeps a heading through the This device card.
              if (widget.wideHeader && !overview.serversFailed)
                // Already on the hub: the card only draws, it opens nothing.
                const ConnectionsConstellationCard(
                    wide: true, interactive: false)
              else
                _ThisDeviceCard(overview: overview, showServers: showServers),
              if (showServers) ...[
                const SizedBox(height: _sectionGap),
                _ServersSection(
                  overview: overview,
                  onAdd: () => nav.addServer(),
                  onAddMydia: () => nav.addServer(kind: SourceKind.mydia),
                  // Every kind, Mydia included: the account page holds the
                  // lock, All servers and reauth controls, and its gear
                  // reaches a Mydia instance's own settings.
                  onOpen: (s) => nav.openAccount(s.account.id),
                ),
              ],
              const SizedBox(height: _sectionGap),
              Column(
                key: _devicesKey,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (overview.devices.isNotEmpty) ...[
                    _DevicesSection(
                      devices: overview.devices,
                      onRemove: (d) => ref
                          .read(peerSyncServiceProvider)
                          .revokePeer(d.nodeId),
                    ),
                    const SizedBox(height: 16),
                  ],
                  HubPairCta(
                    key: const Key('connections-pair-cta'),
                    onShowCode: () =>
                        showPairDeviceSheet(context, mode: PairSheetMode.show),
                    onEnterCode: () =>
                        showPairDeviceSheet(context, mode: PairSheetMode.enter),
                  ),
                ],
              ),
              if (overview.isPaired) ...[
                const SizedBox(height: 12),
                _SyncFooter(onLeave: _confirmLeaveGroup),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A `Scaffold` around [ConnectionsHubBody], for the phone and TV route.
class ConnectionsHubScreen extends StatelessWidget {
  const ConnectionsHubScreen({super.key, this.initialSection});

  final String? initialSection;

  @override
  Widget build(BuildContext context) => ConnectionsRouteScaffold(
        title: context.l10n.connectionsTitle,
        body: ConnectionsHubBody(initialSection: initialSection),
      );
}

/// This device: its glyph in the primary ring, its name, and how it is doing.
class _ThisDeviceCard extends StatelessWidget {
  const _ThisDeviceCard({required this.overview, required this.showServers});

  final ConnectionsOverview overview;
  final bool showServers;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final total = overview.servers.length;
    final lastSync = overview.devices
        .map((d) => d.lastSyncedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(null,
            (latest, t) => latest == null || t.isAfter(latest) ? t : latest);
    final reach = showServers && !overview.serversLoading && total > 0;
    final ago = lastSync == null ? null : l10n.relativeTime(lastSync);
    final status = switch ((reach, ago)) {
      (true, final String ago) =>
        l10n.connectionsThisDeviceStatus(overview.onlineCount, total, ago),
      (true, null) => l10n.connectionsReaching(overview.onlineCount, total),
      (false, final String ago) => l10n.connectionsThisDeviceSynced(ago),
      (false, null) => '',
    };

    return HubCardSurface(
      key: const Key('connections-this-device'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 56,
            child: ThisDeviceNode(platform: overview.localPlatform),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.connectionsThisDevice,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: palette.textDisabled,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  overview.localName.isEmpty
                      ? l10n.connectionsThisDevice
                      : overview.localName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.24,
                    color: palette.textPrimary,
                  ),
                ),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    status,
                    style:
                        TextStyle(fontSize: 12.5, color: palette.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// An eyebrow title with an optional hint below and action at the end.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.hint, this.action});

  final String title;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final hintText = hint;
    final trailing = action;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: palette.textDisabled,
                  ),
                ),
                if (hintText != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    hintText,
                    style:
                        TextStyle(fontSize: 12.5, color: palette.textSecondary),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}

/// Mydia servers first, as the recommended way to use the player, then every
/// other kind. While loading or after a failed read there is nothing to
/// split, so one Servers header carries the spinner or the error.
class _ServersSection extends ConsumerWidget {
  const _ServersSection({
    required this.overview,
    required this.onAdd,
    required this.onAddMydia,
    required this.onOpen,
  });

  final ConnectionsOverview overview;
  final VoidCallback onAdd;
  final VoidCallback onAddMydia;
  final ValueChanged<ConnectionServer> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final direct = ref.watch(connectionsDirectSourceProvider);

    Widget cards(Iterable<ConnectionServer> servers) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, server) in servers.indexed) ...[
              if (i > 0) const SizedBox(height: _cardGap),
              HubServerCard(
                key: Key('connections-server-${server.account.id}'),
                server: server,
                // Any profile of the account may be the one reached
                // directly, not only the owner's.
                direct: server.kind == SourceKind.mydia &&
                    direct != null &&
                    server.record.sources.any((s) => s.id == direct),
                onTap: () => onOpen(server),
              ),
            ],
          ],
        );

    final List<Widget> sections;
    if (overview.serversLoading || overview.serversFailed) {
      sections = [
        _SectionHeader(
          title: l10n.settingsServers,
          action: AddServerButton(onPressed: onAdd),
        ),
        _unknownBody(context),
      ];
    } else {
      final mydia =
          overview.servers.where((s) => s.kind == SourceKind.mydia).toList();
      final others =
          overview.servers.where((s) => s.kind != SourceKind.mydia).toList();
      // One Add button: on Other servers when that section shows, otherwise
      // on the Mydia header so a Plex or Jellyfin add stays reachable.
      final addButton = AddServerButton(onPressed: onAdd);
      sections = [
        Column(
          key: const Key('connections-mydia-servers-section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              title: l10n.connectionsMydiaServers,
              hint: l10n.connectionsMydiaServersHint,
              action: others.isEmpty ? addButton : null,
            ),
            if (mydia.isEmpty)
              HubAddServerGhost(
                key: const Key('connections-add-mydia-ghost'),
                label: l10n.connectionsAddMydiaServerGhost,
                onTap: onAddMydia,
              )
            else
              cards(mydia),
          ],
        ),
        if (others.isNotEmpty) ...[
          const SizedBox(height: _sectionGap),
          Column(
            key: const Key('connections-other-servers-section'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionHeader(
                title: l10n.connectionsOtherServers,
                action: addButton,
              ),
              cards(others),
            ],
          ),
        ],
      ];
    }
    return Column(
      key: const Key('connections-servers-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...sections,
        // "Show hidden servers" while locked, "Lock now" while open, in every
        // state, so it says nothing about whether anything is hidden.
        const SizedBox(height: 4),
        const ShowHiddenSourcesRow(),
      ],
    );
  }

  /// The servers are not known yet, or could not be read.
  Widget _unknownBody(BuildContext context) {
    if (overview.serversLoading) {
      // Nothing is known yet: no ghost inviting a returning user to add the
      // servers they already have.
      return const Padding(
        key: Key('connections-servers-loading'),
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    // The read failed, not the user's setup: an add invitation here would
    // suggest their servers are gone.
    return Padding(
      key: const Key('connections-servers-failed'),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 4),
      child: Text(
        context.l10n.sourcesLoadFailed,
        style: TextStyle(fontSize: 13, color: context.palette.textSecondary),
      ),
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection({required this.devices, required this.onRemove});

  final List<ConnectionDevice> devices;
  final ValueChanged<ConnectionDevice> onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      key: const Key('connections-devices-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: l10n.pairedDevicesListSection,
          hint: l10n.connectionsDevicesHint,
        ),
        LayoutBuilder(builder: (context, constraints) {
          final width = (constraints.maxWidth - _cardGap) / 2;
          return Wrap(
            spacing: _cardGap,
            runSpacing: _cardGap,
            children: [
              for (final d in devices)
                SizedBox(
                  key: Key('connections-device-${d.nodeId}'),
                  width: width,
                  child: HubDeviceCard(device: d, onRemove: () => onRemove(d)),
                ),
            ],
          );
        }),
      ],
    );
  }
}

/// "Sync now" and "Leave sync group", shown once this device is paired.
class _SyncFooter extends ConsumerWidget {
  const _SyncFooter({required this.onLeave});

  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final palette = context.palette;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: [
        TextButton.icon(
          key: const Key('paired-sync-now-button'),
          icon: const Icon(Icons.sync_rounded, size: 18),
          label: Text(l10n.pairedDevicesSyncNowButton),
          onPressed: () =>
              ref.read(peerSyncServiceProvider).syncAll(ignoreCooldown: true),
        ),
        TextButton.icon(
          key: const Key('paired-leave-group-button'),
          style: TextButton.styleFrom(foregroundColor: palette.textSecondary),
          icon: const Icon(Icons.link_off_rounded, size: 18),
          label: Text(l10n.connectionsLeaveGroup),
          onPressed: onLeave,
        ),
      ],
    );
  }
}
