/// The Settings card that draws this device's servers and paired devices as
/// a small constellation, and opens the Servers & devices hub.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/source.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/focus_highlight.dart';
import '../../widgets/glass_surface.dart';
import '../settings/settings_nav.dart';
import '../settings/widgets/settings_row.dart';
import '../settings/widgets/settings_section.dart';
import 'connections_overview.dart';
import 'constellation_layout.dart';

part 'constellation_parts.dart';

const double _cardRadius = 22;
const double _centreSize = 64;
const double _serverSize = 44;
const double _deviceSize = 40;
const double _labelWidth = 92;
const double _labelGap = 6;
const double _labelFontSize = 11;
const double _labelLineHeight = _labelFontSize * 1.2;

/// One tap target: the header, the diagram and the footer all open the hub.
///
/// When the saved servers fail to load it degrades to a plain navigation row,
/// so the hub stays reachable even when there is nothing to draw.
class ConnectionsConstellationCard extends ConsumerWidget {
  const ConnectionsConstellationCard({
    super.key,
    this.wide = false,
    this.interactive = true,
  });

  /// The desktop dialog's wider design box (640x300 rather than 320x250).
  final bool wide;

  /// False on the hub itself, where opening the hub would go nowhere: no tap,
  /// no focus stop, no chevron.
  final bool interactive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(connectionsOverviewProvider);
    final l10n = context.l10n;
    void open() => SettingsNavScope.of(context).openConnections();

    if (overview.serversFailed) {
      // The fallback is only a way to the hub, and the hub draws its own
      // sections below.
      if (!interactive) return const SizedBox.shrink();
      return SettingsCard(children: [
        SettingsRow.navigation(
          key: const Key('connections-card-fallback'),
          icon: Icons.hub_outlined,
          title: l10n.connectionsTitle,
          onTap: open,
        ),
      ]);
    }

    // While the saved servers are still being read, an empty list means
    // "not known yet", so neither the server half nor any invitation to add
    // one is drawn: a returning user must not see the empty install.
    final loading = overview.serversLoading;
    final showServers = !kIsWeb && !loading;
    final footer = _Footer.of(context, overview, showServers: showServers);
    final palette = context.palette;
    final radius = BorderRadius.circular(_cardRadius);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(chevron: interactive),
          const SizedBox(height: 4),
          _Diagram(
            overview: overview,
            showServers: showServers,
            ghosts: !loading,
            design: wide ? const Size(640, 300) : const Size(320, 250),
          ),
          const SizedBox(height: 6),
          footer,
        ],
      ),
    );
    Widget surface(Widget child) => GlassSurface.faux(
          borderRadius: radius,
          fillColor: palette.surfaceVariant.withValues(alpha: 0.55),
          child: child,
        );
    final label = l10n.connectionsCardSemantics(footer.summary);

    if (!interactive) {
      return Semantics(
        container: true,
        excludeSemantics: true,
        label: label,
        child: surface(KeyedSubtree(
          key: const Key('connections-card'),
          child: content,
        )),
      );
    }

    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      focusable: true,
      label: label,
      onTap: open,
      child: FocusHighlight(
        onActivate: open,
        borderRadius: radius,
        child: surface(Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const Key('connections-card'),
            canRequestFocus: false,
            borderRadius: radius,
            onTap: open,
            child: content,
          ),
        )),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.chevron});

  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.connectionsEyebrow,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: palette.textDisabled,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                context.l10n.connectionsTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.24,
                  color: palette.textPrimary,
                ),
              ),
            ],
          ),
        ),
        if (chevron)
          Icon(Icons.chevron_right, size: 20, color: palette.textDisabled),
      ],
    );
  }
}

/// The diagram, drawn in a fixed design box that stretches horizontally to
/// the card and scales down below the design width.
class _Diagram extends StatelessWidget {
  const _Diagram({
    required this.overview,
    required this.showServers,
    required this.ghosts,
    required this.design,
  });

  final ConnectionsOverview overview;
  final bool showServers;

