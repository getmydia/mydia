part of 'connections_constellation_card.dart';

// The diagram's node widgets and line painters.

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
