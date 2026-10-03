import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/player/input_capabilities.dart';
import '../../../core/playback/stats/playback_stats.dart';
import '../../../core/playback/stats/playback_stats_collector.dart';
import '../../../core/playback/stats/stats_metrics.dart';
import '../../../domain/models/cast_device.dart' show CastSession;
import '../../../domain/models/media_segment.dart';
import '../../widgets/playback_stats/stats_panel.dart';
import '../../widgets/video_controls/chrome_panel.dart';
import '../../widgets/video_controls/skip_segment_button.dart';

/// Leaves the player: back where it came from, or home when it was the
/// first route.
void popOrGoHome(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/');
  }
}

/// The spinner shown while the player is opening, with an optional status
/// line under it.
class PlayerLoadingView extends StatelessWidget {
  const PlayerLoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            color: Colors.red,
          ),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(
              message!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[400],
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The failure state: the message, a retry and a way out.
class PlayerErrorView extends StatelessWidget {
  const PlayerErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            size: 64,
            color: Colors.red,
          ),
          const SizedBox(height: 16),
          Text(
            'Failed to load video',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[400],
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => popOrGoHome(context),
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }
}

/// What the player screen shows while the media is on a receiver.
///
/// Deliberately inert: every control lives in `CastMiniController`, which is
/// mounted over this screen by `app.dart`. Duplicating them here is the
/// confusion this replaced: two surfaces showing the same title, device,
/// play/pause and stop, with the bar clipping the remote's stop button.
///
/// [session] rather than just the device: `isCastingProvider` stays true for
/// a [CastSession] that has gone stale (its `mediaInfo` survives the drop,
/// see `CastSession.copyWith`), and this is the app's single largest
/// `Icons.cast_connected` glyph. Rendering it over a connection that no
/// longer exists is exactly the false "connected" claim this feature exists
/// to eliminate, so a stale session gets the same outline glyph and "Lost
/// connection" wording as `CastMiniController`'s stale row, not a claim of
/// a live cast.
class CastPlaceholderView extends StatelessWidget {
  const CastPlaceholderView({
    super.key,
    required this.session,
    required this.title,
    required this.segmentAt,
    required this.onSkip,
  });

  final CastSession session;
  final String title;
  final MediaSegment? Function(Duration) segmentAt;
  final ValueChanged<MediaSegment> onSkip;

  @override
  Widget build(BuildContext context) {
    final device = session.device;
    final isStale = session.isStale;

    // The one control this screen does own while casting. It is not the
    // duplication the doc comment above warns about: `CastMiniController`
    // has no skip, so there is no second copy to disagree with, and the
    // alternative is the feature simply not existing on a TV.
    //
    // Withheld over a stale session for the reason the glyph goes outline:
    // the receiver is gone, and a control that silently does nothing is that
    // same false "connected" claim wearing a different hat.
    //
    // Withheld while syncing too, like the bar's own controls: the position
    // may be minutes old, so the segment it falls in may not be the one the
    // receiver is playing.
    final castPosition = session.mediaInfo?.position ?? Duration.zero;
    final skipSegment =
        isStale || session.isSyncing ? null : segmentAt(castPosition);
    final panelMetrics = PanelMetrics.resolve(
      width: MediaQuery.sizeOf(context).width,
      touchPrimary: InputCapabilities.touchPrimary,
    );

    return Stack(
      children: [
        Center(
          child: Padding(
            // Bottom inset keeps the text clear of the mini bar.
            padding: const EdgeInsets.only(
              left: 32,
              right: 32,
              top: 32,
              bottom: 120,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isStale ? Icons.cast_outlined : Icons.cast_connected,
                  size: 96,
                  color: isStale ? Colors.grey : Colors.blue,
                ),
                const SizedBox(height: 24),
                Text(
                  isStale
                      ? 'Lost connection to ${device.name}'
                      : 'Playing on ${device.name}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[400],
                      ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
        // `Positioned.fill` for the same reason the local path uses it: the
        // button aligns itself bottom-right, which needs the Stack's full
        // constraints rather than the loose ones a bare child would get.
        if (skipSegment != null)
          Positioned.fill(
            child: SkipSegmentButton(
              key: ValueKey(skipSegment.key),
              segment: skipSegment,
              position: castPosition,
              onSkip: onSkip,
              metrics: panelMetrics,
            ),
          ),
        Positioned(
          top: 8,
          left: 8,
          child: SafeArea(
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => popOrGoHome(context),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The stats overlay, drawn over the chrome from the collector's samples.
class PlayerStatsPanel extends StatelessWidget {
  const PlayerStatsPanel({
    super.key,
    required this.collector,
    required this.statsContext,
    required this.onCopy,
    required this.onClose,
  });

  final PlaybackStatsCollector collector;
  final StatsContext Function() statsContext;
  final void Function(StatsSample, StatsContext) onCopy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final metrics = StatsMetrics.resolve(
      viewport: MediaQuery.sizeOf(context),
      directionalPrimary: InputCapabilities.directionalPrimary,
    );
    if (metrics == null) return const SizedBox.shrink();

    return Positioned.fill(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.only(
              top: metrics.top,
              left: metrics.gutter,
            ),
            child: ValueListenableBuilder<StatsSample?>(
              valueListenable: collector.samples,
              builder: (context, sample, _) {
                if (sample == null) return const SizedBox.shrink();
                final ctx = statsContext();
                return StatsPanel(
                  sample: sample,
                  context: ctx,
                  metrics: metrics,
                  onCopy:
                      metrics.showButtons ? () => onCopy(sample, ctx) : null,
                  onClose: metrics.showButtons ? onClose : null,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
