import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../widgets/video_controls/up_next_countdown.dart';
import '../../widgets/video_controls/up_next_policy.dart';
import 'session/playback_session_types.dart';

/// Whether the player is playing now, and its play/pause stream. Null when
/// there is no player.
typedef PlayingSignal = ({bool playing, Stream<bool> changes});

/// Leaves for another episode. The screen saves progress and routes.
typedef EpisodeNavigator = Future<void> Function(
  String episodeId,
  String fileId,
  String title, {
  required int seasonNumber,
});

/// The season being played, the "Up Next" prompt and its countdown, and
/// previous/next navigation.
///
/// Holds no `BuildContext` and no `ref`. Every load-generation check stays
/// in the screen: [setSeason] is only ever handed a current answer.
class UpNextController {
  UpNextController({
    required this.fetchSeason,
    required this.isDownloaded,
    required this.navigate,
    required this.playingSignal,
    required this.isEpisode,
    required this.hasShow,
    required this.seasonNumber,
    required this.isDownloadedSource,
    required this.mounted,
    required this.onChanged,
  });

  final Future<List<PlaybackEpisode>?> Function(int seasonNumber) fetchSeason;

  /// Whether [episodeId] is on this device. May throw; a failure means no
  /// offer.
  final Future<bool> Function(String episodeId) isDownloaded;
  final EpisodeNavigator navigate;
  final PlayingSignal? Function() playingSignal;
  final bool Function() isEpisode;
  final bool Function() hasShow;
  final int? Function() seasonNumber;
  final bool Function() isDownloadedSource;
  final bool Function() mounted;

  /// Rebuild the screen. Called only while [mounted].
  final VoidCallback onChanged;

  List<PlaybackEpisode>? _seasonEpisodes;
  int? _currentIndex;

  /// The next season's episodes, fetched lazily the first time the viewer
  /// reaches the end of the current season.
  List<PlaybackEpisode>? _nextSeasonEpisodes;

  /// Whether the next-season lookup has run, whatever its outcome.
  ///
  /// Separate from [_nextSeasonEpisodes] being null, because "fetched and
  /// there is no next season" and "not fetched yet" must not look the same:
  /// [onPositionTick] runs on every position tick, so conflating them
  /// would refetch a missing season several times a second.
  bool _nextSeasonResolved = false;

  bool _showing = false;
  bool _cancelled = false;

  /// The resolved next episode, or null when nothing is on offer. Non-null
  /// implies playable: `UpNextTarget` cannot be built without a file id.
  UpNextTarget? _target;

  UpNextCountdown? _countdown;

  /// Tracks the player's playing stream while the prompt is up, so a pause
  /// holds the countdown and a resume releases it. Created alongside the
  /// countdown in [_show] and torn down everywhere the countdown is:
  /// [cancel], [playNext], [playPrevious], and [dispose]. There is no other
  /// playing-stream listener in the screen for it to piggyback on: the old
  /// countdown polled the player's playing state inside its own tick, which
  /// is exactly the coupling [UpNextCountdown] was built without.
  StreamSubscription<bool>? _playingSub;

  bool get showing => _showing;
  UpNextTarget? get target => _target;
  UpNextCountdown? get countdown => _countdown;

  /// Whether a previous episode exists in the current season's episode list.
  bool get hasPrevious =>
      _seasonEpisodes != null && _currentIndex != null && _currentIndex! > 0;

  /// Whether a next episode exists in the current season's episode list.
  bool get hasNext =>
      _seasonEpisodes != null &&
      _currentIndex != null &&
      _currentIndex! < _seasonEpisodes!.length - 1;

  /// Pure; the screen wraps it in `setState`.
  void setSeason(
    List<PlaybackEpisode> episodes, {
    required String currentEpisodeId,
  }) {
    _seasonEpisodes = episodes;
    _currentIndex = episodes.indexWhere((ep) => ep.id == currentEpisodeId);
  }

  /// Pure; the screen wraps it in `setState`.
  void clearSeason() {
    _seasonEpisodes = null;
    _currentIndex = null;
  }

  /// Forgets the next-season lookup, for a media change.
  void resetNextSeason() {
    _nextSeasonEpisodes = null;
    _nextSeasonResolved = false;
  }

