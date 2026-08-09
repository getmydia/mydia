import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/colors.dart';

/// What a card's long-press menu can offer.
enum MediaContextAction { play, goToShow, episodeDetails, movieDetails }

/// The subject of a long-press menu, flattened out of whichever rail item the
/// card was built from.
///
/// The menu deliberately knows nothing about `ContinueWatchingItem`,
/// `UpNextItem` or `RecentlyAddedItem`. Each converts itself into one of these
/// where the card is built, so a new rail item type needs no change here.
class MediaContextTarget {
  /// What the card depicts: a movie id or an episode id.
  final String id;

  /// 'movie', 'tv_show', or 'episode'.
  final String type;

  /// The owning series, when the target is an episode that knows it.
  final String? showId;

  /// Whether the target has a playable file.
  final bool hasFile;

  /// Whether the card body already starts playback. Only a card that plays
  /// earns a details entry, because a card that already opens the title would
  /// be offering a second route to where its own tap goes.
  final bool tapPlays;

  const MediaContextTarget({
    required this.id,
    required this.type,
    this.showId,
    this.hasFile = false,
    this.tapPlays = false,
  });

  bool get isEpisode => type.toLowerCase() == 'episode';
  bool get isMovie => type.toLowerCase() == 'movie';
}

/// The entries [target] earns, in display order.
///
/// Pure, so the visibility rules are unit-testable without pumping a menu.
/// An empty result means the card gets no menu at all.
List<MediaContextAction> mediaContextActionsFor(MediaContextTarget target) {
  // A card whose own tap opens the title earns no menu at all. Gating only
  // `movieDetails` on this left two holes: an episode target got
  // `episodeDetails` regardless, duplicating what its tap already did, and any
  // target with a file got `play` even where the rail had no play handler to
  // run, since `_openMenu` routes Play through a nullable `onItemActivate`.
  // That is a Play entry that silently does nothing.
  if (!target.tapPlays) return const [];

  return [
    if (target.hasFile) MediaContextAction.play,
    if (target.showId != null) MediaContextAction.goToShow,
    if (target.isEpisode) MediaContextAction.episodeDetails,
    if (target.isMovie) MediaContextAction.movieDetails,
  ];
}

/// Menu copy for [action].
String mediaContextLabel(MediaContextAction action) => switch (action) {
      MediaContextAction.play => 'Play',
      MediaContextAction.goToShow => 'Go to show',
      MediaContextAction.episodeDetails => 'Episode details',
      MediaContextAction.movieDetails => 'Movie details',
    };

/// Menu glyph for [action].
IconData mediaContextIcon(MediaContextAction action) => switch (action) {
      MediaContextAction.play => Icons.play_arrow_rounded,
      MediaContextAction.goToShow => Icons.tv_rounded,
      MediaContextAction.episodeDetails => Icons.info_outline_rounded,
      MediaContextAction.movieDetails => Icons.info_outline_rounded,
    };

/// Opens the card's secondary menu, anchored under the card.
///
/// Wired to long-press on touch and to secondary tap on desktop, which is how
/// Infuse exposes the same actions on iOS and on the Mac. [context] must be a
/// context inside the card, since its render object is the anchor.
///
/// A [showMenu] popup rather than a modal bottom sheet: this reads correctly at
/// 400px and at 1600px, and matches the `PopupMenuButton` already used by
/// `EpisodeRailCard`, `ShowDetailScreen` and `CollectionDetailScreen`.
Future<void> showMediaContextMenu(
  BuildContext context, {
  required MediaContextTarget target,
  required VoidCallback onPlay,
}) async {
  final actions = mediaContextActionsFor(target);
  if (actions.isEmpty) return;

  final anchor = context.findRenderObject();
  final overlay = Overlay.of(context).context.findRenderObject();
  if (anchor is! RenderBox || overlay is! RenderBox) return;

  final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlay);
  final position = RelativeRect.fromLTRB(
    topLeft.dx,
    topLeft.dy + anchor.size.height,
    overlay.size.width - topLeft.dx - anchor.size.width,
    0,
  );

  final selected = await showMenu<MediaContextAction>(
    context: context,
    position: position,
    items: [
      for (final action in actions)
        PopupMenuItem<MediaContextAction>(
          value: action,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                mediaContextIcon(action),
                size: 18,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Text(mediaContextLabel(action)),
            ],
          ),
        ),
    ],
  );

  if (selected == null || !context.mounted) return;

  switch (selected) {
    case MediaContextAction.play:
      onPlay();
    case MediaContextAction.goToShow:
      final showId = target.showId;
      if (showId != null) context.push('/show/$showId');
    case MediaContextAction.episodeDetails:
      context.push('/episode/${target.id}');
    case MediaContextAction.movieDetails:
      context.push('/movie/${target.id}');
  }
}
