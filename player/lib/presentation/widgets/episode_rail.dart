import 'package:flutter/material.dart';
import '../../core/layout/breakpoints.dart';
import '../../domain/models/episode.dart';
import 'episode_rail_card.dart';
import 'horizontal_rail.dart';

/// A horizontal rail of [EpisodeRailCard]s.
///
/// Scroll mechanics and edge fades come from [HorizontalRail]; this widget
/// only maps episodes onto landscape cards and sizes the rail for the two-line
/// label strip beneath each thumbnail.
class EpisodeRail extends StatelessWidget {
  final List<Episode> episodes;
  final String showTitle;
  final String? showId;
  final String? showPosterUrl;

  /// Invoked when a playable episode card is tapped.
  final ValueChanged<Episode>? onEpisodeTap;
  final String? selectedEpisodeId;

  const EpisodeRail({
    super.key,
    required this.episodes,
    required this.showTitle,
    this.showId,
    this.showPosterUrl,
    this.onEpisodeTap,
    this.selectedEpisodeId,
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
          showTitle: showTitle,
          showId: showId,
          showPosterUrl: showPosterUrl,
          selected: episode.id == selectedEpisodeId,
          onTap: episode.hasFile && onEpisodeTap != null
              ? () => onEpisodeTap!(episode)
              : null,
        );
      },
    );
  }
}
