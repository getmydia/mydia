import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../sources/continue_watching_card.dart';
import '../sources/source_home_hero.dart';
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
  const HomeLoadingSkeleton(
      {super.key, this.showHero = true, this.topInset = 0});

  /// False for a home with no hero (All servers), whose loaded list opens
  /// with a rail.
  final bool showHero;

  /// Space above the first child. A source home's hero starts at y=0 behind
  /// the bar, so it needs none; a heroless home passes where its loaded list
  /// starts.
  final double topInset;

  /// Test handle for the hero block.
  static const heroKey = ValueKey<String>('home-skeleton-hero');

  /// Test handle for the hero's poster placeholder.
  @visibleForTesting
  static const heroPosterKey = ValueKey<String>('home-skeleton-hero-poster');

  /// Test handle shared by every placeholder rail.
  @visibleForTesting
  static const railKey = ValueKey<String>('home-skeleton-rail');

  @override
  Widget build(BuildContext context) {
    // Explicit padding, and no spacers between the rails.
    //
    // The `data` branch is a `CustomScrollView` with neither, under a Scaffold
    // with `extendBodyBehindAppBar: true`, so its hero starts at y=0 and
    // renders under the glass app bar. A ListView with null padding inherits
    // the bar's bottom edge from MediaQuery there and would push the
    // placeholder hero below the bar. Rails are separated by their own
    // heading padding alone, as `SourcePosterRow` lays them out.
    return ListView(
      padding: EdgeInsets.only(top: topInset),
      children: [
        if (showHero) const _ShimmerHero(key: HomeLoadingSkeleton.heroKey),
        // The first rail is Continue Watching, drawn as landscape cards.
        const _ShimmerRail(key: HomeLoadingSkeleton.railKey, landscape: true),
        const _ShimmerRail(key: HomeLoadingSkeleton.railKey),
        const _ShimmerRail(key: HomeLoadingSkeleton.railKey),
      ],
    );
  }
}

class _ShimmerHero extends StatelessWidget {
  const _ShimmerHero({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = Breakpoints.isDesktop(context);
    final padding = Breakpoints.getHorizontalPadding(context);
    // The same offsets as the loaded hero, so nothing moves on the swap.
    final inset = EdgeInsets.fromLTRB(
      padding,
      MediaQuery.paddingOf(context).top + 24,
      padding,
      32,
    );

    Widget bar(double width, double height, double radius) =>
        _ShimmerRail._bar(width: width, height: height, radius: radius);

    // A bar as tall as [lines] lines of [style], so the placeholder follows
    // the loaded text's metrics: invisible text inside a filled box.
    Widget textBar(double? width, TextStyle? style, int lines, double radius,
        {double vertical = 0}) {
      final text = List.filled(lines, 'M').join('\n');
      return SizedBox(
        width: width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.shimmerBase,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: vertical),
            // The text only sizes the bar; a screen reader must not say "M".
            child: ExcludeSemantics(
              child: Text(
                text,
                style: style?.copyWith(color: Colors.transparent),
              ),
            ),
          ),
        ),
      );
    }

    final textTheme = Theme.of(context).textTheme;
    final align = wide ? CrossAxisAlignment.start : CrossAxisAlignment.center;
    final lines = Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The chip row.
        textBar(
          80,
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          1,
          AppTheme.radiusChip,
          vertical: 4,
        ),
        const SizedBox(height: 14),
        textBar(
          wide ? 300 : 200,
          textTheme.displayLarge?.copyWith(
            fontSize: wide ? 48 : 30,
            letterSpacing: -1.2,
            height: 1.0,
          ),
          1,
          8,
        ),
        const SizedBox(height: 12),
        textBar(wide ? 420 : 280, textTheme.bodyLarge, 2, 6),
        const SizedBox(height: 20),
        if (wide)
          Align(
            alignment: Alignment.centerLeft,
            child: bar(220, 52, AppTheme.radiusButton),
          )
        else ...[
          bar(double.infinity, 52, AppTheme.radiusButton),
          const SizedBox(height: 10),
          bar(double.infinity, 52, AppTheme.radiusButton),
        ],
      ],
    );

    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Padding(
        padding: inset,
        child: wide
            ? Row(
                children: [
                  SizedBox(
                    key: HomeLoadingSkeleton.heroPosterKey,
                    width: SourceHomeHero.posterSize.width,
                    height: SourceHomeHero.posterSize.height,
                    child: bar(
                      SourceHomeHero.posterSize.width,
                      SourceHomeHero.posterSize.height,
                      AppTheme.radiusHeroPoster,
                    ),
                  ),
                  const SizedBox(width: 36),
                  Expanded(child: lines),
                ],
              )
            : Column(
                children: [
                  SizedBox(
                    width: SourceHomeHero.narrowPosterWidth(context),
                    child: AspectRatio(
                      key: HomeLoadingSkeleton.heroPosterKey,
                      aspectRatio: SourceHomeHero.posterSize.width /
                          SourceHomeHero.posterSize.height,
                      child: bar(
                        double.infinity,
                        double.infinity,
                        AppTheme.radiusHeroPoster,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  lines,
                ],
              ),
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
  const _ShimmerRail({super.key, this.landscape = false});

  /// Continue Watching's landscape cards instead of posters.
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final itemWidth = landscape
        ? ContinueWatchingCard.artSize.width
        : SourcePosterRow.posterWidth;
    final railHeight =
        landscape ? ContinueWatchingCard.height : SourcePosterRow.rowHeight;
    final radius = landscape ? AppTheme.radiusCard : 8.0;
    // Overflow the viewport so the rail has no empty tail that fills in later.
    final count =
        (MediaQuery.sizeOf(context).width / (itemWidth + cardSpacing)).ceil() +
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
            height: railHeight,
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
                  width: itemWidth,
                  child: _bar(radius: radius),
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
