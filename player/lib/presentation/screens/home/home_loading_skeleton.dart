import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';
import '../sources/source_poster_row.dart';

/// The home screen's loading state.
///
/// Shaped to the loaded layout rather than to a generic placeholder: a hero
/// and three rails at the sizes and offsets `HomeScreen`'s `data` branch will
/// use, so nothing moves when the two swap.
///
/// It lives in its own file so a test can pump it directly. In place, checking
/// this geometry meant holding a code-generated Riverpod `StreamNotifier` in
/// `AsyncLoading`, which is a lot of scaffolding to assert a padding value.
class HomeLoadingSkeleton extends StatelessWidget {
  const HomeLoadingSkeleton({super.key});

  /// Test handle for the hero block.
  static const heroKey = ValueKey<String>('home-skeleton-hero');

  /// Test handle shared by every placeholder rail.
  @visibleForTesting
  static const railKey = ValueKey<String>('home-skeleton-rail');

  @override
  Widget build(BuildContext context) {
    // No top padding, and no spacers between the rails.
    //
    // The `data` branch is a `CustomScrollView` with neither, under a Scaffold
    // with `extendBodyBehindAppBar: true`, so its hero starts at y=0 and
    // renders under the glass app bar. A top padding here pushed the
    // placeholder hero below the app bar and cost roughly 80 to 100px of jump
    // on load. Rails are separated by `RailMetrics.headerTopPadding` alone,
    // exactly as the loaded rows are.
    return ListView(
      children: const [
        _ShimmerHero(key: HomeLoadingSkeleton.heroKey),
        _ShimmerRail(key: HomeLoadingSkeleton.railKey),
        _ShimmerRail(key: HomeLoadingSkeleton.railKey),
        _ShimmerRail(key: HomeLoadingSkeleton.railKey),
      ],
    );
  }
}

class _ShimmerHero extends StatelessWidget {
  const _ShimmerHero({super.key});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = Breakpoints.isDesktop(context);
    // Match the responsive hero height from _HeroSection
    final heroHeight = isDesktop
        ? (size.height * 0.45).clamp(300.0, 450.0)
        : size.height * 0.5;
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);

    return Container(
      width: size.width,
      height: heroHeight,
      color: AppColors.surface,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.background.withValues(alpha: 0.4),
                    Colors.transparent,
                    AppColors.background.withValues(alpha: 0.9),
                    AppColors.background,
                  ],
                  stops: const [0.0, 0.3, 0.7, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            left: horizontalPadding,
            right: horizontalPadding,
            bottom: isDesktop ? 32 : 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 80,
                  height: 20,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: 200,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 120,
                  height: 20,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      width: 100,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.shimmerBase,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 120,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.shimmerBase,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The loading stand-in for one `SourcePosterRow`.
///
/// Sizes come from `SourcePosterRow`'s constants and from the same
/// `Breakpoints` spacing `HorizontalRail` reads, so the swap to real rows does
/// not move anything. One `Shimmer` covers the whole rail so the highlight
/// travels across it as a single motion.
class _ShimmerRail extends StatelessWidget {
  const _ShimmerRail({super.key});

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    // Overflow the viewport so the rail has no empty tail that fills in later.
    final count = (MediaQuery.sizeOf(context).width /
                (SourcePosterRow.posterWidth + cardSpacing))
            .ceil() +
        1;

    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: _bar(width: 150, height: 24, radius: 6),
          ),
          SizedBox(
            height: SourcePosterRow.rowHeight,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              // A skeleton has nothing to scroll to.
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              itemCount: count,
              itemBuilder: (context, index) => Padding(
                padding: EdgeInsets.only(
                  right: index < count - 1 ? cardSpacing : 0,
                ),
                child: SizedBox(
                  width: SourcePosterRow.posterWidth,
                  child: _bar(radius: 8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _bar({double? width, double? height, required double radius}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.shimmerBase,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