  /// Show the "Up Next" overlay if conditions are met. Called on position
  /// ticks once [shouldOfferUpNext] says the credits have started.
  void onPositionTick() {
    // Don't show if already showing, cancelled, or not an episode
    if (_showing || _cancelled || !isEpisode()) {
      return;
    }

    // Check if there's a next episode
    if (_seasonEpisodes == null || _currentIndex == null) {
      return;
    }

    var target = resolveInSeasonNext(
      _candidates(_seasonEpisodes!),
      _currentIndex!,
    );

    if (target == null) {
      if (!mayCrossIntoNextSeason(
        seasonNumber: seasonNumber(),
        currentIndex: _currentIndex!,
        episodeCount: _seasonEpisodes!.length,
      )) {
        return;
      }
      // End of the season. Offer the next season's premiere, if there is one.
      if (!_nextSeasonResolved) {
        unawaited(_fetchNextSeason());
        return; // The next position tick picks it up.
      }
      final nextSeason = _nextSeasonEpisodes;
      if (nextSeason == null || nextSeason.isEmpty) return;
      target = resolveSeasonPremiere(_candidates(nextSeason));
      if (target == null) return;
    }

    // Offline/local playback can only ever autoplay into a next episode
    // that is itself already on disk: the next one existing in the season
    // is not enough, since there may be no connection to stream or fetch it
    // when the countdown lands.
    if (isDownloadedSource()) {
      unawaited(_showIfDownloaded(target));
      return;
    }

    _show(target);
  }

  Future<void> _fetchNextSeason() async {
    if (_nextSeasonResolved) return;
    final season = seasonNumber();
    if (!hasShow() || season == null) {
      _nextSeasonResolved = true;
      return;
    }
    _nextSeasonResolved = true;

    // No offer is the right failure mode: this runs fired-and-forgotten off
    // a position tick, with no caller waiting on a result.
    final episodes = await fetchSeason(season + 1);
    if (episodes == null || !mounted()) return;
    _nextSeasonEpisodes = episodes;
  }

  /// The download-gated half of [onPositionTick].
  ///
  /// Re-checks [showing] and the cancel flag after the lookup: both can
  /// change while the (async) download-manager query is in flight, e.g. the
  /// viewer already dismissed a still-pending offer some other way.
  Future<void> _showIfDownloaded(UpNextTarget target) async {
    final bool downloaded;
    try {
      downloaded = await isDownloaded(target.episodeId);
    } catch (e) {
      // Simply not offering Up Next is the right failure mode here: this
      // runs fired-and-forgotten off a position tick, with no return value
      // and no caller waiting on it, so there is nothing to propagate an
      // error to.
      debugPrint('[PlayerScreen] Could not check next-episode download: $e');
      return;
    }

    if (!mounted() || !downloaded) return;
    if (_showing || _cancelled) return;

    _show(target);
  }

  void _show(UpNextTarget target) {
    _countdown?.dispose();
    final countdown = UpNextCountdown(
      onElapsed: bindUpNextCountdownElapsed(playNext),
    );
    _countdown = countdown;

    if (!mounted()) return;
    _target = target;
    _showing = true;
    onChanged();

    // Playback being paused is its own hold, so a viewer who pauses during
    // the credits does not come back to a different episode. A live
    // subscription, not a one-shot check: a pause or resume that happens
    // while the prompt is already up must reach the countdown too.
    _playingSub?.cancel();
    final signal = playingSignal();
    if (signal != null) {
      if (!signal.playing) countdown.hold(UpNextHold.paused);
      _playingSub = signal.changes.listen((playing) {
        playing
            ? countdown.release(UpNextHold.paused)
            : countdown.hold(UpNextHold.paused);
      });
    }
    countdown.start();
  }

  /// Stops the up-next countdown and its play/pause listener.
  void _stopTimers() {
    _countdown?.cancel();
    _playingSub?.cancel();
    _playingSub = null;
  }

  /// Forgets the up-next prompt entirely, for a file that has not offered it.
  /// Pure; callers wrap it in `setState` when mounted.
  void reset() {
    _stopTimers();
    _countdown?.dispose();
    _countdown = null;
    _target = null;
    _showing = false;
    _cancelled = false;
  }

