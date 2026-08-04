import '../../domain/models/show_next_up.dart';

/// Wide-form button text. Deliberately identical to the Phoenix web UI
/// (see lib/mydia_web/live/media_live/show/helpers.ex) so the two surfaces
/// read alike when a user moves between them.
String nextUpLabel(NextUpState state) {
  switch (state) {
    case NextUpState.continueWatching:
      return 'Continue Watching';
    case NextUpState.next:
      return 'Play Next Episode';
    case NextUpState.start:
      return 'Start Watching';
    case NextUpState.unknown:
      return 'Play';
  }
}

/// Compact word for the cue line when the button has shed its label.
String nextUpShortLabel(NextUpState state) {
  switch (state) {
    case NextUpState.continueWatching:
      return 'Continue';
    case NextUpState.next:
      return 'Next up';
    case NextUpState.start:
      return 'Start';
    case NextUpState.unknown:
      return 'Play';
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
    if (remaining != null) parts.add('$remaining min left');
  }

  return parts.join(' · ');
}
