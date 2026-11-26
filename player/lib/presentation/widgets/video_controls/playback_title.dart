import 'package:flutter/foundation.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../screens/player/session/playback_session_types.dart';

/// The two lines of the playback title block: a [title] and an optional
/// [kicker] under it (an episode's code and name, or a movie's year).
@immutable
class PlaybackTitle {
  const PlaybackTitle({required this.title, this.kicker});

  /// Builds the block from what the session knows. Without a usable show
  /// title (episode) the route's own string stays the title and there is no
  /// kicker; a movie keeps the route title and shows its year.
  factory PlaybackTitle.resolve({
    required String routeTitle,
    required bool isEpisode,
    PlaybackDetail? detail,
    required AppLocalizations l10n,
  }) {
    if (detail == null) return PlaybackTitle(title: routeTitle);
    if (!isEpisode) {
      final year = detail.year;
      return PlaybackTitle(title: routeTitle, kicker: year?.toString());
    }
    final show = _nonBlank(detail.showTitle);
    if (show == null) return PlaybackTitle(title: routeTitle);
    final season = detail.seasonNumber;
    final number = detail.episodeNumber;
    final code = season != null && number != null
        ? l10n.playerEpisodeCode(season, number)
        : null;
    final name = _nonBlank(detail.episodeTitle);
    final kicker = [code, name].whereType<String>().join(' · ');
    return PlaybackTitle(title: show, kicker: kicker.isEmpty ? null : kicker);
  }

  final String title;
  final String? kicker;

  static String? _nonBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackTitle && other.title == title && other.kicker == kicker;

  @override
  int get hashCode => Object.hash(title, kicker);
}
