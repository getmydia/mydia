import '../../domain/models/show_next_up.dart';
import '../../l10n/l10n.dart';

/// Wide-form button text. Matches the Phoenix web UI
/// (see lib/mydia_web/live/media_live/show/helpers.ex) so the two surfaces
/// read alike when a user moves between them.
String nextUpLabel(AppLocalizations l10n, NextUpState state) {
  switch (state) {
    case NextUpState.continueWatching:
      return l10n.nextUpContinueWatching;
    case NextUpState.next:
      return l10n.nextUpPlayNextEpisode;
    case NextUpState.start:
      return l10n.nextUpStartWatching;
    case NextUpState.unknown:
      return l10n.commonPlay;
  }
}

/// Compact word for the cue line when the button has shed its label.
String nextUpShortLabel(AppLocalizations l10n, NextUpState state) {
  switch (state) {
    case NextUpState.continueWatching:
      return l10n.nextUpContinue;
    case NextUpState.next:
      return l10n.nextUpNextUp;
    case NextUpState.start:
      return l10n.nextUpStart;
    case NextUpState.unknown:
      return l10n.commonPlay;
  }
}

/// Minutes left in [episode], or null when no source gives a usable duration.
///
/// Prefers the duration recorded during playback over provider metadata: the
/// episodes table has no runtime column, so `runtime` comes from embedded
/// TVDB/TMDB metadata and is often missing, whereas an episode in the
/// continue state has by definition been played.
int? remainingMinutes(NextUpEpisode episode) {
  final progress = episode.progress;
  if (progress == null) return null;

  // Progress.positionSeconds is non-nullable; only the whole Progress is
  // optional, so there is nothing further to null-check here.
  final position = progress.positionSeconds;

  final recorded = progress.durationSeconds;
  if (recorded != null && recorded > position) {
    return ((recorded - position) / 60).round();
  }

  final runtime = episode.runtimeMinutes;
  if (runtime != null) {
    final remaining = runtime - (position / 60).round();
    if (remaining > 0) return remaining;
  }

  return null;
}

/// Secondary line under the play control.
String nextUpCueLine(
  AppLocalizations l10n,
  NextUpEpisode episode,
  NextUpState state, {
  String? resolution,
}) {
  final parts = <String>[episode.episodeCode];

  if (resolution != null && resolution.isNotEmpty) {
    parts.add(resolution);
  }

  if (state == NextUpState.continueWatching) {
    final remaining = remainingMinutes(episode);
    if (remaining != null) parts.add(l10n.nextUpMinutesLeft(remaining));
  }

  return parts.join(' · ');
}