  /// Whether placeholder nodes may stand in for what is missing.
  final bool ghosts;
  final Size design;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final available =
          constraints.maxWidth.isFinite ? constraints.maxWidth : design.width;
      // Past a third wider than the design the slots drift too far apart to
      // read as one group, so the box stops growing and centres instead.
      final width =
          available.clamp(design.width, design.width * 4 / 3).toDouble();
      final box = Size(width, design.height);
      final diagram = SizedBox.fromSize(size: box, child: _stack(context, box));
      if (available >= design.width) return Center(child: diagram);
      return SizedBox(
        width: available,
        height: design.height * available / design.width,
        child: FittedBox(child: diagram),
      );
    });
  }

  Widget _stack(BuildContext context, Size box) {
    final palette = context.palette;
    final l10n = context.l10n;
    final centre = Offset(
      constellationCentre.dx * box.width,
      constellationCentre.dy * box.height,
    );
    final placed = [
      for (final p in layoutConstellation(
        servers: overview.servers,
        devices: overview.devices,
        showServers: showServers,
        box: box,
      ))
        if (ghosts || p.node is! GhostServerNode && p.node is! GhostDeviceNode)
          p,
    ];

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _ConstellationLinesPainter(
              centre: centre,
              links: [for (final p in placed) _linkOf(p, palette)],
            ),
          ),
        ),
        for (final (i, p) in placed.indexed)
          _positioned(
            key: ValueKey(('node', i)),
            center: p.center,
            size: _sizeOf(p.node),
            node: _nodeWidget(p.node),
            label: _labelOf(p.node, l10n),
            labelColor: switch (p.node) {
              GhostServerNode() || GhostDeviceNode() => palette.textDisabled,
              _ => palette.textSecondary,
            },
          ),
        _positioned(
          key: const ValueKey('centre'),
          center: centre,
          size: _centreSize,
          node: ThisDeviceNode(platform: overview.localPlatform),
          label: overview.localName.isEmpty
              ? l10n.connectionsThisDevice
              : overview.localName,
          labelColor: palette.textPrimary,
          labelWeight: FontWeight.w600,
        ),
      ],
    );
  }

  static double _sizeOf(ConstellationNode node) => switch (node) {
        ServerNode() || GhostServerNode() => _serverSize,
        DeviceNode() || GhostDeviceNode() || MoreNode() => _deviceSize,
      };

  static Widget _nodeWidget(ConstellationNode node) => switch (node) {
        ServerNode(:final server) => _ServerNode(server: server),
        DeviceNode(:final device) => _DeviceNode(device: device),
        MoreNode(:final count) => _MoreNode(count: count),
        GhostServerNode() => const GhostNode(circle: false),
        GhostDeviceNode() => const GhostNode(circle: true),
      };

  static String? _labelOf(ConstellationNode node, AppLocalizations l10n) =>
      switch (node) {
        ServerNode(:final server) => server.name,
        DeviceNode(:final device) => device.name,
        MoreNode() => null,
        GhostServerNode() => l10n.connectionsAddServerGhost,
        GhostDeviceNode() => l10n.connectionsPairDeviceGhost,
      };

  static _Link _linkOf(PlacedNode p, MydiaPalette palette) {
    final radius = _sizeOf(p.node) / 2;
    return switch (p.node) {
      ServerNode(:final server) => server.status == ConnectionStatus.online
          ? _Link(p.center, radius, palette.surfaceBright, _Stroke.solid)
          : _Link(p.center, radius, palette.surfaceBright, _Stroke.dotted),
      DeviceNode() => _Link(p.center, radius,
          palette.primary.withValues(alpha: 0.55), _Stroke.dashed),
      MoreNode() => _Link(p.center, radius,
          palette.surfaceBright.withValues(alpha: 0.6), _Stroke.solid),
      GhostServerNode() || GhostDeviceNode() => _Link(p.center, radius,
          palette.textDisabled.withValues(alpha: 0.45), _Stroke.dotted),
    };
  }

  static Widget _positioned({
    required Key key,
    required Offset center,
    required double size,
    required Widget node,
    required String? label,
    required Color labelColor,
    FontWeight labelWeight = FontWeight.w500,
  }) {
    return Positioned(
      key: key,
      left: center.dx - _labelWidth / 2,
      top: center.dy - size / 2,
      width: _labelWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(dimension: size, child: node),
          if (label != null) ...[
            const SizedBox(height: _labelGap),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: _labelFontSize,
                height: _labelLineHeight / _labelFontSize,
                fontWeight: labelWeight,
                color: labelColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer._({
    required this.servers,
    required this.devices,
    required this.serverDot,
    required this.summary,
    this.empty = false,
  });

  /// Nothing saved and nothing paired: one invitation line, no glyphs.
  final bool empty;

  /// The servers half, or null when it has nothing to say.
  final String? servers;
  final String devices;
  final Color? serverDot;

  /// What a screen reader hears: the footer as sentences.
  final String summary;

  factory _Footer.of(
    BuildContext context,
    ConnectionsOverview o, {
    required bool showServers,
  }) {
    final l10n = context.l10n;
    if (showServers && o.servers.isEmpty && o.devices.isEmpty) {
      final text = l10n.connectionsEmptyFooter;
      return _Footer._(
        servers: null,
        devices: text,
        serverDot: null,
        summary: '$text.',
        empty: true,
      );
    }
    final total = o.servers.length;
    final online = o.onlineCount;
    final servers = showServers && total > 0
        ? l10n.connectionsServersOnline(online, total)
        : null;
    final devices = o.devices.isEmpty
        ? l10n.connectionsNotPaired
        : l10n.connectionsSyncedWith(o.devices.length);
    final Color dot;
    if (online == total) {
      dot = AppColors.success;
    } else if (online > 0) {
      dot = AppColors.warning;
    } else {
      dot = context.palette.textDisabled;
    }
    return _Footer._(
      servers: servers,
      devices: devices,
      serverDot: servers == null ? null : dot,
      summary:
          [if (servers != null) servers, devices].map((s) => '$s.').join(' '),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(fontSize: 12.5, color: palette.textSecondary);
    final serversText = servers;
    final dot = serverDot;
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (serversText != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dot != null) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
                ),
                const SizedBox(width: 6),
              ],
              Text(serversText, style: style),
            ],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!empty) ...[
              Icon(Icons.sync_rounded, size: 14, color: palette.textDisabled),
              const SizedBox(width: 5),
            ],
            Flexible(child: Text(devices, style: style)),
          ],
        ),
      ],
    );
  }
}