  /// Cancel the prompt and the countdown, for the rest of this file.
  void cancel() {
    // Synchronous, before any setState: a dismiss that only lands next frame
    // can lose to a fire scheduled this one.
    _stopTimers();
    if (!mounted()) return;
    _showing = false;
    _cancelled = true;
    onChanged();
  }

  /// Play the next episode immediately.
  ///
  /// [fromAutoCountdown] is true only when the up-next countdown elapsed on
  /// its own. Manual transport, keyboard, and remote actions pass false so
  /// a prior dismiss of auto-play does not block explicit navigation.
  void playNext({bool fromAutoCountdown = false}) {
    _countdown?.cancel();
    _playingSub?.cancel();
    _playingSub = null;

    // Re-check after the countdown: [cancel] may have run between
    // the fire being scheduled and this executing. Manual next is unaffected.
    if (shouldBlockAutoPlayNext(
      autoPlayCancelled: _cancelled,
      fromAutoCountdown: fromAutoCountdown,
    )) {
      return;
    }

    final target = _target;
    if (target != null) {
      unawaited(navigate(
        target.episodeId,
        target.fileId,
        target.routeTitle,
        seasonNumber: target.seasonNumber,
      ));
      return;
    }

    // Keyboard PageDown and the transport's next button reach this with no
    // prompt showing, so the in-season lookup still has to happen here.
    final episodes = _seasonEpisodes;
    final index = _currentIndex;
    if (episodes == null || index == null) return;
    final resolved = resolveInSeasonNext(_candidates(episodes), index);
    if (resolved == null) return;
    unawaited(navigate(
      resolved.episodeId,
      resolved.fileId,
      resolved.routeTitle,
      seasonNumber: resolved.seasonNumber,
    ));
  }

  /// Play the previous episode immediately.
  void playPrevious() {
    _countdown?.cancel();
    _playingSub?.cancel();
    _playingSub = null;

    if (_seasonEpisodes == null || _currentIndex == null) {
      return;
    }

    final previousIndex = _currentIndex! - 1;
    if (previousIndex < 0) {
      return;
    }

    final previousEpisode = _seasonEpisodes![previousIndex];
    final files = previousEpisode.fileIds;
    if (files == null || files.isEmpty) {
      return;
    }

    final firstFileId = files.first;
    if (firstFileId == null) {
      return;
    }

    final title =
        'S${previousEpisode.seasonNumber}E${previousEpisode.episodeNumber}${previousEpisode.title != null ? ' - ${previousEpisode.title}' : ''}';
    unawaited(navigate(
      previousEpisode.id,
      firstFileId,
      title,
      seasonNumber: previousEpisode.seasonNumber,
    ));
  }

  /// The viewer did something; resets the countdown's race guard.
  void noteInput() => _countdown?.noteInput();

  /// The prompt has the viewer's attention (focus or hover).
  void setEngaged(bool engaged) => engaged
      ? _countdown?.hold(UpNextHold.engaged)
      : _countdown?.release(UpNextHold.engaged);

  /// Adapts the generated season-episode rows to the shape the resolvers in
  /// `up_next_policy.dart` take. Keeping the resolvers off the GraphQL layer
  /// is what makes them unit testable without codegen having run.
  List<UpNextCandidate> _candidates(List<PlaybackEpisode> episodes) {
    return episodes
        .map(
          (episode) => UpNextCandidate(
            id: episode.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title ?? 'Episode ${episode.episodeNumber}',
            fileIds: (episode.fileIds ?? const <String?>[])
                .whereType<String>()
                .toList(),
            thumbnailUrl: episode.thumbnailUrl,
          ),
        )
        .toList();
  }

  void dispose() {
    _countdown?.dispose();
    _playingSub?.cancel();
    _playingSub = null;
  }
}

/// The countdown's `onElapsed` callback, bound so a fire is always marked
/// as automatic.
///
/// A tear-off of [UpNextController.playNext] would pass `fromAutoCountdown:
/// false` (the default), which is exactly the regression this helper exists
/// to prevent: after a dismiss, an elapsed countdown would navigate. Tests
/// pin this binding independently of mounting `PlayerScreen`.
@visibleForTesting
VoidCallback bindUpNextCountdownElapsed(
  void Function({bool fromAutoCountdown}) playNext,
) =>
    () => playNext(fromAutoCountdown: true);
