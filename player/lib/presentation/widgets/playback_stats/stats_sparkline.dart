/// Throughput and buffer depth over the last sixty seconds.
///
/// A snapshot says the buffer is at six seconds. This says it was at
/// thirty a moment ago and is draining, which is the difference between a
/// number and a diagnosis.
library;

import 'package:flutter/material.dart';

import '../../../core/playback/stats/playback_stats.dart';

class StatsSparkline extends StatelessWidget {
  const StatsSparkline({
    super.key,
    required this.history,
    required this.width,
    required this.height,
  });

  final List<StatsPoint> history;
  final double width;
  final double height;

  /// Below this, nothing is drawn. Two or three points make a line that
  /// says nothing and reads as a rendering fault.
  static const int minimumPoints = 5;

  static const Key painterKey = Key('stats-sparkline');

  static const Color throughputColor = Color(0xFF7FB4FF);
  static const Color bufferColor = Color(0xFF4FD8A8);

  @override
  Widget build(BuildContext context) {
    if (history.length < minimumPoints) return const SizedBox.shrink();
    return CustomPaint(
      key: painterKey,
      size: Size(width, height),
      painter: _SparklinePainter(history),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.history);

  final List<StatsPoint> history;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x12FFFFFF)
      ..strokeWidth = 1;
    for (final fraction in const [0.2, 0.5, 0.8]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    _drawSeries(
      canvas,
      size,
      history.map((p) => p.throughputKbps?.toDouble()).toList(),
      StatsSparkline.throughputColor,
    );
    _drawSeries(
      canvas,
      size,
      history.map((p) => p.bufferedMs.toDouble()).toList(),
      StatsSparkline.bufferColor,
    );
  }

  /// Each series is scaled to its own window maximum, because kilobits and
  /// milliseconds share no axis. A null value breaks the line rather than
  /// reading as zero.
  void _drawSeries(
    Canvas canvas,
    Size size,
    List<double?> values,
    Color color,
  ) {
    final present = values.whereType<double>();
    if (present.isEmpty) return;
    final max = present.reduce((a, b) => a > b ? a : b);
    final step = values.length > 1 ? size.width / (values.length - 1) : 0.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    var open = false;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        open = false;
        continue;
      }
      // A window of all zeros has no range to normalise against. Draw it
      // as a level line at mid height rather than dividing by zero.
      final normalised = max <= 0 ? 0.5 : value / max;
      final y =
          size.height - (normalised * size.height * 0.9) - size.height * 0.05;
      final point = Offset(step * i, y);
      if (open) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        open = true;
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => !identical(old.history, history);
}
