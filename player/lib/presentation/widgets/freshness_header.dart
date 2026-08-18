import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_status.dart';
import '../../core/format/relative_time.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../core/graphql/watch/freshness.dart';
import '../../core/graphql/watch/invalidation_target.dart';
import '../../core/graphql/watch/query_key.dart';
import '../../core/graphql/watch/watcher_registry.dart';
import '../../core/theme/colors.dart';

/// The space a screen must reserve above the header so it lands below
/// whatever is drawn over the top of its body, rather than behind it.
///
/// [appBarHeight] has three meaningful values, one per layout this app uses:
///
/// - **omitted or null**: nothing is drawn over the body's top edge, so no
///   inset at all. Desktop layouts inside `AppShell`, which have no app bar
///   of their own.
/// - **0**: only the status bar overlaps. Screens whose app bar is a
///   `SliverAppBar` inside the scroll view, since that scrolls with the
///   content instead of sitting above it.
/// - **a height**: the status bar plus a bar of that height. Screens with
///   `extendBodyBehindAppBar: true` and a real app bar; pass the bar's actual
///   height, which is not always `kToolbarHeight` (the library's app bar is
///   taller while its search row is expanded).
double freshnessTopInset(BuildContext context, {double? appBarHeight}) {
  if (appBarHeight == null) return 0;
  return MediaQuery.paddingOf(context).top + appBarHeight;
}

/// Tells the user, at the top of a screen, whether what they are looking at is
/// being refreshed, is old, or failed to refresh.
///
/// Tier 1 is a 2px indeterminate line, shown whenever a fetch is running over
/// content that is already painted. Tier 2 is a banner, reserved for stale or
/// failed states so it stays rare and legible rather than becoming wallpaper.
class FreshnessHeader extends ConsumerWidget {
  const FreshnessHeader({
    super.key,
    required this.queryKeys,
    this.topInset = 0,
  });

  /// The keys whose combined state this header describes. Screens hosting two
  /// controllers (show detail plus season episodes) pass both.
  final List<QueryKey> queryKeys;

  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = ref.watch(authStateProvider).maybeWhen(
          data: (status) => status == AuthStatus.offlineMode,
          orElse: () => false,
        );
    // OfflineBanner already owns this message. Two stacked warning banners
    // saying overlapping things is how banners get ignored.
    if (isOffline) return const SizedBox.shrink();

    final registry = ref.watch(freshnessRegistryProvider);
    final freshness = Freshness.combine(
      queryKeys.map((key) => registry[key]).whereType<Freshness>(),
    );

    final fetchedAt = freshness.fetchedAt;
    // `hasData` rules out a cold-stale mount: an age gate that picked
    // `networkOnly` publishes a real (old) `fetchedAt` from the fetch log
    // together with `data == null`, well before anything is on screen. Without
    // this the banner would claim to be "showing" data over a shimmer, or
    // (on a failed cold fetch) over the error screen.
    final showBanner = fetchedAt != null &&
        freshness.hasData &&
        (freshness.refreshFailed ||
            (freshness.isStale && !freshness.isRefreshing));

    if (!freshness.isRefreshing && !showBanner) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(top: topInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (freshness.isRefreshing)
            const SizedBox(
              key: Key('freshness-inflight'),
              height: 2,
              child: LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Colors.transparent,
              ),
            ),
          if (showBanner)
            _FreshnessBanner(
              key: const Key('freshness-banner'),
              failed: freshness.refreshFailed,
              fetchedAt: fetchedAt,
              onAction: () => ref
                  .read(invalidatorProvider)
                  .invalidate(queryKeys.map((key) => key.target)),
            ),
        ],
      ),
    );
  }
}

/// Mirrors `OfflineBanner`: warning tint, leading icon, text, trailing action.
class _FreshnessBanner extends StatelessWidget {
  const _FreshnessBanner({
    super.key,
    required this.failed,
    required this.fetchedAt,
    required this.onAction,
  });

  final bool failed;
  final DateTime fetchedAt;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final relative = formatRelativeTime(fetchedAt);
    final message = failed
        ? "Couldn't reach your server. Showing your library from $relative."
        : 'Showing your library from $relative.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.15),
        border: Border(
          bottom: BorderSide(
            color: AppColors.warning.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            failed ? Icons.cloud_off_rounded : Icons.history_rounded,
            size: 18,
            color: AppColors.warning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.warning,
              ),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            key: const Key('freshness-action'),
            onPressed: onAction,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: AppColors.warning.withValues(alpha: 0.2),
              foregroundColor: AppColors.warning,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: Text(
              failed ? 'Retry' : 'Refresh',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
