import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/layout/rail_metrics.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/depth_tokens.dart';

class ShimmerCard extends StatelessWidget {
  final double width;
  final double height;

  const ShimmerCard({
    super.key,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.shimmerBase,
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
      ),
    );
  }
}

/// The loading stand-in for one [ContentRail].
///
/// Every dimension comes from [RailMetrics], the same object the real rail
/// reads, so the two cannot hold different numbers.
/// `test/test_utils/rail_parity.dart` asserts that at each breakpoint, and is
/// the reason this widget must not grow a hardcoded size.
class ShimmerRail extends StatelessWidget {
  const ShimmerRail({super.key, this.count});

  /// How many placeholder cards to draw.
  ///
  /// Null derives a count that overflows the viewport, so the rail has no
  /// empty tail that fills in when real cards arrive. A fixed five left the
  /// right third of a desktop rail blank.
  final int? count;

  /// Test handle for the header's title bar.
  static const headerKey = ValueKey<String>('shimmer-rail-header');

  /// Test handle for the placeholder poster block of card [index].
  static ValueKey<String> posterKeyAt(int index) =>
      ValueKey<String>('shimmer-rail-poster-$index');

  @override
  Widget build(BuildContext context) {
    final metrics = RailMetrics.of(context);
    final textTheme = Theme.of(context).textTheme;
    final cardCount = count ??
        (MediaQuery.sizeOf(context).width /
                    (metrics.cardSize.width + metrics.cardSpacing))
                .ceil() +
            1;

    // One shimmer for the whole rail rather than one per card, so the
    // highlight travels across the row as a single motion and the tree carries
    // one ShaderMask instead of N.
    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              metrics.horizontalPadding,
              metrics.headerTopPadding,
              metrics.horizontalPadding,
              metrics.headerBottomPadding,
            ),
            child: _TextBar(
              key: ShimmerRail.headerKey,
              style: textTheme.headlineSmall,
              width: 150,
            ),
          ),
          SizedBox(
            height: metrics.railHeight,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              // A skeleton has nothing to scroll to.
              physics: const NeverScrollableScrollPhysics(),
              padding:
                  EdgeInsets.symmetric(horizontal: metrics.horizontalPadding),
              itemCount: cardCount,
              itemBuilder: (context, index) => Padding(
                padding: EdgeInsets.only(
                  right: index < cardCount - 1 ? metrics.cardSpacing : 0,
                ),
                child: _ShimmerRailCard(metrics: metrics, index: index),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One placeholder card, mirroring `MediaCard`'s column: a poster, then the
/// title and subtitle lines beneath it.
class _ShimmerRailCard extends StatelessWidget {
  const _ShimmerRailCard({required this.metrics, required this.index});

  final RailMetrics metrics;
  final int index;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return SizedBox(
      width: metrics.cardSize.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            key: ShimmerRail.posterKeyAt(index),
            width: metrics.cardSize.width,
            height: metrics.cardSize.height,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.shimmerBase,
                borderRadius: BorderRadius.all(
                  Radius.circular(DepthTokens.radiusPoster),
                ),
                boxShadow: DepthTokens.posterResting,
              ),
            ),
          ),
          const SizedBox(height: RailMetrics.labelGap),
          _TextBar(style: textTheme.bodyMedium, widthFactor: 1),
          const SizedBox(height: RailMetrics.subtitleGap),
          _TextBar(style: textTheme.bodySmall, widthFactor: 0.6),
        ],
      ),
    );
  }
}

/// A shimmering bar exactly one line of [style] tall.
///
/// The height comes from a zero-width space rendered in the real text style
/// rather than from a hardcoded pixel value, so the bars follow a theme change
/// without a tuning pass. Pass [width] for a fixed width or [widthFactor] for
/// a fraction of the available one.
class _TextBar extends StatelessWidget {
  const _TextBar({
    super.key,
    required this.style,
    this.width,
    this.widthFactor,
  });

  final TextStyle? style;
  final double? width;
  final double? widthFactor;

  @override
  Widget build(BuildContext context) {
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.shimmerBase,
        borderRadius: BorderRadius.circular(AppTheme.radiusButton),
      ),
      // U+200B, a zero-width space: no glyph, full line height.
      child: Text('​', style: style),
    );

    if (width != null) return SizedBox(width: width, child: bar);
    if (widthFactor != null) {
      return FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: bar,
      );
    }
    return bar;
  }
}
