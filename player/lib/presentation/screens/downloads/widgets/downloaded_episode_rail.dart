import 'package:flutter/material.dart';

import '../../../../core/layout/breakpoints.dart';
import '../../../../domain/models/download.dart';
import '../../../widgets/horizontal_rail.dart';
import 'downloaded_episode_card.dart';

/// One season's downloaded episodes, as a horizontal rail of 16:9 cards.
///
/// Fade keys are namespaced by season so a show with several seasons keeps
/// each rail's fades individually assertable.
class DownloadedEpisodeRail extends StatelessWidget {
  final List<DownloadedMedia> episodes;
  final String showId;
  final int seasonNumber;

  const DownloadedEpisodeRail({
    super.key,
    required this.episodes,
    required this.showId,
    required this.seasonNumber,
  });

  @override
  Widget build(BuildContext context) {
    return HorizontalRail(
      itemCount: episodes.length,
      height: Breakpoints.getDownloadedEpisodeRailHeight(context),
      leftFadeKey: ValueKey('downloaded-rail-$seasonNumber-left-fade'),
      rightFadeKey: ValueKey('downloaded-rail-$seasonNumber-right-fade'),
      itemBuilder: (context, index) {
        final media = episodes[index];
        return DownloadedEpisodeCard(
          key: ValueKey(media.mediaId),
          media: media,
          showId: showId,
        );
      },
    );
  }
}
