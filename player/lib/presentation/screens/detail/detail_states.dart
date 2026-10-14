import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../widgets/detail_hero_app_bar.dart';

/// The detail screens' loading body.
///
/// Uses the same title row as the loaded hero, so the back button (and the
/// cast button) clear the traffic lights / Linux buttons here too: this state
/// sits under the same `WindowChromeInsets.removeBand` as the rest of the
/// screen, so a plain `leading` slot with its own flat padding has nothing
/// left to push it clear of the band with. `topScrim: false` because the
/// spinner background never had a top darkening gradient.
class DetailLoadingState extends StatelessWidget {
  const DetailLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      clipBehavior: Clip.none,
      slivers: [
        detailHeroAppBar(
          context: context,
          expandedHeight: 350,
          back: const DetailHeroBackButton(),
          topScrim: false,
          background: Container(
            color: AppColors.surface,
            child: const Center(child: CircularProgressIndicator()),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _shimmer(height: 48, radius: 12),
                const SizedBox(height: 24),
                _shimmer(height: 24, width: 200),
                const SizedBox(height: 16),
                _shimmer(height: 100),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _shimmer({required double height, double? width, double radius = 8}) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: AppColors.shimmerBase,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// The detail screens' error body: "Failed to load [noun]", the error, and a
/// retry button. Shares the loaded hero's title row for the same reason as
/// [DetailLoadingState].
class DetailErrorState extends StatelessWidget {
  const DetailErrorState({
    super.key,
    required this.noun,
    required this.error,
    required this.onRetry,
  });

  /// "movie", "TV show" or "episode".
  final String noun;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return CustomScrollView(
      clipBehavior: Clip.none,
      slivers: [
        detailHeroAppBar(
          context: context,
          expandedHeight: 200,
          back: const DetailHeroBackButton(),
          topScrim: false,
          background: Container(color: AppColors.background),
        ),
        SliverFillRemaining(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.error_outline_rounded,
                      size: 48,
                      color: AppColors.error,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Failed to load $noun',
                    style: textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error.toString(),
                    style: textTheme.bodyMedium
                        ?.copyWith(color: AppColors.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try Again'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
