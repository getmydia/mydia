/// The stats panel, drawn over the video.
///
/// Anchored below the chrome's top pill row and above the control panel's
/// corner inset (see `StatsMetrics`), so it stays put while the chrome
/// fades in and out. Dumb by design: every decision about what to show
/// lives in `stats_report.dart`, and every decision about where lives in
/// `stats_metrics.dart`.
library;

import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../../../core/playback/stats/playback_stats.dart';
import '../../../core/playback/stats/stats_metrics.dart';
import '../../../core/playback/stats/stats_report.dart';
import '../../../core/theme/colors.dart';
import 'stats_sparkline.dart';

class StatsPanel extends StatelessWidget {
  const StatsPanel({
    super.key,
    required this.sample,
    required this.context,
    required this.metrics,
    this.onCopy,
    this.onClose,
  });

  final StatsSample sample;
  final StatsContext context;
  final StatsMetrics metrics;

  /// Null on the remote tier, where the panel draws no buttons at all.
  final VoidCallback? onCopy;
  final VoidCallback? onClose;

  static const Key panelKey = Key('stats-panel');
  static const Key copyKey = Key('stats-copy');
  static const Key closeKey = Key('stats-close');

  static Key rowKey(String label) => Key('stats-row-$label');

  static const Color _good = Color(0xFF4FD8A8);
  static const Color _warn = Color(0xFFE8B27C);

  @override
  Widget build(BuildContext buildContext) {
    final rows = statsRows(sample, context, metrics.density);
    final tv = metrics.density == StatsDensity.tv;

    return Container(
      key: panelKey,
      width: metrics.width,
      constraints: BoxConstraints(maxHeight: metrics.maxHeight),
      padding: EdgeInsets.fromLTRB(
        tv ? 22 : 15,
        metrics.showButtons ? 6 : 18,
        tv ? 22 : 15,
        tv ? 20 : 14,
      ),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.80),
        borderRadius: BorderRadius.circular(tv ? 16 : 14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: tv ? 44 : 36,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(tv),
          Container(
            height: 1,
            margin: EdgeInsets.only(bottom: tv ? 14 : 11),
            color: Colors.white.withValues(alpha: 0.08),
          ),
          // The row set varies with what the platform knows, and the Why
          // row's text length varies with the adaptation reason, so this
          // region's natural height is not knowable ahead of time. It
          // scrolls rather than overflows when it exceeds the space the
          // header, divider and the pinned footer content below leave it.
          // The tv tier never needs this: `StatsMetrics.tvMinHeight` is
          // gated on the tv panel's full measured content height, so a
          // television always has room to show it all without scrolling,
          // which matters because a D-pad cannot scroll an unfocusable
          // scroll view.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final row in rows) ...[
                    _row(row),
                    if (row != rows.last) SizedBox(height: metrics.rowGap),
                  ],
                  if (metrics.showSparkline) _sparkline(tv),
                ],
              ),
            ),
          ),
          if (metrics.density == StatsDensity.compact) _compactFootnote(),
          if (tv) _remoteHint(),
        ],
      ),
    );
  }

  Widget _header(bool tv) {
    final title = Text(
      'STATS FOR NERDS',
      style: TextStyle(
        fontSize: tv ? 12.5 : 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.4,
        color: AppColors.textSecondary,
      ),
    );
    if (!metrics.showButtons) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 13),
        child: title,
      );
    }
    return Row(
      children: [
        Expanded(child: title),
        IconButton(
          key: copyKey,
          onPressed: onCopy,
          icon: const Icon(Icons.copy, size: 15),
          color: AppColors.textSecondary,
          tooltip: 'Copy stats',
          // A finger-sized target where a finger is the pointer, and a
          // tight one where a mouse is: 44px icon buttons would double the
          // header's height on the compact panel that can least afford it.
          constraints: BoxConstraints.tightFor(
            width: metrics.density == StatsDensity.compact ? 44 : 32,
            height: metrics.density == StatsDensity.compact ? 44 : 32,
          ),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          key: closeKey,
          onPressed: onClose,
          icon: const Icon(Icons.close, size: 15),
          color: AppColors.textSecondary,
          tooltip: 'Hide stats',
          constraints: BoxConstraints.tightFor(
            width: metrics.density == StatsDensity.compact ? 44 : 32,
            height: metrics.density == StatsDensity.compact ? 44 : 32,
          ),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _row(StatsRow row) {
    final color = switch (row.tone) {
      StatsTone.good => _good,
      StatsTone.warn => _warn,
      StatsTone.normal => AppColors.textPrimary,
    };
    return Row(
      key: rowKey(row.label),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: metrics.density == StatsDensity.tv ? 126 : 90,
          child: Text(
            row.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: metrics.labelSize,
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          // A `Row` with the value `Flexible`, not a `Wrap`: a `Wrap`
          // pushes the value onto a second run when the pill and the
          // value don't both fit on the value column's width, which makes
          // the row's height a function of the string. `Flexible` instead
          // keeps the pill and value on exactly one line always, ellipsizing
          // an overlong value rather than reflowing it, so every row's
          // height is a function of the font and the density alone. The
          // tv tier's "never scrolls" promise (`StatsMetrics.tvMinHeight`)
          // depends on that being true at every density, not just tv's.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (row.pill != null) ...[
                _pill(row.pill!),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  row.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: metrics.valueSize,
                    color: color,
                    height: 1.45,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.42),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: metrics.density == StatsDensity.tv ? 11.5 : 9.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.7,
            color: _warn,
          ),
        ),
      );

  Widget _sparkline(bool tv) => Padding(
        padding: EdgeInsets.only(top: tv ? 15 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 1,
              margin: EdgeInsets.only(bottom: tv ? 9 : 7),
              color: Colors.white.withValues(alpha: 0.08),
            ),
            Row(
              children: [
                _legend('throughput', StatsSparkline.throughputColor, tv),
                const SizedBox(width: 12),
                _legend('buffer', StatsSparkline.bufferColor, tv),
                const Spacer(),
                Text(
                  'last 60 s',
                  style: TextStyle(
                    fontSize: tv ? 12.5 : 10,
                    color: AppColors.textDisabled,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            StatsSparkline(
              history: sample.history,
              width: metrics.width - (tv ? 44 : 30),
              height: tv ? 62 : 54,
            ),
          ],
        ),
      );

  Widget _legend(String label, Color color, bool tv) => Row(
        children: [
          Container(width: tv ? 14 : 12, height: 2, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: tv ? 12.5 : 10,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      );

  Widget _compactFootnote() => Padding(
        padding: const EdgeInsets.only(top: 9),
        child: Text(
          'Short height: source, decoder, audio and the graph move '
          'into Copy.',
          style: TextStyle(
            fontSize: 9.5,
            color: AppColors.textDisabled,
            height: 1.4,
          ),
        ),
      );

  Widget _remoteHint() => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.24),
                ),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                'OK',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.72),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                'then Stats for nerds, to hide this',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
}
