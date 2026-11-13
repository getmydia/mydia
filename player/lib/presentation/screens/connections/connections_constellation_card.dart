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
  const ConnectionsConstellationCard({super.key, this.wide = false});

  /// The desktop dialog's wider design box (640x300 rather than 320x250).
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(connectionsOverviewProvider);
    final l10n = context.l10n;
    void open() => SettingsNavScope.of(context).openConnections();

    if (overview.serversFailed) {
      return SettingsCard(children: [
        SettingsRow.navigation(
          key: const Key('connections-card-fallback'),
          icon: Icons.hub_outlined,
          title: l10n.connectionsTitle,
          onTap: open,
        ),
      ]);
    }

    const showServers = !kIsWeb;
    final footer = _Footer.of(context, overview, showServers: showServers);
    final palette = context.palette;
    final radius = BorderRadius.circular(_cardRadius);

    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label: l10n.connectionsCardSemantics(footer.summary),
      onTap: open,
      child: FocusHighlight(
        onActivate: open,
        borderRadius: radius,
        child: GlassSurface.faux(
          borderRadius: radius,
          fillColor: palette.surfaceVariant.withValues(alpha: 0.55),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const Key('connections-card'),
              canRequestFocus: false,
              borderRadius: radius,
              onTap: open,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _Header(),
                    const SizedBox(height: 4),
                    _Diagram(
                      overview: overview,
                      showServers: showServers,
                      design:
                          wide ? const Size(640, 300) : const Size(320, 250),
                    ),
                    const SizedBox(height: 6),
                    footer,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

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
    required this.design,
  });

  final ConnectionsOverview overview;
  final bool showServers;
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
      final diagram = ExcludeSemantics(
        child: SizedBox.fromSize(size: box, child: _stack(context, box)),
      );
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
    final placed = layoutConstellation(
      servers: overview.servers,
      devices: overview.devices,
      showServers: showServers,
      box: box,
    );

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
          node: _CentreNode(platform: overview.localPlatform),
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
        GhostServerNode() => const _GhostNode(circle: false),
        GhostDeviceNode() => const _GhostNode(circle: true),
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

/// This device: the platform glyph in a primary ring with a soft halo.
class _CentreNode extends StatelessWidget {
  const _CentreNode({required this.platform});

  final String platform;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: palette.surfaceHigh,
        border: Border.all(color: palette.primary, width: 2),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withValues(alpha: 0.10),
            spreadRadius: 6,
          ),
        ],
      ),
      child: Center(
        child: Icon(
          connectionPlatformIcon(platform),
          size: 28,
          color: palette.textPrimary,
        ),
      ),
    );
  }
}

/// A server: its kind's monogram on a rounded square, with a status dot.
class _ServerNode extends StatelessWidget {
  const _ServerNode({required this.server});

  final ConnectionServer server;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final mydia = server.kind == SourceKind.mydia;
    final ink = mydia ? palette.onPrimary : palette.textPrimary;
    final monogram = switch (server.kind) {
      SourceKind.mydia => 'M',
      SourceKind.plex => 'P',
      SourceKind.jellyfin => 'J',
      SourceKind.stash => 'S',
      SourceKind.files => null,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: mydia ? palette.primary : palette.surfaceHigh,
              borderRadius: BorderRadius.circular(13),
              border: mydia ? null : Border.all(color: palette.border),
            ),
            child: Center(
              child: monogram == null
                  ? Icon(Icons.folder_rounded, size: 20, color: ink)
                  : Text(
                      monogram,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        height: 1,
                        color: ink,
                      ),
                    ),
            ),
          ),
        ),
        Positioned(
          right: -3,
          top: -3,
          child: _StatusDot(color: _statusColor(server.status, palette)),
        ),
      ],
    );
  }

  static Color _statusColor(ConnectionStatus s, MydiaPalette palette) =>
      switch (s) {
        ConnectionStatus.online => AppColors.success,
        ConnectionStatus.needsSignIn => AppColors.warning,
        ConnectionStatus.offline => palette.textDisabled,
      };
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  static const double _size = 12;

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        // Cut out of the node so it reads as a badge, not a stray dot.
        border: Border.all(color: context.palette.surface, width: 2),
      ),
    );
  }
}

