import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'control_button.dart';

/// The playback transport: previous episode, −10s, play/pause, +10s, next
/// episode.
///
/// Player-free so it can be widget-tested; [TransportCluster] wraps it.
///
/// Episode buttons render only when their callbacks are supplied, which is how
/// the previously separate floating episode-navigation controls are absorbed
/// into the panel.
class TransportSurface extends StatelessWidget {
  /// Whether playback is currently running.
  final bool isPlaying;

  final VoidCallback? onPlayPause;
  final VoidCallback? onBack10;
  final VoidCallback? onForward10;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;

  const TransportSurface({
    super.key,
    required this.isPlaying,
    this.onPlayPause,
    this.onBack10,
    this.onForward10,
    this.onPreviousEpisode,
    this.onNextEpisode,
  });

  static const Key playPauseKey = Key('transport-play-pause');
  static const Key back10Key = Key('transport-back-10');
  static const Key forward10Key = Key('transport-forward-10');
  static const Key previousEpisodeKey = Key('transport-previous-episode');
  static const Key nextEpisodeKey = Key('transport-next-episode');

  /// Uniform gap between transport glyphs.
  static const double gap = 8.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onPreviousEpisode != null) ...[
          ControlButton(
            key: previousEpisodeKey,
            icon: Icons.skip_previous_rounded,
            size: 44,
            iconSize: 22,
            tooltip: 'Previous episode',
            onTap: onPreviousEpisode,
          ),
          const SizedBox(width: gap),
        ],
        ControlButton(
          key: back10Key,
          icon: Icons.replay_10_rounded,
          size: 44,
          iconSize: 24,
          tooltip: 'Rewind 10 seconds',
          onTap: onBack10,
        ),
        const SizedBox(width: gap),
        // AnimatedSwitcher is keyed on the glyph so play <-> pause cross-fades
        // and scales rather than snapping. Deliberately not AnimatedIcons
        // .play_pause: that ships its own glyph style and would break the
        // _rounded family coherence the icon_family_test enforces.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 120),
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: FadeTransition(opacity: animation, child: child),
          ),
          // The switching key sits on the wrapper, not the button, so
          // `find.byKey(playPauseKey)` keeps resolving to the ControlButton.
          child: KeyedSubtree(
            key: ValueKey<bool>(isPlaying),
            child: ControlButton(
              key: playPauseKey,
              icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 48,
              iconSize: 30,
              tooltip: isPlaying ? 'Pause' : 'Play',
              onTap: onPlayPause,
            ),
          ),
        ),
        const SizedBox(width: gap),
        ControlButton(
          key: forward10Key,
          icon: Icons.forward_10_rounded,
          size: 44,
          iconSize: 24,
          tooltip: 'Forward 10 seconds',
          onTap: onForward10,
        ),
        if (onNextEpisode != null) ...[
          const SizedBox(width: gap),
          ControlButton(
            key: nextEpisodeKey,
            icon: Icons.skip_next_rounded,
            size: 44,
            iconSize: 22,
            tooltip: 'Next episode',
            onTap: onNextEpisode,
          ),
        ],
      ],
    );
  }
}

/// [TransportSurface] bound to a media_kit [Player]'s playing state.
class TransportCluster extends StatelessWidget {
  final Player player;
  final VoidCallback onBack10;
  final VoidCallback onForward10;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;

  const TransportCluster({
    super.key,
    required this.player,
    required this.onBack10,
    required this.onForward10,
    this.onPreviousEpisode,
    this.onNextEpisode,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;
        return TransportSurface(
          isPlaying: isPlaying,
          onPlayPause: () => isPlaying ? player.pause() : player.play(),
          onBack10: onBack10,
          onForward10: onForward10,
          onPreviousEpisode: onPreviousEpisode,
          onNextEpisode: onNextEpisode,
        );
      },
    );
  }
}
