import 'package:flutter/material.dart';
import '../../core/layout/breakpoints.dart';
import '../../domain/detail/detail_views.dart';
import '../screens/detail/detail_actions.dart';
import 'episode_rail_card.dart';
import 'horizontal_rail.dart';

/// A horizontal rail of [EpisodeRailCard]s.
///
/// Scroll mechanics and edge fades come from [HorizontalRail]; this widget
/// only maps episodes onto landscape cards and sizes the rail for the two-line
/// label strip beneath each thumbnail.
class EpisodeRail extends StatelessWidget {
  final List<EpisodeView> episodes;

  /// Invoked when a playable episode card is tapped.
  final ValueChanged<EpisodeView>? onEpisodeTap;
  final String? selectedEpisodeId;

  /// Reports a watched-menu choice for one episode. Null hides the menu.
  final Future<void> Function(EpisodeView, EpisodeWatchedAction)?
      onWatchedAction;

  const EpisodeRail({
    super.key,
    required this.episodes,
    this.onEpisodeTap,
    this.selectedEpisodeId,
    this.onWatchedAction,
  });

  @override
  Widget build(BuildContext context) {
    return HorizontalRail(
      itemCount: episodes.length,
      height: Breakpoints.getEpisodeRailHeight(context),
      leftFadeKey: const ValueKey('episode-rail-left-fade'),
      rightFadeKey: const ValueKey('episode-rail-right-fade'),
      itemBuilder: (context, index) {
        final episode = episodes[index];
        return EpisodeRailCard(
          key: ValueKey(episode.id),
          episode: episode,
          selected: episode.id == selectedEpisodeId,
          onTap: episode.hasFile && onEpisodeTap != null
              ? () => onEpisodeTap!(episode)
              : null,
          onWatchedAction: onWatchedAction == null
              ? null
              : (action) => onWatchedAction!(episode, action),
        );
      },
    );
  }
}