class _DeviceNode extends StatelessWidget {
  const _DeviceNode({required this.device});

  final ConnectionDevice device;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: palette.surfaceHigh,
        border: Border.all(color: palette.primary.withValues(alpha: 0.45)),
      ),
      child: Center(
        child: Icon(
          connectionPlatformIcon(device.platform),
          size: 18,
          color: palette.textSecondary,
        ),
      ),
    );
  }
}

class _MoreNode extends StatelessWidget {
  const _MoreNode({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: palette.surfaceHigh,
        border: Border.all(color: palette.border),
      ),
      child: Center(
        child: Text(
          context.l10n.connectionsMoreNodes(count),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: palette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// A dashed outline with a plus: something that could be here.
class _GhostNode extends StatelessWidget {
  const _GhostNode({required this.circle});

  final bool circle;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return CustomPaint(
      painter: _DashedOutlinePainter(
        color: palette.textDisabled.withValues(alpha: 0.8),
        circle: circle,
      ),
      child: Center(
        child: Icon(Icons.add, size: 18, color: palette.textDisabled),
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

enum _Stroke { solid, dashed, dotted }

/// A line from this device to one node, ending at the node's edge.
@immutable
class _Link {
  const _Link(this.to, this.radius, this.color, this.stroke);

  final Offset to;

  /// The node's half-size, so the line stops short of it.
  final double radius;
  final Color color;
  final _Stroke stroke;

  @override
  bool operator ==(Object other) =>
      other is _Link &&
      other.to == to &&
      other.radius == radius &&
      other.color == color &&
      other.stroke == stroke;

  @override
  int get hashCode => Object.hash(to, radius, color, stroke);
}

class _ConstellationLinesPainter extends CustomPainter {
  _ConstellationLinesPainter({required this.centre, required this.links});

  final Offset centre;
  final List<_Link> links;

  /// Clear of the centre node's ring and halo.
  static const double _centreClearance = _centreSize / 2 + 9;
  static const double _nodeClearance = 5;

  /// Below this, the centre node's name: a line heading nearly straight
  /// down starts under it rather than striking through it.
  static const double _centreLabelBottom =
      _centreSize / 2 + _labelGap + _labelLineHeight + 3;

  @override
  void paint(Canvas canvas, Size size) {
    for (final link in links) {
      final delta = link.to - centre;
      final length = delta.distance;
      if (length == 0) continue;
      final dir = delta / length;
      final start = dir.dy > 0 && dir.dx.abs() < 0.3
          ? math.max(_centreClearance, _centreLabelBottom / dir.dy)
          : _centreClearance;
      final end = length - link.radius - _nodeClearance;
      if (end <= start) continue;
      final paint = Paint()
        ..color = link.color
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final (dash, gap) = switch (link.stroke) {
        _Stroke.solid => (end - start, 0.0),
        _Stroke.dashed => (6.0, 5.0),
        _Stroke.dotted => (0.1, 5.0),
      };
      for (var d = start; d < end; d += dash + gap) {
        canvas.drawLine(
          centre + dir * d,
          centre + dir * math.min(d + dash, end),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ConstellationLinesPainter old) =>
      old.centre != centre || !listEquals(old.links, links);
}

/// The ghost nodes' outline: a dashed circle or rounded square.
class _DashedOutlinePainter extends CustomPainter {
  _DashedOutlinePainter({required this.color, required this.circle});

  final Color color;
  final bool circle;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.75);
    final path = Path();
    if (circle) {
      path.addOval(rect);
    } else {
      path.addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(13)));
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      // Whole dashes around the perimeter, so the seam never shows.
      final count = math.max(4, (metric.length / 8).round());
      final step = metric.length / count;
      for (var i = 0; i < count; i++) {
        canvas.drawPath(
            metric.extractPath(i * step, i * step + step * 0.55), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutlinePainter old) =>
      old.color != color || old.circle != circle;
}
