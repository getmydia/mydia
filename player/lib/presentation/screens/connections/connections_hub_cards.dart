/// The cards the Servers & devices hub is built from: a server, a paired
/// device, the add-a-server ghost and the pair call to action.
library;

import 'package:flutter/material.dart';

import '../../../core/sources/source.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/focus_highlight.dart';
import '../../widgets/glass_surface.dart';
import 'connections_constellation_card.dart';
import 'connections_overview.dart';

const double _tileSize = 44;

/// The surface every hub card sits on: the settings cards' faux glass, with
/// a focus ring and an ink response when it leads somewhere.
class HubCardSurface extends StatelessWidget {
  const HubCardSurface({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppTheme.radiusCard);
    final surface = GlassSurface.faux(
      borderRadius: radius,
      fillColor: context.palette.surfaceVariant.withValues(alpha: 0.55),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          canRequestFocus: false,
          borderRadius: radius,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    final tap = onTap;
    if (tap == null) return surface;
    return FocusHighlight(
        onActivate: tap, borderRadius: radius, child: surface);
  }
}

/// The kind's name, as the brand spells it.
String connectionKindName(SourceKind kind, AppLocalizations l10n) =>
    switch (kind) {
      SourceKind.mydia => 'Mydia',
      SourceKind.plex => 'Plex',
      SourceKind.jellyfin => 'Jellyfin',
      SourceKind.stash => 'Stash',
      SourceKind.files => l10n.sourcesAccountFiles,
    };

/// A device platform's name, as its maker spells it.
String connectionPlatformName(String platform) =>
    switch (platform.toLowerCase()) {
      'android' => 'Android',
      'ios' => 'iOS',
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      'web' => 'Web',
      _ => platform,
    };

/// One saved account: monogram, name, kind and address, and its chips.
class HubServerCard extends StatelessWidget {
  const HubServerCard({
    super.key,
    required this.server,
    required this.direct,
    required this.onTap,
  });

  final ConnectionServer server;

  /// This device reaches the server over a direct p2p path right now.
  final bool direct;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final kind = connectionKindName(server.kind, l10n);
    final detail =
        server.host ?? l10n.connectionsServerCount(server.serverCount);
    final statusText = switch (server.status) {
      ConnectionStatus.online when direct => l10n.connectionsChipDirect,
      ConnectionStatus.online => l10n.connectionsChipOnline,
      ConnectionStatus.offline => l10n.commonOffline,
      ConnectionStatus.needsSignIn => l10n.navSourceSignInAgain,
    };
    final statusColor = connectionStatusColor(server.status, palette);

    return HubCardSurface(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: _tileSize,
            child: ServerMonogram(kind: server.kind),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.connectionsServerMeta(kind, detail),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 12.5, color: palette.textSecondary),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    HubChip(label: statusText, dot: statusColor),
                    if (server.locked)
                      HubChip(
                        label: l10n.connectionsChipLocked,
                        icon: Icons.lock_outline_rounded,
                      ),
                    if (server.inAllServers)
                      HubChip(
                        label: l10n.connectionsChipInAll,
                        icon: Icons.layers_outlined,
                      ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Icon(Icons.chevron_right,
                size: 20, color: palette.textDisabled),
          ),
        ],
      ),
    );
  }
}

/// A small pill: a status dot or an icon, then a word or two.
class HubChip extends StatelessWidget {
  const HubChip({super.key, required this.label, this.dot, this.icon});

  final String label;
  final Color? dot;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dotColor = dot;
    final glyph = icon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: palette.surfaceHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 7,
              height: 7,
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: dotColor),
            ),
            const SizedBox(width: 6),
          ] else if (glyph != null) ...[
            Icon(glyph, size: 13, color: palette.textSecondary),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: palette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Add a server", drawn where the server cards would be when none is saved.
class HubAddServerGhost extends StatelessWidget {
  const HubAddServerGhost({super.key, required this.onTap, this.label});

  final VoidCallback onTap;

  /// Defaults to "Add a server".
  final String? label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return HubCardSurface(
      onTap: onTap,
      child: Row(
        children: [
          const SizedBox.square(
            dimension: _tileSize,
            child: GhostNode(circle: false),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label ?? context.l10n.connectionsAddServerGhost,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One paired device: platform glyph, name, platform and last sync, and a
/// menu holding "Remove".
class HubDeviceCard extends StatelessWidget {
  const HubDeviceCard({
    super.key,
    required this.device,
    required this.onRemove,
  });

  final ConnectionDevice device;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final synced = device.lastSyncedAt;
    final platform = connectionPlatformName(device.platform);
    return HubCardSurface(
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.surfaceHigh,
                  border: Border.all(
                      color: palette.primary.withValues(alpha: 0.45)),
                ),
                child: Icon(connectionPlatformIcon(device.platform),
                    size: 18, color: palette.textSecondary),
              ),
              const Spacer(),
              PopupMenuButton<void>(
                key: Key('connections-device-menu-${device.nodeId}'),
                icon: Icon(Icons.more_vert,
                    size: 20, color: palette.textDisabled),
                itemBuilder: (_) => [
                  PopupMenuItem<void>(
                    key: Key('remove-peer-${device.nodeId}'),
                    onTap: onRemove,
                    child: Row(
                      children: [
                        const Icon(Icons.link_off_rounded, size: 18),
                        const SizedBox(width: 10),
                        Text(l10n.pairedDevicesRemovePeerButton),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              device.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              synced == null
                  ? platform
                  : l10n.connectionsDeviceMeta(
                      platform, l10n.relativeTime(synced)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Pair another device", with the two ways in.
class HubPairCta extends StatelessWidget {
  const HubPairCta({
    super.key,
    required this.onShowCode,
    required this.onEnterCode,
  });

  final VoidCallback onShowCode;
  final VoidCallback onEnterCode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    return HubCardSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.primary.withValues(alpha: 0.14),
                ),
                child: Icon(Icons.devices_rounded,
                    size: 19, color: palette.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.connectionsPairCta,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.connectionsPairCtaBody,
                      style: TextStyle(
                          fontSize: 12.5, color: palette.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('connections-show-code'),
                icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                label: Text(l10n.connectionsShowCode),
                onPressed: onShowCode,
              ),
              OutlinedButton.icon(
                key: const Key('connections-enter-code'),
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                label: Text(l10n.connectionsEnterCode),
                onPressed: onEnterCode,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
