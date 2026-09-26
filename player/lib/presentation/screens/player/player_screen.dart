import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, listEquals;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../../../core/app_menu/now_playing.dart';
import '../../../core/auth/auth_status.dart';
import '../../../core/connection/connection_provider.dart' as conn;
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/invalidation_rules.dart';
import '../../../core/graphql/watch/watcher_registry.dart';
import '../../../core/player/audio_language.dart';
import '../../../core/player/codec_support.dart';
import '../../../core/player/hls_engine.dart';
import '../../../core/player/media_start.dart';
import '../../../core/player/subtitle_cues.dart';
import '../../../core/player/player_orientation_lease_controller.dart';
import '../../../core/player/progress_service.dart';
import '../../../core/player/subtitle_stream_index.dart';
import '../../../core/player/image_subtitle_sidecar.dart';
import '../../../core/player/subtitle_delay.dart';
import '../../../core/player/subtitle_render.dart';
import '../../../core/player/video_output_config.dart';
import '../../../core/player/scrub_controller.dart';
import '../../../core/player/scrub_thumbnails.dart';
import '../../../core/player/thumbnail_service.dart';
import '../../../core/player/tracks_ready.dart';
import '../../../core/playback/isolated_fetches.dart';
import '../../../core/playback/playback_progress_providers.dart';
import '../../../core/playback/playback_progress_store.dart';
import '../../../core/startup/startup_timeline.dart';
import '../../../core/utils/file_utils.dart' as file_utils;
import '../../../core/utils/web_lifecycle.dart' as web_lifecycle;
import '../../../core/player/fullscreen/fullscreen_controller.dart';
import '../../../core/player/fullscreen/fullscreen_failure.dart';
import '../../../core/player/fullscreen/fullscreen_report_signal.dart';
import '../../../core/player/input_capabilities.dart';
import '../../../core/player/platform_features.dart';
import '../../../core/player/playback_error.dart';
import '../../../core/player/stream_timeline.dart';
import '../../../core/playback/candidates_from_graphql.dart';
import '../../../core/playback/adaptation_policy.dart';
import '../../../core/playback/frame_stats_sampler.dart';
import '../../../core/playback/health_sample.dart';
import '../../../core/playback/playback_monitor.dart';
import '../../../core/playback/quality_choice.dart';
import '../../../core/playback/seek_decision.dart';
import '../../../core/playback/source_switch_gate.dart';
import '../../../core/playback/playback_controller.dart';
import '../../../core/playback/link_path.dart';
import '../../../core/playback/playback_memory.dart';
import '../../../core/playback/playback_memory_providers.dart';
import '../../../core/playback/playback_plan.dart';
import '../../../core/playback/playback_planner.dart';
import '../../../core/playback/quality_display.dart';
import '../../../core/playback/local_playback_state.dart';
import '../../../core/cast/cast_backend.dart';
import '../../../core/cast/cast_providers.dart';
import '../../../core/cast/cast_session_manager.dart';
import '../../../core/cast/cast_target.dart';
import '../../../core/downloads/download_providers.dart';
import '../../widgets/resume_dialog.dart';
import '../../widgets/subtitle_track_selector.dart';
import '../../widgets/audio_track_selector.dart';
import '../../widgets/hls_quality_selector.dart';
import '../../widgets/gesture_controls.dart';
import '../../widgets/cast_actions.dart';
import '../../widgets/cast_device_picker.dart';
import '../../widgets/video_controls/cast_chrome_icon.dart';
import '../../widgets/video_controls/chrome_top_bar.dart';
import '../../widgets/video_controls/custom_video_controls.dart';
import '../../widgets/video_controls/playback_chrome.dart';
import '../../widgets/video_controls/skip_segment_button.dart';
import '../../widgets/video_controls/chrome_panel.dart';
import '../../widgets/tap_to_play_overlay.dart';
import '../../widgets/video_controls/up_next_countdown.dart';
import '../../widgets/video_controls/up_next_policy.dart';
import '../../widgets/video_controls/up_next_prompt.dart';
import '../../widgets/toast/toaster.dart';
import '../../../domain/models/audio_track.dart' as app_models_audio;
import '../../../domain/models/media_segment.dart';
import '../../../domain/models/quality_delivery_subtitle.dart';
import '../../../domain/models/quality_rung.dart';
import '../../../domain/models/subtitle_candidate.dart';
import '../../../domain/models/subtitle_track.dart' as app_models;
import '../../../domain/models/cast_device.dart';
import '../../../domain/models/download.dart';
import '../../../graphql/schema.graphql.dart';
import '../../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../../graphql/queries/movie_detail.graphql.dart';
import '../../../graphql/queries/episode_detail.graphql.dart';
import '../../../graphql/queries/media_segments.graphql.dart';
import '../../../graphql/queries/season_episodes.graphql.dart';
import '../../../graphql/mutations/set_audio_language_preference.graphql.dart';
import '../../../graphql/mutations/set_subtitle_preference.graphql.dart';
import '../../../graphql/queries/streaming_candidates.graphql.dart';
import '../../../graphql/queries/subtitle_content.graphql.dart';
import '../../../graphql/queries/subtitle_search.graphql.dart';
import '../../../graphql/queries/subtitle_track_settings.graphql.dart';
import '../../../graphql/queries/subtitle_preference.graphql.dart';
import '../../../graphql/mutations/download_subtitle.graphql.dart';
import '../../../graphql/mutations/set_subtitle_offset.graphql.dart';
import '../../../core/p2p/media_proxy.dart';
import '../../../core/p2p/media_proxy_factory.dart';
import '../../../core/playback/server_features.dart';
import '../../../core/playback/stream_urls.dart';
import '../../../core/window/desktop_window.dart';
import '../../../core/window/player_window_sizer.dart';
import '../../../core/player/resume_plan.dart';
import '../../../core/remote/remote_control_intent.dart';
import '../../../core/remote/remote_target_controller.dart';
import '../../../native/lib.dart';
import '../../../core/connection/connection_summary.dart';
import '../../../core/p2p/p2p_service.dart';
import '../../../core/playback/stats/playback_stats.dart';
import '../../../core/playback/stats/playback_stats_collector.dart';
import '../../../core/playback/stats/stats_metrics.dart';
import '../../../core/playback/stats/stats_report.dart';
import '../../../core/settings/stats_overlay_setting.dart';
import '../../../core/update/update_provider.dart';
import '../../widgets/playback_stats/stats_panel.dart';
import '../settings/settings_controller.dart';
import 'stats_context_builder.dart';
import 'subtitle_content_query.dart';
import 'subtitle_preference.dart';
import 'subtitle_selection_target.dart';
import 'subtitle_track_builder.dart';

export '../../../core/player/resume_plan.dart'
    show
        kMinResumeThresholdSeconds,
        kEndOfMediaThresholdSeconds,
        kWatchedThreshold,
        shouldOfferResume;

/// How many times a subtitle preference may retake a one-shot a track-list
/// revision superseded. Three is well past any revision count media_kit
/// produces in practice; it is a stop, not a budget.
const int _maxPreferenceApplyRetries = 3;

/// What an arrow key press means in the player.
///
/// A remote's D-pad and a keyboard's arrows deliver the same key codes, so one
/// handler serves both, but they cannot mean the same thing. A keyboard viewer
/// has a pointer and a volume slider; a remote viewer has neither, and the
/// only focusable things on screen are the OSD controls, which are not there
/// while the OSD is hidden.
enum ArrowIntent {
  seekBackward,
  seekForward,

  /// Start or continue a D-pad scrub: the directional-tier answer for left
  /// and right with the OSD hidden. A remote has no pointer to drag the bar
  /// with, so the press reveals the OSD and moves a cursor instead of seeking.
  scrubBackward,
  scrubForward,
  volumeUp,
  volumeDown,

  /// Show the OSD. The directional-tier answer for up and down, which have no
  /// volume to change: on a television that belongs to the remote and the
  /// receiver, and binding it means one press changes two volumes.
  revealChrome,

  /// Let the key fall through to focus traversal, so it walks the OSD's
  /// controls. Returning this means the handler must report `ignored`.
  traverse,
}

/// What a Back press does in the player.
///
/// On a remote, Back is the only way out of anything, so it peels one layer
/// at a time. Everywhere else it leaves the player.
enum BackAction { cancelScrub, hideChrome, pop }

class PlayerScreen extends ConsumerStatefulWidget {
  final String mediaId;
  final String mediaType;
  final String fileId;
  final String? title;
  final String? showId;
  final int? seasonNumber;
  final int? resumeSeconds;

  /// Track ids to select once playback opens, in the same id space
  /// [selectTrack] already accepts. Null means "leave whatever this file
  /// opens on" — the existing behaviour for every call site that predates
  /// remote control, where nothing ever requested a specific track.
  final String? audioTrack;
  final String? subtitleTrack;

  /// Whether to start playing once the media opens. Defaults to true, which
  /// is what every call site did before this field existed: opening this
  /// screen has always meant "play now". A remote `LoadContent` with
  /// `autoplay: false` is the one caller that passes false, to load a title
  /// cued up without starting it.
  final bool autoplay;

  /// Creates the playback engine. Reused across native source switches.
  final Player Function()? createPlayer;

  /// Creates the window sizer. Null uses [createPlayerWindowSizer]; tests
  /// pass a recording fake to see whether the window was re-attached.
  @visibleForTesting
  final PlayerWindowSizer Function()? createWindowSizer;

  const PlayerScreen({
    super.key,
    required this.mediaId,
    required this.mediaType,
    required this.fileId,
    this.title,
    this.showId,
    this.seasonNumber,
    this.resumeSeconds,
    this.audioTrack,
    this.subtitleTrack,
    this.autoplay = true,
    this.createPlayer,
    this.createWindowSizer,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();

  /// The player's outer frame: a black [Scaffold] with a [SafeArea] that
  /// only insets the sides and bottom, never the top.
  ///
  /// `top: false` is deliberate on every platform, not just macOS. On macOS
  /// windowed, `WindowChromeInset` folds `kMacTitleBarOverlap` into
  /// `MediaQuery.padding.top` app-wide so `SafeArea`/`AppBar` clear the
  /// traffic lights for free; a bare `SafeArea` here would consume that same
  /// strip a second time, pushing the media_kit `Video` down by
  /// `kMacTitleBarOverlap` and putting a black band above every video —
  /// `NativePlayerWindowSizer` then snaps the window to the video's aspect
  /// ratio *without* that inset, so media_kit adds side pillars too.
  /// `playback_chrome.dart`'s own `SafeArea` keeps the same `top: false` for
  /// the same reason; its top bar is placed by `PlayerTopBarSlot` instead,
  /// which reads `WindowChromeInsets` directly to sit level with the window
  /// controls on a windowed desktop, or 16px below the safe area's own
  /// `padding.top` everywhere else. `_withCastAffordance`'s loading/error
  /// cast pill goes through that same slot, so it never drifts from where
  /// playback puts it.
  ///
  /// On iOS this also puts the video full-bleed under the notch, which is
  /// intentional, not a side effect: this is an immersive video player, the
  /// controls keep their own `SafeArea`, and edge-to-edge video is what
  /// video players do.
  ///
  /// Public and `@visibleForTesting` so a test can assert the seam directly
  /// (see `player_screen_frame_inset_test.dart`) without mounting the full
  /// screen, which needs a live player controller and platform channels.
  @visibleForTesting
  static Widget playerFrame({required Widget child}) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(top: false, child: child),
      );

  /// Stands in for the platform fullscreen backend while a test is mounted.
  ///
  /// The real one is chosen by a conditional import, so a `flutter test` host
  /// always gets the native backend, which is unconditionally ready. That makes
  /// the case this change exists for — a route that exists but cannot be used
  /// right now, so the button must not draw — unreachable without a seam. The
  /// controller is a field initializer with no constructor to thread an
  /// argument through, hence a static rather than a parameter.
  ///
  /// Null in production, and a test that sets it must clear it.
  @visibleForTesting
  static FullscreenBackendFactory? debugFullscreenBackendFactory;

  /// Whether this build should install the playback key handler.
  ///
  /// Exposed as a pure predicate rather than inlined at the call site so it
  /// can be checked for every platform combination from one non-web host,
  /// for the same reason `PlatformFeatures.computeSupportsKeyboardShortcuts`
  /// is. Before the directional term, a television fell through both arms:
  /// `supportsKeyboardShortcuts` covers desktop and web only, so a remote's
  /// D-pad reached nothing.
  @visibleForTesting
  static bool wantsKeyHandling({
    required bool supportsKeyboardShortcuts,
    required bool directionalPrimary,
  }) =>
      supportsKeyboardShortcuts || directionalPrimary;

  /// Whether to pin the display to landscape on entering playback.
  ///
  /// A television is already landscape and has no sensor to rotate, so the
  /// request is at best a no-op. It reads `isMobile`, which Android TV
  /// answers true, so it needs the directional term to opt back out.
  @visibleForTesting
  static bool wantsForcedLandscape({
    required bool isMobile,
    required bool directionalPrimary,
  }) =>
      isMobile && !directionalPrimary;

  /// Resolves an arrow key to its meaning for this input tier and OSD state.
  ///
  /// Pure and exposed for testing, for the same reason
  /// `PlatformFeatures.computeSupportsKeyboardShortcuts` is: the tier is a
  /// runtime platform answer that a single test host cannot vary.
  @visibleForTesting
  static ArrowIntent resolveArrowIntent({
    required LogicalKeyboardKey key,
    required bool directionalPrimary,
    required bool chromeVisible,
  }) {
    if (directionalPrimary && chromeVisible) return ArrowIntent.traverse;

    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        return directionalPrimary
            ? ArrowIntent.scrubBackward
            : ArrowIntent.seekBackward;
      case LogicalKeyboardKey.arrowRight:
        return directionalPrimary
            ? ArrowIntent.scrubForward
            : ArrowIntent.seekForward;
      case LogicalKeyboardKey.arrowUp:
        return directionalPrimary
            ? ArrowIntent.revealChrome
            : ArrowIntent.volumeUp;
      case LogicalKeyboardKey.arrowDown:
        return directionalPrimary
            ? ArrowIntent.revealChrome
            : ArrowIntent.volumeDown;
      default:
        return ArrowIntent.traverse;
    }
  }

  /// Resolves a Back press for this input tier and state.
  ///
  /// Pure and exposed for testing, like [resolveArrowIntent]. Cancelling a
  /// scrub comes before hiding the OSD: the viewer is looking at the cursor,
  /// and Back meaning "never mind" is what every television player does.
  @visibleForTesting
  static BackAction resolveBackAction({
    required bool directionalPrimary,
    required bool scrubActive,
    required bool chromeBlocksBack,
  }) {
    if (!directionalPrimary) return BackAction.pop;
    if (scrubActive) return BackAction.cancelScrub;
    if (chromeBlocksBack) return BackAction.hideChrome;
    return BackAction.pop;
  }
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    implements RemotePlayerBinding {
  Player? _player;
  VideoController? _videoController;
  ProgressService? _progressService;

  /// Play-to-first-frame marks for this screen's current load. Replaced on
  /// every `_initializePlayer` run, so a source restart times itself.
  StartupTimeline? _playTimeline;

  /// Watches `player.stream.width` for the first positive width, marks
  /// `first_frame` and logs the timeline, then cancels itself. Re-bound
  /// every time `_openPlayerAndStart` runs for a new source, and cancelled
  /// in `dispose` so it never outlives the screen.
  StreamSubscription<int?>? _firstFrameSubscription;

  /// Captured in [initState] rather than read from `dispose()`, for the same
  /// reason as [_invalidator]: `remoteTargetControllerProvider` is a plain
  /// (non-autoDispose) provider, so this stays the same live instance for
  /// the container's lifetime and is safe to call after the widget's
  /// element is defunct.
  late final RemoteTargetController _remoteTargetController;

  /// Set once the offline or already-downloaded branch of
  /// [_initializePlayer] resolves [playbackProgressStoreProvider]. Null
  /// whenever that resolution failed, so a broken box open cannot block
  /// playback; `_saveProgress` treats a null store the same as one that was
  /// never needed.
  PlaybackProgressStore? _progressStore;

  /// True once the offline or already-downloaded branch of
  /// [_initializePlayer] runs. Downloaded media is the only source that can
  /// be played with no server in reach, so it is the only one `_saveProgress`
  /// writes locally for; streaming playback writes straight to the server,
  /// which is reachable by definition.
  bool _isDownloadedSource = false;

  /// Captured in [initState] rather than read from `dispose()`: by the time
  /// `dispose()` runs the widget's element may already be defunct, and
  /// `ref.read` on a disposed `ConsumerState` is not safe.
  /// `invalidatorProvider` is a keepAlive root provider, so the
  /// `Invalidator` it returns does not depend on the widget's element and
  /// stays valid to call after disposal.
  late final Invalidator _invalidator;

  /// `mediaProxyProvider` is a plain (non-autoDispose) provider, so it
  /// is effectively keep-alive for this container's lifetime — the same
  /// instance `ref.read` would return at any later point. Safe to capture
  /// once here, exactly like [_invalidator], and used by
  /// [_terminateHlsSession] instead of a `dispose()`-time `ref.read`.
  late final MediaProxy _mediaProxy;

  /// The most recently resolved GraphQL client, kept in sync via
  /// `ref.listenManual` rather than read in `dispose()`: a long
  /// playback session can outlive a token refresh or reconnect that
  /// produces a new client, so this is refreshed continuously rather than
  /// captured once. Null until the first resolution completes;
  /// [_terminateHlsSession] treats a still-null client the same as any
  /// other best-effort failure (already caught and logged there).
  GraphQLClient? _graphqlClient;

  /// Set once the 90% watched threshold is first crossed, so the invalidation
  /// fires once per playback rather than on every position tick.
  bool _watchedInvalidationSent = false;

  StreamSubscription<Duration>? _positionSubscription;

  /// Keeps the audio track list current as media_kit revises it. Detection
  /// cannot be a one-shot sample after `open()`: mpv publishes tracks only
  /// once it has probed the file, and a probe that outruns the sample used to
  /// leave the selector empty for the rest of the session.
  StreamSubscription<Tracks>? _tracksSubscription;

  /// media_kit reports playback failures asynchronously, long after
  /// [Player.open] has returned, so the try/catch around initialisation cannot
  /// see them. Without this the failure has nowhere to go: the screen sits
  /// there with its loading state cleared and its timeline running off the
  /// duration the server supplied, and a stream that never delivers a byte
  /// looks exactly like one that is merely dark.
  StreamSubscription<String>? _errorSubscription;

  /// The furthest real playback position observed so far, seeded with the
  /// resume offset so a seek is not mistaken for progress.
  Duration _furthestPosition = Duration.zero;

  /// Whether playback has ever actually moved forward.
  ///
  /// This gates [_onPlaybackError], and the gate is the whole reason that
  /// handler is safe. media_kit's error stream carries every mpv log line at
  /// error level, which includes recoverable decoder (`vd`/`ad`) and network
  /// (`ffmpeg tcp:`) complaints that a healthy stream shrugs off. Replacing a
  /// playing video with an error page over one of those would be a worse bug
  /// than the one this exists to fix. A stream that has never advanced is not
  /// having a hiccup: it never played at all, and a black screen is all the
  /// viewer would otherwise get.
  bool _playbackAdvanced = false;
  bool _isLoading = true;
  String? _error;

  /// Whether the browser refused to start playback for want of a user gesture.
  ///
  /// Deliberately not an [_error]. By the time this is set the media is open
  /// and ready and only the *start* was declined, so the video is shown with a
  /// play affordance over it rather than torn down for an error screen. See
  /// [_onPlaybackError].
  ///
  /// Only ever true on web, and [_onPlaybackError] gates on `kIsWeb` to keep
  /// that true by construction rather than by trusting mpv never to phrase an
  /// error the way a browser does. Every browser requires a live user
  /// activation to start an unmuted video, and on a cold start nothing here
  /// can promise one:
  /// the tap that asked for playback is separated from [Player.play] by a
  /// route change, the candidates and progress queries, `StartStreamingSession`
  /// and the open itself. Over a remote server that routinely outlasts the
  /// activation window, which is why this is a state to recover from rather
  /// than a race to try to win.
  bool _autoplayBlocked = false;

  String? _loadingMessage;
  int? _savedPositionSeconds;
  int? _savedDurationSeconds;

  /// When the server last recorded progress for this media, populated by
  /// [_fetchProgressAndEpisodes]. Feeds [pickNewerProgress] on the
  /// downloaded-online branch, which needs a timestamp to decide whether the
  /// server's record or a local one written offline is more recent.
  DateTime? _serverLastWatchedAt;

  /// Set when a seek forced a session restart, so re-initialization starts at
  /// this position instead of re-asking about the saved progress position.
  int? _resumeOverrideSeconds;

  /// Reads and clears the pending resume override.
  ///
  /// Consume-once matters: a seek-driven restart sets this field too, and a
  /// value that survived would re-apply on every later re-initialization.
  int? _consumeResumeOverride() {
    final value = _resumeOverrideSeconds;
    _resumeOverrideSeconds = null;
    return value;
  }

  int? _runtimeMinutes;
  List<Query$SeasonEpisodes$seasonEpisodes>? _seasonEpisodes;
  int? _currentEpisodeIndex;

  /// The next season's episodes, fetched lazily the first time the viewer
  /// reaches the end of the current season.
  List<Query$SeasonEpisodes$seasonEpisodes>? _nextSeasonEpisodes;

  /// Whether the next-season lookup has run, whatever its outcome.
  ///
  /// Separate from [_nextSeasonEpisodes] being null, because "fetched and
  /// there is no next season" and "not fetched yet" must not look the same:
  /// `_maybeShowUpNext` runs on every position tick, so conflating them
  /// would refetch a missing season several times a second.
  bool _nextSeasonResolved = false;

  /// The client `_fetchSeasonEpisodes` was handed, kept so the next-season
  /// lookup can run from a position tick, where no client is in scope.
  GraphQLClient? _graphQLClient;

  // Track selection state
  /// The subtitle tracks the *server* reported for this file, exactly as
  /// `MediaFileFragment` delivered them: embedded tracks ffprobe found, plus
  /// sidecars from the database.
  ///
  /// The source of truth, and never overwritten by track detection.
  /// [_subtitleTracks] is derived from this together with whatever media_kit
  /// has probed (see [_applySubtitleTracks]).
  ///
  /// Keeping the two apart is what makes detection re-runnable. The
  /// direct-play branch used to assign media_kit's own list straight over
  /// the one field, so a probe that finished after the fixed sample taken
  /// just after `open()` left an empty list with the server's tracks already
  /// discarded, and nothing could rebuild it.
  List<app_models.SubtitleTrack> _serverSubtitleTracks = [];

  /// The tracks actually offered to the viewer in the subtitle sheet.
  /// Derived: never assigned outside [_applySubtitleTracks].
  List<app_models.SubtitleTrack> _subtitleTracks = [];
  app_models.SubtitleTrack? _selectedSubtitleTrack;
  List<app_models_audio.AudioTrack> _audioTracks = [];
  app_models_audio.AudioTrack? _selectedAudioTrack;

  /// Audio languages this playback should open on, most preferred first, as
  /// resolved by the server from the operator's config and the item's own
  /// original language.
  ///
  /// Populated from the streaming-candidates response and applied to mpv
  /// before the media opens. Empty means no opinion — a server that predates
  /// the field, a failed candidates call, or an operator who asked for the
  /// container's `default` flag to win — and mpv keeps its own selection.
  List<String> _preferredAudioLanguages = const [];

  /// The target of the subtitle selection attempt currently in flight, or
  /// most recently concluded — as opposed to [_selectedSubtitleTrack],
  /// which only reflects what has actually taken effect on the player.
  ///
  /// The no-op guard at the top of [_showSubtitleSelector] compares the
  /// sheet's result against this, not against [_selectedSubtitleTrack] (see
  /// [shouldStartSubtitleSelection]). Comparing against the applied value
  /// would mean a tap matching whatever is still displayed as current —
  /// because its own request hasn't resolved yet — is invisible to the
  /// guard and gets silently dropped instead of registering as a retry or
  /// a cancel.
  ///
  /// `null` means no attempt is in flight, which is not the same as "Off is
  /// the requested state": that is [TargetOff]. Conflating them is what let a
  /// sheet Off tapped from a clean state be dropped before it could be
  /// applied or remembered. See [SubtitleSelectionTarget].
  ///
  /// Written once, up front, to whatever a call is requesting, and — this
  /// is the part a second review round found missing — reverted by
  /// [_resetPendingSubtitleSelection] on every exit that concludes without
  /// applying. Left un-reverted, a failed fetch stuck this at the track
  /// that had just failed, so re-tapping that exact track (the natural
  /// response to a "could not load, try again" toast) matched this
  /// field and was silently swallowed by the no-op guard rather than
  /// starting a genuine retry. See [pendingSubtitleSelectionAfterFailure].
  ///
  /// [_selectedSubtitleTrack] and this field are allowed to disagree while
  /// a request is in flight — that's the whole point of tracking them
  /// separately — and the sheet still displays [_selectedSubtitleTrack] as
  /// checked, not this. Showing the viewer that a selection is pending is
  /// a UI concern for whichever task rebuilds this sheet with real
  /// loading states; this field only exists to make the *comparison*
  /// correct in the meantime.
  SubtitleSelectionTarget? _pendingSubtitleSelection;

  /// Bumped on every non-no-op call into [_showSubtitleSelector].
  ///
  /// A subtitle selection now does real async work (an "Off" call to
  /// media_kit, or a content fetch in [_resolveMediaKitSubtitleTrack]), and
  /// the tap that starts it is fire-and-forget from a sheet that has
  /// already closed, so nothing stops the viewer from picking again before
  /// the first pick resolves. Each call captures the generation it was
  /// issued under; [_canApplySubtitleSelection] re-checks it (together with
  /// `mounted` and whether a player still exists) after every await before
  /// that call is allowed to commit [_selectedSubtitleTrack] or touch the
  /// player. Whichever call the viewer made *last* is the one whose
  /// generation is still current when its work finishes, so it is the only
  /// one that can win; an earlier call that resolves later — a slow
  /// network response losing a race to a fast "Off" tap, for instance —
  /// recognises it has been superseded and backs off instead of fighting
  /// the newer choice for control of the player. Bumped before the
  /// no-player bailout in [_showSubtitleSelector], not after: an in-flight
  /// call from *before* this tap must count as superseded even when this
  /// tap itself has no player to act on.
  int _subtitleSelectionGeneration = 0;

  /// Whether the viewer picked a subtitle, or "Off", this playback.
  ///
  /// What tells "the viewer chose Off" from "the viewer never chose", which
  /// [_pendingSubtitleSelection] cannot: both are null there. A source
  /// switch carries the first and leaves mpv to its own defaults for the
  /// second. Cleared by [_initializePlayer].
  bool _subtitleChosenThisPlayback = false;

  /// What the server says this viewer wants for this show, folding their own
  /// per-show pick over the operator default. Null means no opinion, and the
  /// file is left to do whatever it would have done.
  SubtitlePreference? _subtitlePreference;

  /// The tail of the per-show preference write queue.
  ///
  /// The server's upsert is unconditional, so two writes handed to the
  /// transport at once land in whatever order the network gives them and the
  /// earlier pick can win. Chaining them keeps the order the viewer picked in.
  /// Per screen is the right scope: the case that exists is one viewer tapping
  /// twice.
  Future<void> _subtitlePreferenceWrite = Future<void>.value();

  /// The identity of [screen]'s file: `'mediaType:mediaId:fileId'`.
  ///
  /// The route's three identity fields joined, because one file is what a
  /// subtitle choice is made against and one file is what a preference write
  /// names. [didUpdateWidget] compares one file's key against the next's to
  /// tell whether this reused State has been handed a different file at all,
  /// and a queued write carries the key it was made under so it can be
  /// dropped once that key has moved on.
  static String _mediaKeyOf(PlayerScreen screen) =>
      '${screen.mediaType}:${screen.mediaId}:${screen.fileId}';

  /// The key for the file now showing; see [_mediaKeyOf].
  String get _mediaKey => _mediaKeyOf(widget);

  /// Bumped at the start of every load and every file switch. A load
  /// captures it on entry and stops writing state as soon as it no longer
  /// matches, so a slow answer for a file this State has moved past (see
  /// [didUpdateWidget]) cannot land on the one now showing.
  int _loadGeneration = 0;

  bool _isCurrentLoad(int generation) =>
      mounted && generation == _loadGeneration;

  /// Whether [_applySubtitlePreference] has already run for the file now
  /// loaded. media_kit revises its track list several times per playback and
  /// every revision reaches [_applySubtitleTracks], so without this a
  /// revision landing after a viewer pick would silently undo it.
  bool _preferenceAppliedForPlayback = false;

  /// Whether the open now on screen has passed its wait for mpv's probe
  /// (`awaitRealTracks` in [_openPlayerAndStart]), whether tracks arrived or
  /// the cap ran out. Until then, in native direct play, the subtitle list is
  /// the server's fallback and [_applySubtitlePreference] holds off.
  bool _playerTracksSettled = false;

  /// The generation of the wait now filling in [_playerTracksSettled].
  ///
  /// `_attachSource`'s native branch reuses the same `Player` across a
  /// switch, so `identical(_player, player)` alone cannot tell a wait an
  /// earlier switch started from the current one -- both share it. Every
  /// open bumps this and hands the new value to its own wait as a token; a
  /// wait may only mark [_playerTracksSettled] true when the token it holds
  /// still matches, i.e. nothing newer has started since. See
  /// [_beginTracksSettle] and [_settleTracks].
  int _tracksSettleEpoch = 0;

  bool get _awaitingPlayerTracks =>
      !kIsWeb && _isDirectPlay && !_playerTracksSettled;

  /// Closes the gate for a new open and returns the token its own wait must
  /// carry to be allowed to reopen it. See [_tracksSettleEpoch].
  int _beginTracksSettle() {
    _playerTracksSettled = false;
    return ++_tracksSettleEpoch;
  }

  /// Reopens the gate for the open [epoch] was handed by
  /// [_beginTracksSettle], and reports whether it did.
  ///
  /// Declines when [player] is no longer the live one, the screen is gone,
  /// or a later open has since bumped [_tracksSettleEpoch] out from under
  /// this wait -- in which case this wait is stale and the newer open's own
  /// wait is the one that gets to decide.
  bool _settleTracks(int epoch, Player player) {
    if (!mounted || !identical(_player, player)) return false;
    if (epoch != _tracksSettleEpoch) return false;
    _playerTracksSettled = true;
    return true;
  }

  /// How many times [_applySubtitlePreference] has retaken its one-shot after
  /// a revision superseded the apply.
  ///
  /// The retry terminates on its own, because it only re-arms when another
  /// real track-list revision supersedes it and revisions are finite. That
  /// relies on mpv behaving, and this is the cheap insurance if it does not.
  int _preferenceApplyRetries = 0;

  /// Exposed for widget tests that assert per-file preference reset on a
  /// reused State. See `player_screen_file_change_test.dart`.
  @visibleForTesting
  SubtitlePreference? get subtitlePreferenceForTesting => _subtitlePreference;

  @visibleForTesting
  bool get preferenceAppliedForTesting => _preferenceAppliedForPlayback;

  @visibleForTesting
  bool get watchedInvalidationSentForTesting => _watchedInvalidationSent;

  @visibleForTesting
  bool get isDownloadedSourceForTesting => _isDownloadedSource;

  /// Exposed so a widget test can tell a preference apply that delivered from
  /// one the screen had to retake. See `subtitle_preference_apply_test.dart`.
  @visibleForTesting
  int get preferenceApplyRetriesForTesting => _preferenceApplyRetries;

  /// The viewer's choice while a source switch carries it to the new
  /// source, in the server's id space. See [SubtitleIntent].
  ///
  /// Non-null from when [_switchSource] lands until the restore that
  /// consumes it finishes. A switch sets it only when it is null, so a
  /// rollback after a failed switch reuses the original choice rather than
  /// reading one from the failed source. A sheet or remote pick clears it,
  /// since the pick replaces any carried choice. [_restoreSubtitleIntent]
  /// clears it only when nothing superseded it: a restore cancelled by a
  /// newer switch leaves it for that switch to consume.
  SubtitleIntent? _subtitleIntentAcrossSwitch;

  /// Stored per-track subtitle offsets from the server, keyed by track ref
  /// (the same id space `SubtitleTrack.id`/`SubtitleContent` use). Empty
  /// both before [_loadSubtitleOffsets] has run and after it has failed;
  /// [_subtitleOffsetsLoaded] is what tells those two apart.
  Map<String, int> _subtitleOffsets = {};

  /// Whether [_loadSubtitleOffsets] has completed successfully at least
  /// once for the media file now loaded, even when it found nothing to
  /// report. `subtitleTrackSettings` does not exist on a server that
  /// predates this feature, and it is a standalone root query precisely so
  /// that failure stays contained to it (see the query's own doc comment)
  /// rather than taking playback down with it.
  ///
  /// Gates the sheet's delay row and the `z`/`shift+z` keyboard nudge: with
  /// this false, an empty [_subtitleOffsets] is indistinguishable from "the
  /// server genuinely has nothing stored" and cannot be trusted enough to
  /// nudge relative to, let alone Save over. See [subtitleDelayDisplayMs].
  bool _subtitleOffsetsLoaded = false;

  /// What the server had already shifted into the body currently loaded.
  /// Equal to the stored offset for a track fetched over `SubtitleContent`
  /// (`Delivery.content/3` applies it before returning); zero for an
  /// mpv-native track mpv read straight out of the container, which the
  /// server never saw, and for a bitmap sidecar, which it cannot shift. See
  /// [bakedSubtitleOffsetMs] and [effectiveSubtitleDelayMs].
  int _bakedSubtitleOffsetMs = 0;

  /// The live, unsaved adjustment from the sheet's steppers or the
  /// `z`/`shift+z` keys. Reset to zero on every track change by
  /// [_onSubtitleTrackChanged].
  ///
  /// Applies to mpv the same way regardless of track origin -- but for an
  /// mpv-native track, [_saveSubtitleDelay] refuses to persist it (see
  /// [canSaveSubtitleDelay]). The asymmetry is real, not an oversight: the
  /// live delay only needs [_subtitleNudgeMs] and [_bakedSubtitleOffsetMs],
  /// neither of which cares what id space a track's id lives in, while
  /// persisting needs a `trackRef` the next session's mpv probe can
  /// reproduce, which an `mk_`-prefixed id is not.
  int _subtitleNudgeMs = 0;

  /// Feeds the subtitle sheet's delay row. A `ValueNotifier`, not a plain
  /// field: the delay row lives inside a modal bottom sheet, a different
  /// route from this State's own build method, so a `setState` here would
  /// never reach it. `null` hides the row entirely -- no track selected, or
  /// the offsets query never succeeded. Disposed in [dispose].
  final ValueNotifier<int?> _subtitleDelayDisplay = ValueNotifier<int?>(null);

  // Mapping from app model track IDs to media_kit track objects
  Map<String, AudioTrack> _mediaKitAudioTrackMap = {};
  Map<String, SubtitleTrack> _mediaKitSubtitleTrackMap = {};

  /// Local copies of bitmap subtitle sidecars fetched during this screen's
  /// life, deleted in [dispose]. mpv loads them from disk; see
  /// [_fetchImageSubtitleTrack].
  final List<String> _imageSidecarPaths = [];

  /// [_fetchSubtitleBody] calls still running, by server track id, so a
  /// restore that starts while a pick's fetch is in flight joins it instead
  /// of asking the server for a second extraction. An entry goes when its
  /// fetch completes, success or not, so a retry fetches again.
  final Map<String, Future<SubtitleTrack?>> _subtitleBodyFetches = {};

  // Whether current playback is direct play (vs HLS)
  bool _isDirectPlay = false;

  /// Owns the streaming session for the source now playing. Rebuilt on every
  /// online initialization, since the connection mode it needs can change
  /// between them; the previous one's session is ended first.
  PlaybackController? _playback;
  PlaybackMonitor? _monitor;
  AdaptationPolicy? _policy;
  StreamSubscription<HealthSample>? _healthSubscription;

  /// Runs whenever the stats panel is on, including for a downloaded file
  /// and on a source `_startVerification` never arms the monitor for.
  PlaybackStatsCollector? _statsCollector;

  /// The last fallback this session, for the panel's Why row.
  StatsFallback? _lastFallback;

  /// Closed for the whole of [_switchSource], including the progress save
  /// before the controller claims its switch. Subtitle calls pass through
  /// it, so none reaches a player a switch is replacing; see
  /// [SourceSwitchGate].
  final _switchGate = SourceSwitchGate();

  bool get _switchingSource =>
      _switchGate.closed || _playback?.switching == true;

  /// What is playing now and why. Null until the online branch plans, and
  /// on the offline and downloaded branches, which have nothing to plan.
  PlaybackPlan? _plan;

  /// The inputs the current plan was made from, kept for re-planning on a
  /// quality change and for the failure memory's key.
  PlanInputs? _planInputs;

  /// The file id the source was opened for: the route's, or the server's
  /// choice on the two fall-through paths.
  String? _playFileId;

  /// Null when the memory box could not be opened; every read treats that
  /// as an empty memory.
  PlaybackMemory? _memory;

  /// Keys memory by server: the node address over p2p, the URL over HTTP.
  String? _serverKey;

  /// Whether the server is serving a playlist covering the whole file.
  ///
  /// False against a server too old to know about `playlistMode`, which is the
  /// only reason the restart path below still exists. Delete that path, and
  /// this field, once the compatibility window closes.
  bool _fullPlaylist = false;

  /// The rung in effect, or null before anything has settled one for this
  /// playback.
  ///
  /// Storage seeds this once; quality changes adopt the chosen rung here
  /// before persisting it, so a failed preference write cannot undo the pick.
  QualityRung? _settledQuality;

  /// The choice in effect, which is what gets requested. Auto until something
  /// settles one.
  QualityRung get _selectedQuality => _settledQuality ?? QualityRung.auto;

  /// True when this session's bytes cross our relay: public web
  /// (web.mydia.dev) only.
  ///
  /// Native hole-punches to a direct connection, and the instance-hosted
  /// `/player` build talks to its own origin over plain HTTP; neither costs
  /// the project anything, so both stay uncapped and unblocked. Shared by the
  /// streaming-session cap and the browser-support gate below, so both agree
  /// on exactly which sessions are relayed.
  bool get _relayed => kIsWeb && !isInstanceHostedWeb;

  /// Why this browser cannot play a relayed HLS stream, or null when it can.
  ///
  /// Only ever consulted for [_relayed] sessions, and that distinction is the
  /// whole point. On public web the manifest and every segment are served by a
  /// Service Worker out of the page's p2p connection. The instance-hosted
  /// `/player` build serves a plain same-origin HTTP manifest with no worker
  /// in the path, where everything below plays, so nothing may be blocked
  /// there.
  ///
  /// The caller must consult this before `startStreamingSession`: past that
  /// point an FFmpeg transcode is running on the instance and relay bytes are
  /// being spent on a session that can only end in a spinner.
  ///
  /// [CodecSupport.prefersNativeHls] is deliberately *not* consulted here.
  /// media_kit skips hls.js for any browser answering `canPlayType(
  /// 'application/vnd.apple.mpegurl')` non-empty, and Chromium 149 answers
  /// `maybe`, so that predicate is true on desktop Chrome. There the media
  /// element's own loader was measured fetching both the manifest and its
  /// segment through the Service Worker, so it works. Blocking on it would
  /// turn away most of this site's viewers. Whether WebKit's loader does the
  /// same is the open question, and it needs the manual browser matrix to
  /// answer, not a guess. See that getter's doc.
  String? _relayedPlaybackBlocker() {
    if (!_relayed) return null;

    // Neither MediaSource nor ManagedMediaSource, so hls.js cannot run at all.
    // iOS Safari below 17.1 is the real-world case.
    if (!CodecSupport.hasHlsMediaSourceSupport) {
      return 'This browser cannot play video here. Try the Mydia '
          'app instead, or a browser released after 2023.';
    }

    return null;
  }

  /// The rung the server reported actually applying, which is what gets
  /// displayed. These differ on a relay connection, where the cap is not
  /// negotiable by the client. Null until a session echoes its caps back,
  /// and reset on every re-initialization so a value from the previous
  /// session cannot label the new one.
  QualityRung? _effectiveQuality;

  /// Ladder for the current file, derived from its source height.
  ///
  /// Original alone — the initial value, and what the downloaded and offline
  /// branches leave in place — hides the control: a local file has no
  /// session to restart and nothing to switch between.
  List<QualityRung> _qualityLadder = const [QualityRung.original];

  /// What the Original rung would do for this file's candidates.
  ///
  /// Cached because the candidate list is not retained after
  /// [_initializePlayer]. Defaults to re-encoding required until candidates
  /// resolve (honest worst case; matches the spec fallback).
  String _originalDeliverySubtitle = kOriginalTranscodeSubtitle;

  // Total duration from server (for HLS streams where playlist duration is incomplete)
  Duration? _totalDuration;

  // The mapping from the player's stream-local positions onto real media
  // positions. Populated in two stages for HLS: first with just the
  // resolved duration (offset zero) as soon as it's known — so a cast
  // chosen before the session negotiates still gets a real duration — then
  // rebuilt with the session's echoed start offset once it starts. Stays at
  // its zero default for direct play and offline playback, which hold the
  // whole file and need no correction.
  StreamTimeline _timeline = StreamTimeline.zero;

  // Desktop feature state
  final FocusNode _focusNode = FocusNode();

  /// Focus target for the play/pause control, so revealing the OSD lands the
  /// viewer on a real control. Owned here rather than by the chrome because
  /// the key handler that reveals the chrome lives here and is the only caller
  /// that needs to move focus into it.
  final FocusNode _osdPlayPauseFocus = FocusNode(debugLabel: 'osd-play-pause');

  /// Focus target for the OSD's scrub bar on the remote tier. Owned here for
  /// the same reason as [_osdPlayPauseFocus]: the key handler that starts a
  /// scrub from a hidden OSD is the caller that moves focus onto it.
  final FocusNode _scrubberFocus = FocusNode(debugLabel: 'osd-scrubber');

  /// D-pad scrub state. Reads the live player and timeline on every call,
  /// so it survives player re-initialisation and source switches without
  /// being rebuilt.
  late final ScrubController _scrub = ScrubController(
    position: () {
      final player = _player;
      return player == null
          ? Duration.zero
          : _timeline.toReal(player.state.position);
    },
    duration: () {
      final player = _player;
      return player == null
          ? Duration.zero
          : _timeline.resolveDuration(player.state.duration);
    },
    onCommit: seekToReal,
  );

  /// Trickplay frames for the scrub bubble, for the file that is playing.
  /// Null over p2p and off the remote tier; see [_attachScrubThumbnails].
  ScrubThumbnails? _scrubThumbnails;

  /// Wraps the whole OSD so the screen can ask "is focus anywhere in the
  /// chrome?" rather than "is it on play/pause?".
  ///
  /// `hasFocus` is true for a node when any descendant holds focus, which is
  /// what makes one node sufficient here. It takes no focus itself and is
  /// skipped by traversal — the same shape `RailFocusScroller` uses — so it
  /// adds no stop and changes no order.
  final FocusNode _chromeFocusNode = FocusNode(
    debugLabel: 'osd-chrome',
    skipTraversal: true,
    canRequestFocus: false,
  );

  /// Handle on the OSD's shown or hidden state, so `_handleKeyEvent` can
  /// decide what an arrow press means and reveal the chrome on demand.
  final ChromeVisibilityController _chromeVisibility =
      ChromeVisibilityController();

  /// Fullscreen state, owned by the controller and sourced from platform
  /// events. Deliberately not a local bool: the previous field was flipped
  /// optimistically and never learned that the platform had refused, which is
  /// why the button reported "exit fullscreen" over an inline video on
  /// iPhone Safari.
  final FullscreenController _fullscreen = FullscreenController(
    backendFactory: PlayerScreen.debugFullscreenBackendFactory,
  );

  /// Live while the screen is mounted. Carries refused requests to the viewer;
  /// see [_onFullscreenFailure].
  StreamSubscription<FullscreenFailure>? _fullscreenFailures;

  // Always-on-top state. Not persisted — starts false for every playback
  // session and is force-disabled in dispose() if still true, so it never
  // leaks into the browse/library window behind this one.
  bool _isAlwaysOnTop = false;

  /// Skippable intro/credits segments for the file being played, as reported
  /// by the server. Empty whenever detection has not run, found nothing, or
  /// the query failed: an older server has no `segments` field at all, and
  /// that must degrade to "no skip button", never to a playback error.
  List<MediaSegment> _segments = const [];

  /// Once-per-playback record of automatic skips. Reset when the media
  /// changes, not when a seek restarts the HLS session, so a restart mid-intro
  /// cannot re-arm a skip the viewer already overrode.
  final SegmentSkipTracker _skipTracker = SegmentSkipTracker();

  /// Identifies the media [_skipTracker] is currently armed for. See
  /// [_resetSegmentsIfMediaChanged].
  String? _skipTrackerMediaKey;

  /// Whether detected segments are skipped without asking. Off unless the
  /// viewer opted in; loaded once in [initState] and deliberately not watched,
  /// since flipping it mid-episode is not a case worth a rebuild.
  bool _autoSkipSegments = false;

  // Auto-play next episode state
  bool _showUpNext = false;
  bool _autoPlayCancelled = false;

  /// The resolved next episode, or null when nothing is on offer. Non-null
  /// implies playable: `UpNextTarget` cannot be built without a file id.
  UpNextTarget? _upNextTarget;

  UpNextCountdown? _upNextCountdown;

  /// Tracks `player.stream.playing` while the prompt is up, so a pause holds
  /// the countdown and a resume releases it. Created alongside the countdown
  /// in [_showUpNextOverlay] and torn down everywhere the countdown is:
  /// [_cancelAutoPlay], [_playNextEpisode], [_playPreviousEpisode], and
  /// [dispose]. There is no other `player.stream.playing` listener in this
  /// file for it to piggyback on — the old countdown polled
  /// `_player!.state.playing` inside its own tick, which is exactly the
  /// coupling [UpNextCountdown] was built without.
  StreamSubscription<bool>? _upNextPlayingSub;

  /// Reports this screen's playback to the macOS Dock menu. Claimed in
  /// [initState] so a newer screen's claim supersedes this one before this
  /// one disposes; see [NowPlayingPublisher].
  late final NowPlayingPublisher _nowPlaying;

  /// Re-bound per `Player`, like [_errorSubscription].
  StreamSubscription<bool>? _nowPlayingSubscription;

  /// Player events that change what the OS media session shows but that
  /// [_publishNowPlaying] does not already cover.
  final List<StreamSubscription<Object?>> _mediaSessionSubscriptions = [];

  Future<void> _cancelMediaSessionSubscriptions() async {
    final subscriptions = List.of(_mediaSessionSubscriptions);
    _mediaSessionSubscriptions.clear();
    for (final sub in subscriptions) {
      await sub.cancel();
    }
  }

  /// Reshapes the OS window to the video's aspect on desktop. A no-op
  /// everywhere else, so no platform check is needed at the call sites.
  ///
  /// Nullable rather than `late final`: it is assigned in [initState] after
  /// two `ref.read` calls and two `fireImmediately` listener callbacks, any
  /// of which could throw first. `dispose()` always reaches
  /// `_windowSizer?.detach()` regardless of how far `initState` got, and a
  /// `late` field that was never assigned would throw
  /// `LateInitializationError` there instead of letting `dispose` finish.
  PlayerWindowSizer? _windowSizer;

  /// Identity handle for this screen's orientation lease. The controller
  /// tracks owners by identity, so a route replacement (a different player
  /// route, not an episode advance, which reuses this State) has a handle
  /// distinct from this one's, and only the last release restores normal
  /// orientations.
  final Object _orientationLeaseOwner = Object();

  /// Whether [initState] acquired the lease above, so [dispose] releases only
  /// what this screen actually owns.
  bool _ownsOrientationLease = false;

  /// Tracks local playback activity so global cast bars are suppressed
  /// during active on-device playback.
  LocalPlaybackNotifier? _localPlaybackNotifier;
  bool _acquiredPlayback = false;

  @override
  void initState() {
    super.initState();
    _invalidator = ref.read(invalidatorProvider);
    _mediaProxy = ref.read(mediaProxyProvider);
    _remoteTargetController = ref.read(remoteTargetControllerProvider);
    _remoteTargetController.attachPlayer(this);
    _nowPlaying = ref.read(nowPlayingPublisherProvider)..claim(this);
    final localPlaybackNotifier =
        ref.read(localPlaybackActiveProvider.notifier);
    _localPlaybackNotifier = localPlaybackNotifier;
    Future.microtask(() {
      if (mounted) {
        _acquiredPlayback = true;
        localPlaybackNotifier.acquire();
      }
    });

    // Seeded here rather than read at each branch: an entry-point that already
    // said "Continue" has answered the resume question, and all three
    // initialization branches must honour that, not just the streaming one.
    _resumeOverrideSeconds = widget.resumeSeconds;

    // Set up before `_initializePlayer` so it is live for the whole widget
    // lifetime, regardless of which playback branch runs (offline,
    // already-downloaded, or streaming) — `_terminateHlsSession` is called
    // unconditionally from `dispose()` no matter which branch was taken.
    ref.listenManual<AsyncValue<GraphQLClient>>(
      asyncGraphqlClientProvider,
      (previous, next) => next.whenData((client) => _graphqlClient = client),
      fireImmediately: true,
    );

    // Before `_initializePlayer`: attach pauses geometry persistence and
    // snapshots the browse window, and the snapshot must be taken before
    // anything reshapes the window.
    final windowSizer =
        widget.createWindowSizer?.call() ?? createPlayerWindowSizer();
    _windowSizer = windowSizer;
    unawaited(windowSizer.attach());

    _loadAutoSkipPreference();
    _fullscreen.isFullscreen.addListener(_onFullscreenChanged);
    // Availability moves at runtime on web: the media element route is not
    // ready until a player is attached, and a refused request can retire the
    // route mid-session. The button follows it, so the rebuild has to as well.
    _fullscreen.available.addListener(_onFullscreenChanged);
    _fullscreenFailures = _fullscreen.failures.listen(_onFullscreenFailure);
    _initializePlayer();

    // An auto-hidden OSD that kept focus would swallow the next OK: the
    // focused control is still live but no longer on screen, so the press
    // would activate something the viewer cannot see. Handing focus back to
    // the player makes the next reveal start from a known place.
    _chromeVisibility.addListener(_onChromeVisibilityChanged);

    // Keep one shared lease for the complete player route lifetime. During a
    // route replacement (a different player route, not an episode advance,
    // which reuses this State), the incoming and outgoing screens hand this
    // lease off without briefly restoring portrait-capable orientations.
    _ownsOrientationLease = PlayerScreen.wantsForcedLandscape(
      isMobile: PlatformFeatures.isMobile,
      directionalPrimary: InputCapabilities.directionalPrimary,
    );
    if (_ownsOrientationLease) {
      playerOrientationLeaseController.acquire(_orientationLeaseOwner);
    }

    // Register beforeunload handler for web to terminate HLS session on tab close
    if (kIsWeb) {
      web_lifecycle.registerBeforeUnload(_terminateHlsSession);
    }
  }

  /// Loads the new file when this State is handed a different one.
  ///
  /// go_router keys `/player/:type/:id`'s page off the route *pattern* rather
  /// than the resolved location (`go_router/lib/src/match.dart:231`:
  /// `pageKey: ValueKey<String>(newMatchedPath)`). So `_navigateToEpisode`'s
  /// `context.go`, a remote `LoadContent` and a deep link while playing all
  /// update this State in place instead of building a new one, and
  /// [_switchToFile] does the per-file teardown and reload a new State would
  /// have done in `dispose` and `initState`.
  @override
  void didUpdateWidget(PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_mediaKeyOf(oldWidget) == _mediaKey) return;
    unawaited(_switchToFile(oldWidget));
  }

  /// Replaces the file this State plays with the one `widget` now names.
  ///
  /// [previous] is the widget the old file came from. `widget` already names
  /// the new file here, so anything that must still address the old one
  /// (its progress save) takes [previous]'s identity explicitly.
  ///
  /// Screen-scoped state (window sizer, fullscreen, orientation lease, proxy
  /// hold) is deliberately untouched: this is the same screen, and tearing
  /// any of it down would exit fullscreen or reshape the window on every
  /// episode advance.
  ///
  /// Everything the old file owns is detached from State before this
  /// function's own first `await` -- every statement up to (and including)
  /// starting [disposal] below runs synchronously, with no suspension point
  /// in between. `didUpdateWidget` calls this unawaited, so nothing stops a
  /// second file switch (a remote command, a fast deep link, up-next racing
  /// a manual tap) from starting on this same State while this one is still
  /// awaiting its own save or session end. Without the synchronous detach, a
  /// second switch's *own* first step -- saving progress for the file it is
  /// leaving -- would still find this switch's `_player`, undisposed, and
  /// credit this switch's position to the second switch's id. The same
  /// applies to `dispose()`'s fire-and-forget save, which reads whatever
  /// `_player` and `widget` (already the new file) happen to hold at the
  /// moment the screen goes away. [_saveProgressFor] already bails out at
  /// its first line when `_player` is null, so detaching it here is what
  /// makes both races harmless: a second switch's own save, and dispose's,
  /// simply find nothing left to save.
  Future<void> _switchToFile(PlayerScreen previous) async {
    final gen = ++_loadGeneration;

    // Started here, not awaited yet -- an async function runs synchronously
    // up to its own first `await`, and that covers every read
    // [_saveProgressFor] and `ProgressService`'s sync helpers do
    // (`_player`, `_progressStore`, `_progressService`, `_isDownloadedSource`,
    // `_totalDuration`, and `player.state.position`/`duration` inside
    // `resolveSync`) -- so the old file's position is captured before the
    // detach below ever runs.
    final save = _bestEffort(
      'save progress',
      () => _saveProgressFor(
        mediaType: previous.mediaType,
        mediaId: previous.mediaId,
      ),
    );

    _stopVerification();
    if (mounted) {
      setState(() {
        _resetUpNext();
        _isLoading = true;
      });
    } else {
      _resetUpNext();
      _isLoading = true;
    }

    // Ends the old file's server session without `_terminateHlsSession`,
    // which would also release this screen's proxy hold.
    final playback = _playback;
    _playback = null;

    // Also started here, not awaited yet: [_disposePlayer] nulls `_player`
    // and `_videoController` at its own very first (synchronous) lines,
    // before its own first `await` -- see its doc comment. So by the time
    // this line returns, `_player` is already gone from State.
    final disposal = _bestEffort('dispose player', _disposePlayer);

    await save;
    await _bestEffort('end session', () async => playback?.endSession());
    await disposal;
    for (final path in _imageSidecarPaths) {
      unawaited(discardImageSidecar(path));
    }
    _imageSidecarPaths.clear();
    _subtitleBodyFetches.clear();
    _resumeOverrideSeconds = widget.resumeSeconds;
    // A second switch that started while this one was still awaiting above
    // has already bumped `_loadGeneration` past `gen` (and may already have
    // reloaded); only the most recent switch may reload.
    if (!_isCurrentLoad(gen)) return;
    await _initializePlayer();
  }

  /// Runs one teardown step of [_switchToFile], logging instead of throwing,
  /// so an unreachable server cannot strand the viewer on the old file.
  Future<void> _bestEffort(String step, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('[PlayerScreen] File switch: $step failed: $e');
    }
  }

  /// Read the auto-skip preference once at mount.
  ///
  /// Failure is not propagated: secure storage being unreadable is no reason
  /// to fail playback, and the safe answer is the default (skip nothing
  /// automatically, leave the button).
  Future<void> _loadAutoSkipPreference() async {
    try {
      final enabled =
          await ref.read(settingsServiceProvider).getAutoSkipSegments();
      if (!mounted) return;
      _autoSkipSegments = enabled;
    } catch (e) {
      debugPrint('[PlayerScreen] Could not read auto-skip preference: $e');
    }
  }

  /// The file's subtitle tracks, in the shape the cast stack wants.
  ///
  /// `url` here is still the media-file URL; `CastRouteResolver` rewrites it
  /// to a session path once a route exists. Only `trackId` and `language`
  /// survive that rewrite, but the URL is what the progressive DLNA route
  /// keeps using, so it is carried rather than blanked.
  ///
  /// `deliverable` is one half of the filter: image tracks (PGS, VobSub)
  /// must never be offered, since a receiver fetching one gets a 415. `url`
  /// is allowed to be null here — `SubtitleTrack.fromDownload` deliberately
  /// leaves it null for a track that was just downloaded but never had a
  /// media-file URL assigned — and is passed through as an empty string.
  /// That is only a progressive-route concern: `CastRouteResolver.
  /// _progressiveSubtitles` drops any track it can't build a URL for, while
  /// the session-addressed (HLS) routes ignore this field entirely and
  /// rewrite it from `trackId`.
  ///
  /// The other half is `CastSubtitleTrack.isServableTrackId`. In direct play
  /// `_detectTracks` replaces `_subtitleTracks` with media_kit's own track
  /// list for every embedded track, carrying synthetic ids like `mk_0` (see
  /// the comment there). Those have no url and default to `deliverable`, so
  /// dropping the old `url != null` half of this filter (to let a
  /// just-downloaded sidecar through) would also let `mk_0` through — and
  /// `CastRouteResolver._sessionSubtitles` builds `subs_mk_0.vtt` for it
  /// unconditionally, which `Mydia.Streaming.SessionSubtitles`'s anchored
  /// filename regex rejects outright, so the receiver 404s and shows
  /// nothing. Filtering on id shape instead keeps downloaded sidecars (UUID,
  /// null url) working while excluding every `mk_` id — at the cost that a
  /// direct-play session, whose whole `_subtitleTracks` list is `mk_` ids
  /// plus sidecars, now offers no *embedded* subtitles to a receiver at all,
  /// only sidecars. That is strictly better than offering ids that 404, but
  /// it is a real gap: there is no server-side stream index to fall back to
  /// here, because media_kit's own track ordering is not guaranteed to match
  /// ffprobe's, and guessing one would show the wrong subtitle instead of
  /// none.
  List<CastSubtitleTrack> _castSubtitleTracks() => _subtitleTracks
      .where((track) =>
          track.deliverable && CastSubtitleTrack.isServableTrackId(track.id))
      .map((track) => CastSubtitleTrack(
            trackId: track.id,
            url: track.url ?? '',
            label: track.displayName,
            language: track.language,
          ))
      .toList();

  /// Start on the receiver instead of locally, when a device was chosen
  /// before playback began.
  ///
  /// Returns true when a cast was started, in which case the caller must not
  /// build a local `Player` — the point of choosing a device up front is that
  /// the file never opens on this machine. Called from three points inside
  /// [_initializePlayer], each immediately before it would otherwise start
  /// local-only setup (HLS session negotiation, the P2P proxy, or opening a
  /// downloaded file): the offline-playback branch, the "already downloaded,
  /// still online" branch, and the network streaming branch. Checking before
  /// that setup — rather than once at the top of [_initializePlayer], or once
  /// right before each `Player` is constructed — means a chosen cast target
  /// never pays for local streaming infrastructure it immediately throws
  /// away, while still reaching the metadata fetch that populates
  /// `_totalDuration` on the streaming path.
  ///
  /// [plan] is resolved by the caller before this runs, on every branch that
  /// calls it — so the receiver starts where the user asked, instead of
  /// always at zero the way it did when each of the three call sites reached
  /// this before the resume decision existed.
  ///
  /// [fileId] is the file id to hand the receiver. Callers before the
  /// streaming-candidates fetch pass `widget.fileId` (there is no other id
  /// yet); the caller after it must pass `playFileId` instead, so a self-heal
  /// that swaps in the server-ranked file for local playback (see
  /// [_fetchStreamingCandidates]) reaches the receiver too, rather than
  /// sending it the id the server just rejected.
  Future<bool> _castToTargetIfSet(ResumePlan plan,
      {required String fileId}) async {
    final target = ref.read(castTargetProvider);
    if (target == null) return false;

    // Downloaded media lives only on this device; the route resolver has no
    // server-side file to hand the receiver. Playing locally is the useful
    // outcome, but silently ignoring the chosen device is not, so say why.
    if (fileId == 'offline') {
      if (mounted) {
        showToast(
          context,
          'Downloads cannot be cast — playing on this device.',
        );
      }
      return false;
    }

    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      await manager.startCast(
        device: target,
        request: CastLaunchRequest(
          fileId: fileId,
          mediaId: widget.mediaId,
          mediaType: widget.mediaType,
          showId: widget.showId,
          title: widget.title ?? 'Untitled',
          duration: _knownCastDuration(),
          startPosition: plan.position,
          subtitles: _castSubtitleTracks(),
        ),
      );
      // The target and the session coexist deliberately: the target is what
      // the user chose, the session is what is connected. Clearing it here
      // would drop the cast icon to white mid-cast. Opting out is the bar's ✕
      // or Stop, both of which disconnect — and "every future playback casts"
      // is the correct behaviour while the user is visibly connected to a TV.
      return true;
    } catch (e) {
      // A dead screen is the one outcome worse than not casting: fall through
      // so the user still gets their episode. The chosen device is kept, so
      // the bar offers a reconnect rather than silently discarding it.
      debugPrint('[PlayerScreen] Cast target failed, playing locally: $e');
      if (mounted) {
        if (e is CastBackendException) {
          showCastErrorToast(context, e,
              ref: ref,
              isMydiaTarget: target.protocol == CastProtocolKind.mydia);
        } else {
          showToast(context, 'Failed to start casting: $e',
              kind: ToastKind.error);
        }
      }
      return false;
    }
  }

  /// Clears everything that describes one file's playback, before a load.
  ///
  /// Runs at the top of every [_initializePlayer]: first mount, a cast-stop
  /// restart, and a file switch on a reused State (see [didUpdateWidget]).
  /// Pure; the `setState` that follows in [_initializePlayer] rebuilds.
  void _resetPerFileState() {
    // Cleared up front so the branches that never reach a streaming session —
    // offline, and already-downloaded — cannot inherit a ladder derived for a
    // previous one. Both return early below, and a local file has no session
    // to restart and nothing to switch between, so Original alone is right
    // for them and hides the control.
    _qualityLadder = const [QualityRung.original];
    _effectiveQuality = null;
    _originalDeliverySubtitle = kOriginalTranscodeSubtitle;
    // A stale plan from the previous file must not offer a control, or
    // narrate its old delivery, for the one about to load.
    _plan = null;
    _planInputs = null;
    // A choice carried by a switch that never landed belongs to the source
    // this load replaces, and a fresh load starts with no choice made.
    _subtitleIntentAcrossSwitch = null;
    _subtitleChosenThisPlayback = false;
    // The preference belongs to the show, not the file, so it is refetched
    // with the new file's media-file document rather than carried. Clearing
    // it here means a file whose query has not landed yet cannot apply the
    // previous episode's answer to this one.
    _subtitlePreference = null;
    _preferenceAppliedForPlayback = false;
    _preferenceApplyRetries = 0;

    // Each load branch sets these again; a load that stops early (an error
    // before its branch) must not keep the previous file's answer.
    _isDownloadedSource = false;
    _progressStore = null;
    _progressService?.dispose();
    _progressService = null;
    // Once per file: crossing 90% on the next episode must invalidate again.
    _watchedInvalidationSent = false;
    _resetUpNext();
  }

  Future<void> _initializePlayer() async {
    final gen = ++_loadGeneration;
    // Flushes whatever the *previous* load's timeline reached before this
    // one takes over the field -- e.g. `_restartLocalPlayback` calling this
    // again after a cast session ends abandons the cast-era timeline, which
    // would otherwise never print. A no-op on the very first call, when
    // `_playTimeline` is still null.
    _playTimeline?.logOnce();
    _playTimeline = StartupTimeline('playback');
    _resetSegmentsIfMediaChanged();
    _resetPerFileState();

    try {
      setState(() {
        _isLoading = true;
        _error = null;
        _autoplayBlocked = false;
      });

      // Check if we're in offline mode
      final authState = ref.read(authStateProvider);
      final isOfflineMode = authState.maybeWhen(
        data: (status) => status == AuthStatus.offlineMode,
        orElse: () => false,
      );

      // Check for downloaded content first (before any network operations)
      final downloadManager = await ref.read(downloadManagerProvider.future);
      if (!_isCurrentLoad(gen)) return;
      final downloadedMedia =
          downloadManager.getDownloadedMediaById(widget.mediaId);

      // In offline mode, only downloaded content can be played
      if (isOfflineMode) {
        if (downloadedMedia == null || kIsWeb) {
          setState(() {
            _error =
                'This content is not available offline. Download it first to watch without a connection.';
            _isLoading = false;
          });
          return;
        }

        final offlinePath =
            await _resolveDownloadedFilePath(downloadedMedia.filePath);
        if (!_isCurrentLoad(gen)) return;
        if (offlinePath == null) {
          setState(() {
            _error =
                'Downloaded file not found. Please re-download the content.';
            _isLoading = false;
          });
          return;
        }

        // The whole file is on disk, so this is direct play in every sense
        // `seekToReal` and `_detectTracks` care about: no HLS session exists
        // to restart, and media_kit's own duration is already the true
        // runtime.
        _isDirectPlay = true;

        _isDownloadedSource = true;
        try {
          _progressStore = await ref.read(playbackProgressStoreProvider.future);
        } catch (e) {
          debugPrint('Could not open local progress store: $e');
        }
        if (!_isCurrentLoad(gen)) return;

        // No server is reachable, so the saved position comes from whatever a
        // previous offline session recorded locally. The stored duration is
        // preferred over the download's own runtime metadata: it reflects the
        // media's real duration as measured during actual playback, while
        // `runtime` is catalog metadata that can be missing or approximate.
        // Without either, `shouldOfferResume` declines and this path silently
        // loses its prompt.
        final localProgress = _progressStore?.get(widget.mediaId);
        _savedPositionSeconds = localProgress?.positionSeconds;
        _savedDurationSeconds = localProgress?.durationSeconds;
        _totalDuration =
            _savedDurationSeconds != null && _savedDurationSeconds! > 0
                ? Duration(seconds: _savedDurationSeconds!)
                : (downloadedMedia.runtime != null
                    ? Duration(minutes: downloadedMedia.runtime!)
                    : null);

        final plan = await resolveResumePlan(
          savedPositionSeconds: _savedPositionSeconds,
          realDuration: _totalDuration,
          resumeOverride: _consumeResumeOverride(),
          mounted: mounted,
          ask: (saved, total) async {
            if (!_isCurrentLoad(gen)) return null;
            return showResumeDialog(context, saved, total);
          },
        );
        if (plan == null) return;
        if (!_isCurrentLoad(gen)) return;

        if (await _castToTargetIfSet(plan, fileId: widget.fileId)) return;
        if (!_isCurrentLoad(gen)) return;

        await _openPlayerAndStart(offlinePath, {}, plan: plan);
        return;
      }

      // In online mode, if content is downloaded locally, play it directly
      // without requiring network for streaming
      if (downloadedMedia != null && !kIsWeb) {
        final localPath =
            await _resolveDownloadedFilePath(downloadedMedia.filePath);
        if (!_isCurrentLoad(gen)) return;
        if (localPath != null) {
          debugPrint('Playing from local file: $localPath');

          // Try to initialize progress sync (optional - local playback
          // works even if server is unreachable)
          try {
            final graphqlClient =
                await ref.read(asyncGraphqlClientProvider.future);
            if (!_isCurrentLoad(gen)) return;
            _progressService = ProgressService(graphqlClient);
            await _fetchProgressAndEpisodes(graphqlClient, gen);
            if (!_isCurrentLoad(gen)) return;
          } catch (e) {
            debugPrint('Could not initialize progress sync: $e');
          }

          // Same reasoning as the offline branch above: the whole file is
          // already local, so this holds the whole file exactly like direct
          // play and must never be treated as a restartable HLS session.
          _isDirectPlay = true;

          _isDownloadedSource = true;
          try {
            _progressStore =
                await ref.read(playbackProgressStoreProvider.future);
          } catch (e) {
            debugPrint('Could not open local progress store: $e');
          }
          if (!_isCurrentLoad(gen)) return;

          // Reconcile the server's progress (just loaded above) against
          // whatever this device recorded locally, e.g. during an earlier
          // offline session the server never heard about. The more
          // recently-updated side wins.
          final reconciled = pickNewerProgress(
            local: _progressStore?.get(widget.mediaId),
            serverPositionSeconds: _savedPositionSeconds,
            serverDurationSeconds: _savedDurationSeconds,
            serverLastWatchedAt: _serverLastWatchedAt,
          );
          _savedPositionSeconds = reconciled.positionSeconds;
          _savedDurationSeconds = reconciled.durationSeconds;

          // No candidates query runs on this branch — there is no server-side
          // stream to negotiate — so the runtime has to come from whatever
          // was just reconciled above. `shouldOfferResume` declines outright
          // without one, which would silently cost this path its resume
          // prompt. Only `_totalDuration` is set, not `_timeline`: the file
          // is entirely local, so media_kit's own duration is the
          // authoritative one for everything else.
          _totalDuration = _resolveRealDuration(null);

          final plan = await resolveResumePlan(
            savedPositionSeconds: _savedPositionSeconds,
            realDuration: _totalDuration,
            resumeOverride: _consumeResumeOverride(),
            mounted: mounted,
            ask: (saved, total) async {
              if (!_isCurrentLoad(gen)) return null;
              return showResumeDialog(context, saved, total);
            },
          );
          if (plan == null) return;
          if (!_isCurrentLoad(gen)) return;

          if (await _castToTargetIfSet(plan, fileId: widget.fileId)) return;
          if (!_isCurrentLoad(gen)) return;

          await _openPlayerAndStart(localPath, {}, plan: plan);
          return;
        }
        debugPrint('Downloaded file not found, falling back to streaming');
      }

      // Online mode - initialize network services
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);
      if (!_isCurrentLoad(gen)) return;

      // Capture it directly rather than relying on the `ref.listenManual` in
      // `initState` to have fired by now. That listener is the right mechanism
      // for keeping the field fresh across a reconnect, but it only populates
      // it once the provider resolves, and this await resolves on the same
      // transition — the ordering between the two is a Riverpod internal. If
      // the screen were disposed inside that window we would have started a
      // session with a client `_terminateHlsSession()` could not see, and the
      // HLS session would leak until its inactivity timeout.
      _graphqlClient = graphqlClient;

      // Get server URL and token
      final serverUrl = await ref.read(serverUrlProvider.future);
      final token = await ref.read(authTokenProvider.future);
      if (!_isCurrentLoad(gen)) return;

      if (serverUrl == null || token == null) {
        if (mounted) {
          setState(() {
            _error = 'Server URL or authentication token not available';
            _isLoading = false;
          });
        }
        return;
      }

      // Check connection mode
      final connectionState = ref.read(conn.connectionProvider);
      final isP2PMode = connectionState.isP2PMode;

      // Start local proxy if P2P
      if (isP2PMode) {
        final serverNodeAddr = connectionState.serverNodeAddr;
        if (serverNodeAddr == null) {
          throw Exception(
              'Server node address not available for P2P connection');
        }

        if (mounted) {
          setState(() {
            _loadingMessage = 'Connecting via P2P...';
          });
        }

        final proxy = ref.read(mediaProxyProvider);
        // Held against this State, and released by [_terminateHlsSession] at
        // dispose. This method re-runs within one screen's life (a session
        // restart past the transcoded end, a cast rebind); the hold is per
        // owner, so those re-runs re-target the proxy without stacking up a
        // debt that a single stop could not settle.
        await proxy.start(
          owner: this,
          targetPeer: serverNodeAddr,
          authToken: token,
        );
        if (!_isCurrentLoad(gen)) return;
        debugPrint('[PlayerScreen] Media proxy serving at ${proxy.baseUrl}');
      }

      // Initialize progress service
      _progressService = ProgressService(graphqlClient);

      // Ask about the *file* the user picked. Keying this on mediaId left
      // the server to pick one of the item's files with no way to express the
      // user's choice, and its pick then won on the direct-play path below.
      //
      // The exception is the `'offline'` sentinel: a downloaded item whose
      // local file has gone missing falls through to streaming from above,
      // still carrying that sentinel instead of a real file id. There is no
      // file to ask about, so ask about the media item and let the server rank.
      final byFile = widget.fileId != 'offline';
      final mediaContentType =
          widget.mediaType == 'movie' ? 'movie' : 'episode';
      // Started now and awaited below: it shares nothing with the queries in
      // `_fetchProgressAndEpisodes`, and never throws (it catches everything).
      final candidatesFuture = _fetchStreamingCandidates(
        graphqlClient,
        byFile ? 'file' : mediaContentType,
        byFile ? widget.fileId : widget.mediaId,
      );

      // Fetch saved progress and episode list for TV shows
      await _fetchProgressAndEpisodes(graphqlClient, gen);
      if (!_isCurrentLoad(gen)) return;
      _playTimeline?.mark('queries_done');

      // Fetch streaming candidates to determine optimal strategy
      if (mounted) {
        setState(() {
          _loadingMessage = 'Checking file compatibility...';
        });
      }

      var candidatesFetch = await candidatesFuture;
      if (!_isCurrentLoad(gen)) return;

      // A selected file can go missing out from under a live route: a
      // quality upgrade replaces an episode's file, writing a new
      // `media_files` row and deleting the old one, and the route still
      // carries the old id. The server tells us that explicitly —
      // `serverRejected`, a GraphQL error, not a transport failure — so
      // re-ask by media item and let the server rank a file that still
      // exists, the same fallback the offline sentinel already uses below.
      //
      // A transport failure (unreachable server, timeout, socket error) gets
      // no such retry: `serverRejected` is false in that case specifically so
      // this branch is skipped, and `playFileId` below keeps resolving to
      // `widget.fileId`. Falling back on a network blip would silently swap
      // the user's chosen file for a different one.
      var usesServerRankedFile = !byFile;
      if (byFile && candidatesFetch.serverRejected) {
        usesServerRankedFile = true;
        candidatesFetch = await _fetchStreamingCandidates(
          graphqlClient,
          mediaContentType,
          widget.mediaId,
        );
        if (!_isCurrentLoad(gen)) return;
      }

      final candidatesResult = candidatesFetch.candidates;

      // Held for _openPlayerAndStart, which builds the media_kit Player and
      // has to set mpv's alang before opening the media.
      //
      // Only overwritten when the server actually answered. A null here is
      // either a failed candidates call (offline fall-through, transient
      // error) or a server too old to carry the field, and neither is a
      // statement that the viewer has no preference. Assigning `const []`
      // unconditionally would discard what `_rememberAudioLanguage` stored on
      // the previous episode, which is exactly the case where a season
      // playing through must keep it: go_router reuses this screen state, so
      // this field is the only thing carrying the choice forward.
      final serverPreference =
          candidatesResult?.metadata.preferredAudioLanguages;
      if (serverPreference != null) {
        _preferredAudioLanguages = serverPreference;
      }

      // The file actually being played. Normally the user's choice; on the
      // offline fall-through, or when the selected file was rejected by the
      // server and re-asked above, it is whatever the server ranked highest
      // instead.
      //
      // On both of those fall-throughs there is no `widget.fileId` worth
      // falling back to if the candidates call itself failed (network
      // hiccup, server unreachable): `widget.fileId` is either the
      // `'offline'` sentinel or a file id the server has just said does not
      // exist. Sending either on to `StartStreamingSession` would just
      // repeat a failure this branch exists to avoid, so fail here instead
      // with a message the user can act on — the same
      // throw-into-the-surrounding-catch convention used above for the
      // missing P2P server address.
      final playFileId = usesServerRankedFile
          ? candidatesResult?.fileId ??
              (throw Exception(
                  'Could not reach the server to find a playable file for '
                  'this title. Check your connection and try again.'))
          : widget.fileId;

      await _resolveQualityForFile(candidatesResult, gen);
      if (!_isCurrentLoad(gen)) return;

      final memory = await _openPlaybackMemory();
      if (!_isCurrentLoad(gen)) return;
      // The p2p branch threw above if the node address was missing, so the
      // cast is safe there; HTTP keys by URL.
      final serverKey = isP2PMode ? connectionState.serverNodeAddr! : serverUrl;
      _memory = memory;
      _serverKey = serverKey;
      _playFileId = playFileId;
      _attachScrubThumbnails(
        serverUrl: serverUrl,
        token: token,
        fileId: playFileId,
        isP2PMode: isP2PMode,
      );
      // After an await: `ref` is only safe while mounted.
      final linkPath = mounted ? _currentLinkPath() : null;

      final inputs = PlanInputs(
        candidates: candidateStrategiesFrom(candidatesResult?.candidates),
        isWeb: kIsWeb,
        typeSupported: CodecSupport.isTypeSupported,
        choice: QualityChoice.fromRung(_selectedQuality),
        sourceHeight: candidatesResult?.metadata.height,
        fileBitrateKbps:
            kbpsFromBitsPerSecond(candidatesResult?.metadata.bitrate),
        recentStall: linkPath == null
            ? null
            : memory?.recentStall(serverKey, linkPath, now: DateTime.now()),
        knownFailures:
            memory?.failuresFor(serverKey, now: DateTime.now()) ?? const {},
      );
      final playbackPlan = planPlayback(inputs);
      // The one line that turns "it picked the wrong path" into a lookup.
      debugPrint('[PlayerScreen] Plan: ${playbackPlan.describe()} '
          'shape=${inputs.shape.videoCodec}/${inputs.shape.heightBucket} '
          'bitrateKbps=${inputs.fileBitrateKbps} '
          'path=${linkPath?.name ?? 'unknown'} '
          'stallCeilingKbps=${inputs.recentStall?.ceilingKbps}');
      _playTimeline?.mark('planned');
      _plan = playbackPlan;
      _planInputs = inputs;
      _rememberOriginalDeliverySubtitle(inputs);
      _isDirectPlay = playbackPlan is DirectPlayPlan;

      // Resolve the real runtime before anything asks the player for it. On a
      // cold HLS stream media_kit only sees a partial, still-growing playlist,
      // so its own duration is useless here.
      //
      // The saved progress record ranks below server metadata deliberately: it
      // may itself have been written against a partial duration by an older
      // build.
      _totalDuration = _resolveRealDuration(candidatesResult);

      // Publish the duration to the timeline as soon as we know it. Casting can
      // short-circuit playback below, before any streaming session exists, and
      // the receiver cannot work the runtime out for itself: a Mydia HLS
      // playlist carries no EXT-X-ENDLIST until FFmpeg finishes. The offset is
      // still zero here; the session result rebuilds this with the real one.
      _timeline = StreamTimeline(totalDuration: _totalDuration);

      // Resolved here, upstream of both the cast fork below and the
      // HLS/direct fork further down. Every branch consumes this one value.
      // Keeping the decision inside the branches is what let three cast
      // exits and the offline path start at zero without ever asking.
      final plan = await resolveResumePlan(
        savedPositionSeconds: _savedPositionSeconds,
        realDuration: _totalDuration,
        resumeOverride: _consumeResumeOverride(),
        mounted: mounted,
        ask: (saved, total) async {
          if (!_isCurrentLoad(gen)) return null;
          return showResumeDialog(context, saved, total);
        },
      );
      if (plan == null) return;
      if (!_isCurrentLoad(gen)) return;

      if (await _castToTargetIfSet(plan, fileId: playFileId)) return;
      if (!_isCurrentLoad(gen)) return;

      if (playbackPlan is HlsPlan) {
        // Before a session is requested: past this point an FFmpeg transcode
        // runs on the instance and relay bytes are spent.
        final blocker = _relayedPlaybackBlocker();
        if (blocker != null) {
          if (mounted) {
            setState(() {
              _error = blocker;
              _isLoading = false;
            });
          }
          return;
        }
      }

      final StreamUrls urls;
      if (isP2PMode) {
        urls = ProxyStreamUrls(_mediaProxy);
      } else {
        urls = HttpStreamUrls(
          serverUrl: serverUrl,
          bearerToken: token,
          mediaToken: () async {
            final service =
                await ref.read(asyncMediaTokenServiceProvider.future);
            await service.ensureValidToken();
            return service.getToken();
          },
        );
      }

      // A previous controller's session, from a cast stop or a proxy
      // handoff re-running this method, is ended before it is dropped.
      await _playback?.endSession();
      if (!_isCurrentLoad(gen)) return;
      final playback = PlaybackController(
        client: () => _graphqlClient,
        urls: urls,
        features: ref.read(serverFeaturesProvider),
        relayed: _relayed,
      );
      _playback = playback;

      final source = await playback.open(
        playbackPlan,
        fileId: playFileId,
        startAt: plan.position,
        totalDuration: _totalDuration,
        onProgress: _setLoadingMessage,
      );
      if (!_isCurrentLoad(gen)) {
        // Opened for a file this State has moved past. The switch already
        // detached `_playback`, so nothing else will end this session.
        if (identical(_playback, playback)) _playback = null;
        await playback.endSession();
        return;
      }
      _applySource(source);

      // A windowed session baked the resume offset into FFmpeg's -ss, so it
      // opens at zero; every other source seeks to the real position.
      await _openPlayerAndStart(
        source.url,
        source.headers,
        plan: source.seekOnOpen ? plan : ResumePlan.fromStart,
        verificationPlan: playbackPlan,
      );
    } catch (e) {
      // A superseded load that fails must not tear down the player the
      // current load built.
      if (!_isCurrentLoad(gen)) return;
      debugPrint('Error initializing player: $e');
      // The player and its verification monitor, not the streaming session:
      // that stays owned by this screen until `dispose()`'s own
      // `_terminateHlsSession` ends it, same as every other error path here.
      // A widget test's `Player()` throws for an unrelated reason (no
      // `MediaKit.ensureInitialized`), and ending the session on that throw
      // would tear it down before the screen is ever unmounted.
      _stopVerification();
      await _disposePlayer();
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// The real runtime, from the most trustworthy source available.
  Duration? _resolveRealDuration(
    Query$StreamingCandidates$streamingCandidates? candidatesResult,
  ) {
    final fromCandidates = candidatesResult?.metadata.duration;
    if (fromCandidates != null && fromCandidates > 0) {
      return Duration(milliseconds: (fromCandidates * 1000).round());
    }

    final fromProgress = _savedDurationSeconds;
    if (fromProgress != null && fromProgress > 0) {
      return Duration(seconds: fromProgress);
    }

    final fromRuntime = _runtimeMinutes;
    if (fromRuntime != null && fromRuntime > 0) {
      return Duration(minutes: fromRuntime);
    }

    return null;
  }

  /// Rebuilds the quality ladder for the file about to play and settles which
  /// rung this playback will request.
  ///
  /// The ladder is per-file, not per-widget: it depends on the source height,
  /// and a rung chosen while watching a taller file may not exist in this
  /// one's ladder. Falling back to Auto there beats requesting an upscale,
  /// which costs encode time to produce a larger, blurrier picture.
  ///
  /// The rung is *seeded* from storage and then carried in memory. Re-reading
  /// it here on every re-initialization would put a fallible platform channel
  /// on the only path carrying the viewer's choice: a swallowed write failure
  /// would make the restart negotiate the rung they just replaced, and the
  /// label would revert in front of them. See [_settledQuality].
  Future<void> _resolveQualityForFile(
    Query$StreamingCandidates$streamingCandidates? candidatesResult,
    int gen,
  ) async {
    _qualityLadder = deriveQualityLadder(
      sourceHeight: candidatesResult?.metadata.height,
    );

    final requested = _settledQuality ?? await _storedDefaultQuality();
    if (!_isCurrentLoad(gen)) return;

    if (requested.isAuto || _qualityLadder.contains(requested)) {
      _settledQuality = requested;
    } else {
      // The carried rung would upscale this file; Auto, the default, decides
      // instead.
      _settledQuality = QualityRung.auto;
    }
  }

  Future<PlaybackMemory?> _openPlaybackMemory() async {
    try {
      return await ref.read(playbackMemoryProvider.future);
    } catch (e) {
      debugPrint('[PlayerScreen] Playback memory unavailable: $e');
      return null;
    }
  }

  /// Everything the screen keeps from a source the controller opened.
  void _applySource(PlaybackSource source) {
    _fullPlaylist = source.fullPlaylist;
    _timeline = source.timeline;
    _effectiveQuality = source.effectiveRung;
    _totalDuration ??= source.timeline.totalDuration;
    _progressService?.timeline = _timeline;
    debugPrint('[PlayerScreen] Stream timeline: $_timeline');
  }

  /// Opens [source] on the live player at [at], and returns the position
  /// stream the controller waits on before ending the old session.
  ///
  /// Native keeps the `Player`: the last frame holds and every subscription
  /// stays bound. Web recreates it, because media_kit 1.2.6's web backend
  /// stacks an hls.js instance per `open()` and never destroys the previous
  /// one. See "The switch" in player/docs/playback.md.
  ///
  /// Never arms verification, on either platform: a switch is already the
  /// policy's own decision (or a seek/quality change the viewer made), and
  /// the controller serialises it against a second switch or a fallback —
  /// `_switchSource` re-arms only once `replaceSource` has actually landed
  /// the new source. Arming here would let a fault on the incoming source
  /// be deferred to a policy that is about to mark itself done and hand
  /// back a `FallbackToTranscode` `_fallbackToTranscode` immediately drops
  /// (`_switchingSource` is still true), silently swallowing the fault for
  /// up to `replaceSource`'s 60s first-advance bound.
  Future<Stream<Duration>> _attachSource(
    Player player,
    PlaybackSource source, {
    required Duration at,
  }) async {
    // The live subscriptions observe the new source as soon as open starts,
    // including while the controller still waits for its first advance.
    _applySource(source);
    if (kIsWeb) {
      await _disposePlayer();
      final fresh = await _openPlayerAndStart(
        source.url,
        source.headers,
        plan: source.seekOnOpen ? ResumePlan(at) : ResumePlan.fromStart,
        // This is `_switchSource`'s web continuation, not a fresh media
        // item: a fallback's `_lastFallback` was set moments ago by the
        // caller and must survive into the replacement source.
        isSourceSwitch: true,
      );
      return fresh.stream.position;
    }

    // Same bookkeeping `_openPlayerAndStart` does for a new player: nothing
    // this source has done has been observed yet.
    final playerTarget =
        source.seekOnOpen ? source.timeline.toPlayer(at) : Duration.zero;
    _playbackAdvanced = false;
    _furthestPosition = playerTarget;
    final opening = mediaStartingAt(
      source.url,
      httpHeaders: source.headers,
      position: playerTarget,
      isWeb: kIsWeb,
    );
    // A new open on the same `Player`: its track list is not mpv's own until
    // the probe below settles, exactly like a fresh `_openPlayerAndStart`.
    // Without this a switch landing on direct play would leave the previous
    // source's `true` in place, and a preference not yet applied could match
    // this file's pre-probe server fallback and fetch a stream mpv is about
    // to report itself.
    final tracksSettleEpoch = _beginTracksSettle();
    await player.open(opening.media, play: false);
    _detectTracks();
    if (opening.seekAfterOpen) await player.seek(playerTarget);
    await player.play();
    // Not awaited: unlike `_openPlayerAndStart`, this switch must not wait on
    // mpv's probe before returning. `_detectTracks()` above already read
    // whatever mpv knew synchronously; this only re-runs it once the probe
    // actually settles, so a preference still waiting on `_awaitingPlayerTracks`
    // gets its chance through `_onTracksChanged` instead of being stuck behind
    // the outgoing source's flag for the rest of the playback.
    //
    // `player.state.tracks` is the right `current` to hand `awaitRealTracks`
    // even though `player` is reused across the switch: media_kit's native
    // `open()` resets it to `const Tracks()` through its own internal
    // `stop(open: true)` before it loads anything (media_kit 1.2.6
    // `lib/src/player/native/player/real.dart`, `open()`'s call to `stop()`
    // around line 173; `stop()`'s `state = PlayerState().copyWith(...)`
    // there does not carry `tracks` forward, so it reverts to the
    // `PlayerState()` default). By the time `await player.open(...)` above
    // returns, `player.state.tracks` already reflects that reset, or real
    // tracks mpv reported just as fast -- never the outgoing file's list.
    //
    // `_settleTracks` (not the plain identity check `_openPlayerAndStart`
    // gets away with) is what makes this safe to fire late: two switches on
    // the same `Player` share both `_player` and `player`, so a stale wait
    // from a switch a second one already superseded would otherwise pass an
    // identity check and mark a newer, still-probing file settled. The
    // epoch `_beginTracksSettle` handed this wait is what tells the two
    // apart.
    unawaited(awaitRealTracks(
      current: player.state.tracks,
      updates: player.stream.tracks,
    ).then((_) {
      if (_settleTracks(tracksSettleEpoch, player)) _detectTracks();
    }));
    return player.stream.position;
  }

  /// Replaces what is playing with [plan] at [at], keeping the player.
  ///
  /// Serialised by the controller: a switch while one is in flight throws,
  /// and every caller checks `switching` first. Returns whether the new
  /// source actually took effect: `false` when this call did nothing (a
  /// switch was already in flight, the playback, player or file id was
  /// missing, or the widget was unmounted or `_playback` had already been
  /// replaced before the new source landed), `true` once it applied.
  Future<bool> _switchSource(PlaybackPlan plan, {required Duration at}) async {
    if (_switchingSource) return false;
    final playback = _playback;
    final player = _player;
    final fileId = _playFileId;
    if (playback == null || player == null || fileId == null) return false;

    // An active scrub must not commit into the stream being replaced. A
    // settling target survives: when this switch is a seek restart, it is
    // the very target the restart is heading for.
    _scrub.cancel();

    // Closed from the progress save through the landing, so no subtitle call
    // reaches a player this is replacing. The restore starts only once the
    // gate has reopened, since its own calls pass through it.
    final landed = await _switchGate.closeWhile(() async {
      // Persist where the viewer actually is before the old source goes away.
      await _saveProgress();
      // Read while the old file is still loaded, since an mpv track's stream
      // index can only be read from its own file. Committed only once
      // replaceSource has landed, so a throw there does not leave intent
      // pending and block sync for the rest of playback.
      final subtitleIntent =
          _subtitleIntentAcrossSwitch ?? await _captureSubtitleIntent(player);
      if (!mounted || !identical(playback, _playback)) return false;
      _stopVerification();

      // Every switch past this point keeps the same `Player` (a fallback, a
      // manual quality change, a seek restart): a fresh dropped-frame
      // baseline and an empty sparkline history, or the next sample diffs
      // against the outgoing source's counters and reports a spike that
      // never happened. After the abort checks above, not before: an
      // aborted switch (unmounted, or `_playback` already replaced) must
      // not wipe a history nothing is actually replacing.
      _statsCollector?.rebind();

      final source = await playback.replaceSource(
        plan,
        fileId: fileId,
        realPosition: at,
        totalDuration: _totalDuration,
        attach: (source) => _attachSource(player, source, at: at),
        onProgress: (message) => debugPrint('[PlayerScreen] $message'),
      );
      if (!mounted || !identical(playback, _playback)) return false;
      _subtitleIntentAcrossSwitch = subtitleIntent;
      if (subtitleIntent != null) {
        // Supersedes a pick or restore still resolving, which is waiting at
        // the gate for this switch: its target is the intent just captured,
        // and the restore below applies that to the new file instead.
        _subtitleSelectionGeneration++;
      }
      setState(() {
        _plan = plan;
        _isDirectPlay = plan is DirectPlayPlan;
        _applySource(source);
        // A fault that landed on `player.stream.error` while this switch was
        // in flight (verification is deliberately unarmed until it lands,
        // see `_attachSource`) can still have set `_error` even though the
        // switch just succeeded. Clear it here so a working video is never
        // left behind the error page.
        _error = null;
        // Derived again for the mode just adopted: `_attachSource` detected
        // tracks while `_isDirectPlay` still described the old source.
        _applySubtitleTracks(
            _player?.state.tracks.subtitle ?? const <SubtitleTrack>[]);
        // Nothing is applied on the new file yet. The restore below sets
        // this once the carried choice actually takes effect.
        if (_subtitleIntentAcrossSwitch != null) _selectedSubtitleTrack = null;
      });
      _startVerification(plan);
      return true;
    });
    if (landed) unawaited(_restoreSubtitleIntent());
    return landed;
  }

  /// What [_switchSource] carries to the new source: the latest pick,
  /// counting one still resolving, in the server's id space. Null when the
  /// viewer never chose this playback, so mpv keeps its own defaults.
  ///
  /// An mpv-native pick is translated through its stream index, which has
  /// to be read now, while the file it belongs to is still loaded. Read
  /// directly, not through [_switchGate]: this runs inside the switch that
  /// holds the gate, so a pass would wait for its own switch forever.
  Future<SubtitleIntent?> _captureSubtitleIntent(Player player) async {
    final pending = _pendingSubtitleSelection;
    final selected = pending is TargetTrack ? pending.track : null;
    final mpvId = selected == null ? null : mpvIdOfSubtitleTrack(selected.id);
    final streamIndex =
        mpvId == null ? null : (await subtitleStreamIndices(player))[mpvId];
    return subtitleIntentBeforeSwitch(
      selected: selected,
      viewerChose: _subtitleChosenThisPlayback,
      selectedStreamIndex: streamIndex,
      serverTracks: _serverSubtitleTracks,
    );
  }

  /// Re-applies the choice [_switchSource] carried across, on the source
  /// that just landed.
  ///
  /// mpv loses a `sub-add`ed track when it opens a new file, and media_kit
  /// resets its own record of the selection, so neither can say what should
  /// be showing now; [_subtitleIntentAcrossSwitch] is the only record.
  /// Applied through [_applySubtitleSelection] like any pick, so a viewer
  /// pick or another switch arriving meanwhile supersedes it cleanly.
  Future<void> _restoreSubtitleIntent() async {
    final intent = _subtitleIntentAcrossSwitch;
    if (intent == null || _player == null || !mounted) return;

    // A viewer pick or a newer switch during the read below bumps this and
    // then owns the choice.
    final token = _subtitleSelectionGeneration;
    bool stillCurrent() =>
        mounted && token == _subtitleSelectionGeneration && _player != null;

    var indices = const <String, int>{};
    if (_isDirectPlay) {
      // Through the gate: a stream index has to come from the file this
      // restore is for, not from one a newer switch is opening.
      final read = await _switchGate.pass(stillCurrent, () async {
        final player = _player;
        if (player != null) indices = await subtitleStreamIndices(player);
      });
      if (!read) return;
    }
    if (!stillCurrent()) return;

    final restore = resolveSubtitleIntent(
      intent: intent,
      tracks: _subtitleTracks,
      streamIndexByMpvId: indices,
    );
    final generation = await _applySubtitleSelection(
      restore is RestoreTrack ? restore.track : null,
      keepNudge: true,
    );
    if (generation != _subtitleSelectionGeneration) return;

    if (restore is RestoreUnavailable) {
      _showToast(restore.message);
      return;
    }
    if (subtitleRestoreConsumed(
        restore: restore, selected: _selectedSubtitleTrack)) {
      _subtitleIntentAcrossSwitch = null;
    }
  }

  /// Selects the subtitle this viewer already chose for this show, or turns
  /// subtitles off if that is what they chose.
  ///
  /// Runs off the back of a track-list revision rather than from
  /// `_initializePlayer`, because the list is what it matches against and in
  /// direct play that list is mpv's, published asynchronously after `open()`.
  ///
  /// Nothing is consumed unless a selection can actually be made. A
  /// `PreferTrack` that matches nothing does nothing at all, and shows no
  /// toast: episode transitions are frequent, and a line on every episode of
  /// a season that lacks the track is noise the viewer cannot act on. The
  /// subtitle button is already on the OSD. Neither that case nor a call
  /// arriving before there is a player spends
  /// [_preferenceAppliedForPlayback], so the next revision still gets its
  /// chance -- which is what stops a direct-play file whose track list is
  /// already complete from losing the preference for the whole playback. In
  /// native direct play it also waits for the open to pass mpv's probe, and
  /// matches on the server's tracks before translating to mpv's own (see
  /// [preferenceTarget]), so a stream the file already carries is never
  /// fetched from the server.
  Future<void> _applySubtitlePreference() async {
    final preference = _subtitlePreference;
    if (preference == null) return;

    if (!shouldApplySubtitlePreference(
      viewerChose: _subtitleChosenThisPlayback,
      switchInFlight: _switchingSource,
      intentPending: _subtitleIntentAcrossSwitch != null,
      alreadyApplied: _preferenceAppliedForPlayback,
      hasTracks: _subtitleTracks.isNotEmpty,
      awaitingPlayerTracks: _awaitingPlayerTracks,
    )) {
      return;
    }

    // A selection with no player behind it goes nowhere: the fetch and the
    // `setSubtitleTrack` are both behind `_applySubtitleSelection`'s own
    // `_player == null` bailout. Spending the one-shot here would leave the
    // preference permanently unapplied for a playback whose track list is
    // already complete, so this waits for a revision that has one.
    final player = _player;
    if (player == null) return;

    // Set before the first await, not after: a second track-list revision can
    // land while the target below is still resolving, and two concurrent
    // applies of the same preference would race each other's generation.
    // Given back below whenever nothing ends up selected.
    _preferenceAppliedForPlayback = true;

    // Null is "Off", and Off is applied like any other selection rather than
    // skipped: mpv switches on whichever track the container flagged default,
    // so leaving it alone is exactly the behaviour the viewer turned off.
    app_models.SubtitleTrack? target;
    switch (preference) {
      case PreferOff():
        target = null;
      case PreferTrack():
        target = await _preferenceTrackTarget(preference, player);
        // Nothing to select, and nothing to say about it here; see the
        // dartdoc above for why this stays quiet.
        if (target == null) {
          _preferenceAppliedForPlayback = false;
          return;
        }
    }

    final generation = await _applySubtitleSelection(target);

    // A revision landed mid-apply and bumped the generation, so
    // `shouldApplySubtitleSelection` discarded the selection. Give the
    // preference back its one shot and take it now, against the list that
    // superseded it: waiting for another revision would lose the preference
    // outright when this was the last one.
    //
    // Only when the target is not what is showing, which is what separates a
    // discarded apply from a delivered one. A selection superseded after it
    // reached the player -- the Off path is the one that can be -- has already
    // been acted on, and re-sending it would double every such command. See
    // `subtitle_preference_apply_test.dart`, whose two revision cases pin the
    // two sides of that line.
    if (generation != _subtitleSelectionGeneration &&
        _selectedSubtitleTrack != target) {
      if (_preferenceApplyRetries < _maxPreferenceApplyRetries) {
        _preferenceApplyRetries++;
        _preferenceAppliedForPlayback = false;
        await _applySubtitlePreference();
      } else {
        debugPrint('[PlayerScreen] Gave up re-applying the subtitle '
            'preference after $_preferenceApplyRetries retries');
      }
    }

    if (generation == _subtitleSelectionGeneration &&
        _selectedSubtitleTrack?.id == target?.id) {
      debugPrint(target == null
          ? '[PlayerScreen] Subtitle preference applied: Off'
          : '[PlayerScreen] Subtitle preference applied: '
              '${target.displayName} via '
              '${isMpvNativeSubtitleTrackId(target.id) ? 'mpv' : 'server'}');
    }
  }

  /// The track [preference] names on the list now on screen; see
  /// [preferenceTarget].
  ///
  /// Reads mpv's stream indices only when mpv's own tracks are on screen,
  /// and through [_switchGate] for the same reason [_restoreSubtitleIntent]
  /// does: an index has to come from the file it will be applied to. Null
  /// when nothing matches, or when the player changed or the viewer picked
  /// while the read was waiting.
  Future<app_models.SubtitleTrack?> _preferenceTrackTarget(
    PreferTrack preference,
    Player player,
  ) async {
    var indices = const <String, int>{};
    if (_subtitleTracks.any((t) => isMpvNativeSubtitleTrackId(t.id))) {
      bool stillCurrent() =>
          mounted && identical(_player, player) && !_subtitleChosenThisPlayback;
      final read = await _switchGate.pass(stillCurrent, () async {
        indices = await subtitleStreamIndices(player);
      });
      // A switch can land a new file on this same player while the read
      // waits, leaving that file's pre-probe server fallback on screen.
      // Matching it would fetch a stream mpv is about to offer natively; the
      // settle that ends the probe re-runs this against mpv's own list.
      if (!read ||
          !stillCurrent() ||
          _awaitingPlayerTracks ||
          _switchingSource) {
        return null;
      }
    }
    return preferenceTarget(
      pref: preference,
      serverTracks: _serverSubtitleTracks,
      tracks: _subtitleTracks,
      streamIndexByMpvId: indices,
    );
  }

  /// Monitors a source and lets the policy decide when to replace it.
  ///
  /// Never armed for a downloaded or offline file, which has no server to
  /// fall back to, and never for a cast session.
  void _startVerification(PlaybackPlan plan) {
    _stopVerification();
    final player = _player;
    if (player == null || _isDownloadedSource) return;

    final kind = switch (plan) {
      DirectPlayPlan() => SourceKind.direct,
      HlsPlan(strategy: HlsStrategy.copy) => SourceKind.copy,
      HlsPlan() => SourceKind.transcode,
    };
    final monitor = PlaybackMonitor(
      signals: PlayerSignals.of(player),
      sampler: frameStatsSamplerFor(player),
    );
    final policy = AdaptationPolicy(
      source: kind,
      // Original asks for the file's own bytes: a slow link buffers rather
      // than being swapped for a transcode.
      reactsToBandwidth: !_selectedQuality.isOriginal,
    );
    _monitor = monitor;
    _policy = policy;
    _healthSubscription =
        monitor.samples.listen((sample) => _onHealthSample(sample, policy));
    monitor.start();
    debugPrint('[PlayerScreen] Verifying ${kind.name} source');
  }

  void _stopVerification() {
    unawaited(_healthSubscription?.cancel());
    _healthSubscription = null;
    unawaited(_monitor?.dispose());
    _monitor = null;
    _policy = null;
  }

  /// Starts, restarts or stops the collector to match the flag.
  ///
  /// Separate from `_startVerification`: that arms `AdaptationPolicy` and
  /// deliberately skips a downloaded file and a cast session, while the
  /// panel reports on whatever is playing.
  void _startStatsCollector(Player player) {
    _stopStatsCollector();
    if (!(ref.read(statsOverlayEnabledProvider).value ?? false)) return;
    final collector = PlaybackStatsCollector(
      signals: PlayerSignals.of(player),
      sampler: frameStatsSamplerFor(player),
    );
    _statsCollector = collector;
    collector.start();
  }

  void _stopStatsCollector() {
    unawaited(_statsCollector?.dispose());
    _statsCollector = null;
  }

  void _onHealthSample(HealthSample sample, AdaptationPolicy policy) {
    // A sample from a monitor that has since been replaced.
    if (!mounted || !identical(policy, _policy)) return;

    final action = policy.observe(sample);
    if (action is FallbackToTranscode) {
      unawaited(_fallbackToTranscode(action));
    }
  }

  Future<void> _fallbackToTranscode(FallbackToTranscode action) async {
    final playback = _playback;
    final player = _player;
    final inputs = _planInputs;
    if (playback == null || player == null || inputs == null) return;
    if (_switchingSource) return;

    final position = _timeline.toReal(player.state.position);
    final throughput = action.throughputKbps ?? inputs.recentStall?.ceilingKbps;
    final plan = fallbackPlan(
      choice: QualityChoice.fromRung(_selectedQuality),
      sourceHeight: inputs.sourceHeight,
      throughputKbps: throughput,
    );
    debugPrint('[PlayerScreen] Falling back to ${plan.describe()}: '
        '${action.reason.name} at ${position.inSeconds}s (${action.detail})');

    final memory = _memory;
    final serverKey = _serverKey;
    if (memory != null && serverKey != null) {
      try {
        switch (action.reason) {
          case FailureReason.decodeFailed:
          case FailureReason.decodeTooSlow:
            await memory.recordFailure(
              serverKey,
              FailureKey.fromShape(inputs.shape),
              action.reason,
              now: DateTime.now(),
            );
          case FailureReason.bandwidth:
            // The path now, not at plan time: a relay switch mid-play is
            // exactly when a stall is likely. Read before the first await,
            // while `_onHealthSample`'s mounted check still holds.
            final path = _currentLinkPath();
            final ceiling = stallCeilingKbps(
              measuredKbps: action.throughputKbps,
              fileBitrateKbps: inputs.fileBitrateKbps,
            );
            if (path != null && ceiling != null) {
              await memory.recordStall(serverKey, path, ceiling,
                  now: DateTime.now());
            }
        }
      } catch (e) {
        debugPrint('[PlayerScreen] Could not update playback memory: $e');
      }
    }

    // The choice stays the viewer's: `fallbackPlan` already honours it as
    // closely as this device allows. The stored default is never written
    // here either, since one file failing says nothing about the next.
    _showToast(fallbackMessage(action.reason));
    try {
      final switched = await _switchSource(plan, at: position);
      // For the panel's Why row, recorded only once the switch actually
      // took effect: `_switchSource` returns false when it aborted
      // (unmounted, or `_playback` already replaced), and recording the
      // fallback anyway would leave the row reporting a switch that never
      // happened. The dropped-frame baseline is reset by `_switchSource`
      // itself (every caller keeps the same `Player`, not just this one),
      // so it is not repeated here.
      if (switched) {
        _lastFallback =
            StatsFallback(reason: action.reason, detail: action.detail);
      }
    } catch (e) {
      debugPrint('[PlayerScreen] Fallback failed: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _showToast(String message, {ToastKind kind = ToastKind.info}) {
    if (!mounted) return;
    showToast(context, message, kind: kind);
  }

  void _setLoadingMessage(String message) {
    if (mounted) setState(() => _loadingMessage = message);
  }

  /// The Original rung's subtitle: what the planner would do with the
  /// Original choice, whatever is selected now. Labels only.
  void _rememberOriginalDeliverySubtitle(PlanInputs inputs) {
    _originalDeliverySubtitle = deliverySubtitleForPlan(
      planPlayback(inputs.copyWith(choice: QualityChoice.original)),
    );
  }

  /// The rung stored as this install's default, for the first session of a
  /// playback.
  ///
  /// Secure storage being unreadable is no reason to fail playback, and
  /// Auto, the default, is the answer then. Matches how
  /// `_loadAutoSkipPreference` treats the same failure.
  Future<QualityRung> _storedDefaultQuality() async {
    try {
      final storedKey =
          await ref.read(settingsServiceProvider).getDefaultQuality();
      return QualityRung.fromStorageKey(storedKey) ?? QualityRung.auto;
    } catch (e) {
      debugPrint('[PlayerScreen] Could not read default quality: $e');
      return QualityRung.auto;
    }
  }

  /// Shared tail of _initializePlayer: create player, open the media, start
  /// playback.
  ///
  /// Reached by three paths, not just the HLS one: the HLS branch, the
  /// direct-play branch, and the "already downloaded, still online" branch.
  /// It no longer prompts — the resume decision is made once, upstream of
  /// every fork, by [resolveResumePlan] — it only executes [plan]. A windowed
  /// HLS session bakes that same decision into FFmpeg's start offset instead,
  /// the only way to resume a live-style playlist, so [plan] arrives here
  /// already neutralized to [ResumePlan.fromStart] for it. The other three —
  /// direct play, "already downloaded", and a full-playlist HLS session —
  /// hold or expose the whole file at real coordinates and have nothing to
  /// bake an offset into, so for them resuming is a plain [Player.seek] after
  /// the media opens.
  ///
  /// A fourth path reaches this too: web's `_attachSource` reopens the
  /// whole `Player` for a mid-session switch (`_switchSource`), and passes
  /// [isSourceSwitch] so this does not treat that continuation as a fresh
  /// media item.
  Future<Player> _openPlayerAndStart(
    String mediaSource,
    Map<String, String> httpHeaders, {
    required ResumePlan plan,
    PlaybackPlan? verificationPlan,
    bool isSourceSwitch = false,
  }) async {
    if (mounted) {
      setState(() {
        _loadingMessage = null;
      });
    }

    // Web: put hls.js in media_kit's path before it can choose the browser's
    // own HLS engine, which cannot play a Mydia session (see
    // `core/player/hls_engine.dart`). Ahead of the `Player` below, because
    // media_kit makes that choice when the source opens and keeps it for the
    // life of the session. A no-op on native, and on web when hls.js cannot
    // run at all.
    await prepareHlsEngine();

    // Create media_kit player
    final player = widget.createPlayer?.call() ?? Player();
    _player = player;
    _videoController = VideoController(
      player,
      configuration: videoControllerConfigurationFor(
        defaultTargetPlatform,
        isWeb: kIsWeb,
      ),
    );
    // Hands the backend the media_kit player so the web backend can reach the
    // underlying HTMLVideoElement. A no-op on native.
    //
    // Called again for every source this screen plays, and that repetition is
    // load-bearing: each one is a fresh `Player` with a fresh element, and a
    // backend still holding the previous one would fullscreen a disposed
    // element. The backend keys on instance identity, so a repeat with the same
    // player is free.
    _fullscreen.attach(player);
    _publishFullscreenReport();

    // Bound before `open` deliberately: a source that fails to resolve at all
    // (a deleted file id, a dead HLS session) errors during the open itself,
    // which a subscription attached afterwards would miss entirely.
    //
    // This is a brand new `Player`, so nothing it does has been observed yet:
    // a previous source's progress must not vouch for this one.
    _playbackAdvanced = false;
    _furthestPosition = Duration.zero;
    await _errorSubscription?.cancel();
    _errorSubscription = player.stream.error.listen(_onPlaybackError);
    await _nowPlayingSubscription?.cancel();
    _nowPlayingSubscription =
        player.stream.playing.listen((_) => _publishNowPlaying());

    await _cancelMediaSessionSubscriptions();
    void announce(Object? _) => _remoteTargetController.notifyChanged();
    _mediaSessionSubscriptions.addAll([
      player.stream.buffering.listen(announce),
      player.stream.completed.listen(announce),
      player.stream.volume.listen(announce),
      player.stream.duration.listen(announce),
    ]);

    // Re-bound whenever `_initializePlayer` runs again for this screen: a
    // source switch, a session restart, or a fresh `PlayerScreen` state for
    // a new queue item. It is *not* re-bound by navigating to the next
    // episode of a season -- that reuses this same `PlayerScreen` state
    // (go_router keys the page by route pattern, not the resolved path), so
    // `initState` and this call do not run again then. The sizer cancels
    // the previous subscription itself.
    _windowSizer?.bindVideoParams(player.stream.videoParams);

    // A new open: its track list is not mpv's until the probe below.
    // `_openPlayerAndStart` always gets a brand new `Player` (`_attachSource`
    // is what reuses one across a switch), so the plain `identical(_player,
    // player)` check below is already enough on its own; the epoch is taken
    // anyway for consistency with `_attachSource`'s native branch, which
    // needs it.
    final tracksSettleEpoch = _beginTracksSettle();

    // Subscribe before opening. `player.stream.tracks` is a plain broadcast
    // stream with no replay, so a revision published between `open()` and the
    // detection pass below would otherwise be lost — which is the whole
    // failure this guards against.
    await _tracksSubscription?.cancel();
    _tracksSubscription = watchTracks(player.stream.tracks, _onTracksChanged);

    // Once per `Player`, before `open`, so a default bitmap track mpv picks
    // while opening is drawn too. See `subtitle_render.dart` for why mpv,
    // not media_kit's overlay, has to draw those.
    unawaited(watchSubtitleRendering(player));

    // Before `open`, deliberately: mpv chooses its audio track while loading
    // the file, so a preference applied afterwards does not reselect and the
    // viewer still starts on the wrong language. Without this, mpv falls
    // through to whatever the container flagged `default`, which on a
    // dual-language release is routinely the dub — the reason an English show
    // could open in Russian.
    await AudioLanguage.apply(player, _preferredAudioLanguages);

    // Broadcast errors and playing events can arrive during open/play.
    // Subscribe now so verification sees even a decoder's first failure.
    if (verificationPlan != null) _startVerification(verificationPlan);

    // Unconditional, unlike `_startVerification` above: the panel reports
    // on a downloaded file too, which `_startVerification` deliberately
    // skips (see its own `_isDownloadedSource` guard).
    _startStatsCollector(player);

    // A genuinely fresh media item: whatever this session last fell back
    // to says nothing about it, and without clearing it here a stale Why
    // message from a previous file would outlive the source it explained.
    // Not cleared when `isSourceSwitch`, since that is `_switchSource`'s
    // own web continuation and the one case (a fallback) where the
    // message just set must survive into the replacement source.
    if (!isSourceSwitch) _lastFallback = null;

    // Open media, already positioned at [plan] where the platform allows it.
    // These paths hold the whole file, so the player's own coordinates
    // already are the real ones and there is no session that could need
    // restarting. A full-playlist HLS session reaches this too: the call site
    // passes the real `plan` (not `ResumePlan.fromStart`) exactly when
    // `source.seekOnOpen`, so this is already its resume.
    final opening = mediaStartingAt(
      mediaSource,
      httpHeaders: httpHeaders,
      position: plan.position,
      isWeb: kIsWeb,
    );
    await player.open(opening.media, play: false);
    _playTimeline?.mark('opened');

    // Watches for the first real frame, marks it and logs the timeline's one
    // summary line, then cancels itself -- an explicit subscription rather
    // than `firstWhere(...).timeout(...)`, which never cancels its own
    // subscription when the timeout fires and would leak one per source.
    // `_disposePlayer` cancels this (and flushes whatever marks exist) before
    // every later call to this method, so there is never more than one live.
    final firstFrameTimeline = _playTimeline;
    _firstFrameSubscription = player.stream.width.listen((width) {
      if (width == null || width <= 0) return;
      firstFrameTimeline?.mark('first_frame');
      firstFrameTimeline?.logOnce();
      unawaited(_firstFrameSubscription?.cancel());
      _firstFrameSubscription = null;
    });

    // Wait for mpv to probe the media before reading tracks, capped so a
    // source that never reports any still starts. Used to be a fixed 500 ms.
    // media_kit 1.2.6's web backend never reports a track with a real id --
    // `WebPlayer` only ever adds a bare `Tracks()`, in `stop()` -- so web
    // would otherwise burn the full cap on every open and every source
    // switch (`isSourceSwitch` only ever happens on web). Keep web at
    // exactly its old 500 ms instead.
    final tracksReady = await awaitRealTracks(
      current: player.state.tracks,
      updates: player.stream.tracks,
      timeout: kIsWeb
          ? const Duration(milliseconds: 500)
          : const Duration(seconds: 3),
    );
    // `dispose()` may have run while this was suspended: it nulls `_player`
    // and disposes both `player` and the progress service. `identical`
    // also catches a newer `_openPlayerAndStart` call (a source switch)
    // having replaced `_player` out from under this one. Bailing out here,
    // before anything below touches `player` or `_progressService` again,
    // is what keeps e.g. `player.play()` from throwing against a
    // `PlatformPlayer` whose stream controllers `dispose()` already closed.
    if (!mounted || !identical(_player, player)) return player;
    _settleTracks(tracksSettleEpoch, player);
    if (!tracksReady && !kIsWeb) {
      // Timing out on web is the expected path, not worth logging every time.
      debugPrint(
          '[PlayerScreen] No tracks reported before the cap; continuing');
    }
    _playTimeline?.mark('tracks_ready');

    // Detect available tracks from media_kit. Covers whatever mpv already
    // knew before the subscription above went live; anything discovered
    // later arrives through that subscription instead.
    _detectTracks();

    // Applied through the same `selectTrack` a remote `SelectAudioTrack`/
    // `SelectSubtitleTrack` command uses, right after detection so both
    // `_audioTracks`/`_subtitleTracks` and their media_kit id maps are
    // populated. Only ever non-null for a `LoadContent`-originated screen —
    // every other call site leaves these null, which is a no-op here.
    if (widget.audioTrack != null) {
      await selectTrack(TrackKind.audio, widget.audioTrack);
    }
    if (widget.subtitleTrack != null) {
      await selectTrack(TrackKind.subtitle, widget.subtitleTrack);
    }

    // Web only; see `mediaStartingAt`. A plain seek, not a `seekToReal`, for
    // the same reason as the open above.
    if (opening.seekAfterOpen) {
      await player.seek(plan.position);
    }

    // The bar a position has to clear to count as playback. Zero on a
    // windowed HLS session, which always arrives here with
    // `ResumePlan.fromStart` because its offset went into FFmpeg's `-ss`
    // instead, so its player-local coordinates genuinely do start at zero.
    // Direct play and full-playlist HLS both carry the real resume position
    // through instead, matching the seek above.
    _furthestPosition = plan.position;

    // Start playback, unless a remote `LoadContent` asked to load without
    // playing. Every other caller leaves `autoplay` at its default of true.
    if (widget.autoplay) {
      await player.play();
    }

    // Start progress tracking
    if (_progressService != null) {
      _progressService!.timeline = _timeline;
      if (widget.mediaType == 'movie') {
        _progressService!.startMovieSync(player, widget.mediaId);
      } else if (widget.mediaType == 'episode') {
        _progressService!.startEpisodeSync(player, widget.mediaId);
      }
    }

    // Listen for playback completion
    await _positionSubscription?.cancel();
    _positionSubscription = player.stream.position.listen((_) {
      _onPlaybackProgress();
    });

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }

    debugPrint('Loaded ${_subtitleTracks.length} subtitle tracks from GraphQL');
    return player;
  }

  /// Resolve the actual file path for a downloaded media file.
  ///
  /// The stored path may not match the actual location due to a bug where
  /// the previous download backend received a full absolute path as a relative
  /// directory, causing doubled paths. This tries the stored path first,
  /// then checks alternative locations.
  Future<String?> _resolveDownloadedFilePath(String storedPath) async {
    // Try the stored path first
    if (await file_utils.fileExists(storedPath)) {
      return storedPath;
    }

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final filename = storedPath.split('/').last;

      // Try the standard downloads directory with just the filename
      final standardPath = '${docsDir.path}/downloads/$filename';
      if (standardPath != storedPath &&
          await file_utils.fileExists(standardPath)) {
        debugPrint('[PlayerScreen] Found file at standard path: $standardPath');
        return standardPath;
      }

      // Try the doubled path (legacy bug: full absolute path was passed
      // as relative directory to previous download backend)
      final doubledPath = '${docsDir.path}$storedPath';
      if (await file_utils.fileExists(doubledPath)) {
        debugPrint('[PlayerScreen] Found file at doubled path: $doubledPath');
        return doubledPath;
      }
    } catch (e) {
      debugPrint('[PlayerScreen] Error resolving download path: $e');
    }

    return null;
  }

  /// Fetch streaming candidates from the server via GraphQL.
  ///
  /// `networkOnly` is load-bearing. The primary call here is keyed by the
  /// specific file the user selected (`('file', widget.fileId)`), not by
  /// content id. When the server rejects that file id — e.g. because a
  /// quality upgrade trashed it (`Mydia.Upgrades.apply_upgrade/4`) — the
  /// caller in [_initializePlayer] re-asks by media item and plays whatever
  /// the server ranks instead (`playFileId`). That self-heal only works if
  /// the rejection is actually visible: a warm cache entry for
  /// `('file', id)` recorded before the file was trashed still holds a
  /// *successful* response, with no `graphqlErrors`, because the request
  /// that produced it really did succeed at the time. Serving that cached
  /// hit would make `result.hasException` false, so `serverRejected` below
  /// would never be true, and the self-heal would silently never fire — the
  /// exact bug this whole mechanism exists to avoid. `networkOnly` is what
  /// forces a live request every time, so a rejection is always observable.
  /// That is the load-bearing reason, not merely keeping a stale `fileId`
  /// out of the direct-play URL: on the fallback paths (the offline
  /// sentinel, and this self-heal) the id used for playback comes from this
  /// response rather than from the route regardless, so a stale cached
  /// response there would feed a dead file straight into playback either way.
  ///
  /// `cacheAndNetwork` is not the fix: on a one-shot `client.query()` it
  /// returns the cached result and discards the network one, which is the same
  /// defect `core/graphql/watch/query_watcher.dart` documents. Nothing is lost
  /// by going to the network here — the offline branch returns long before this
  /// runs, and every remaining path needs the server to serve a single byte.
  ///
  /// `serverRejected` distinguishes *why* a call failed, so the caller can
  /// decide whether it is safe to retry against a different id.
  /// `streaming_resolver.ex`'s `streaming_candidates/3` answers an unknown
  /// id with a GraphQL error (e.g. "file not found") rather than throwing —
  /// the server understood the request and gave a real answer, so
  /// `result.exception` carries non-empty `graphqlErrors` and a null
  /// `linkException`. A transport failure (unreachable server, timeout,
  /// socket error) looks the opposite: no `graphqlErrors`, a non-null
  /// `linkException`. Only the former means "this id doesn't exist"; the
  /// latter means "we don't know", and must not be treated the same way by
  /// callers that would otherwise retry with a different id.
  Future<
      ({
        Query$StreamingCandidates$streamingCandidates? candidates,
        bool serverRejected,
      })> _fetchStreamingCandidates(
    GraphQLClient graphqlClient,
    String contentType,
    String id,
  ) async {
    try {
      final result = await graphqlClient.query(
        QueryOptions(
          document: documentNodeQueryStreamingCandidates,
          variables: Variables$Query$StreamingCandidates(
            contentType: contentType,
            id: id,
          ).toJson(),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Failed to fetch candidates: ${result.exception}');
        final exception = result.exception;
        final serverRejected = exception != null &&
            exception.graphqlErrors.isNotEmpty &&
            exception.linkException == null;
        return (candidates: null, serverRejected: serverRejected);
      }

      final data = Query$StreamingCandidates.fromJson(result.data!);
      return (candidates: data.streamingCandidates, serverRejected: false);
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching streaming candidates: $e');
      return (candidates: null, serverRejected: false);
    }
  }

  /// Fetches the movie or episode detail document: saved progress, runtime,
  /// and the subtitle tracks extracted from its files.
  Future<void> _fetchDetail(GraphQLClient client, int gen) async {
    try {
      if (widget.mediaType == 'movie') {
        // Fetch movie progress
        final result = await client.query(
          QueryOptions(
            document: documentNodeQueryMovieDetail,
            variables: Variables$Query$MovieDetail(id: widget.mediaId).toJson(),
          ),
        );
        if (!_isCurrentLoad(gen)) return;

        if (result.data != null) {
          final movie = Query$MovieDetail.fromJson(result.data!).movie;
          _savedPositionSeconds = movie?.progress?.positionSeconds;
          _savedDurationSeconds = movie?.progress?.durationSeconds;
          _serverLastWatchedAt =
              DateTime.tryParse(movie?.progress?.lastWatchedAt ?? '');
          _runtimeMinutes = movie?.runtime;

          // Extract subtitle tracks from files
          _extractSubtitlesFromFiles(movie?.files);
        }
      } else if (widget.mediaType == 'episode') {
        // Fetch episode progress
        final result = await client.query(
          QueryOptions(
            document: documentNodeQueryEpisodeDetail,
            variables:
                Variables$Query$EpisodeDetail(id: widget.mediaId).toJson(),
          ),
        );
        if (!_isCurrentLoad(gen)) return;

        if (result.data != null) {
          final episode = Query$EpisodeDetail.fromJson(result.data!).episode;
          _savedPositionSeconds = episode?.progress?.positionSeconds;
          _savedDurationSeconds = episode?.progress?.durationSeconds;
          _serverLastWatchedAt =
              DateTime.tryParse(episode?.progress?.lastWatchedAt ?? '');
          _runtimeMinutes = episode?.runtime;

          // Extract subtitle tracks from files
          _extractSubtitlesFromFiles(episode?.files);
        }
      }
    } catch (e) {
      debugPrint('Error fetching progress: $e');
    }
  }

  /// Every pre-play query at once. All of them read only `widget.*`, and each
  /// was already failure-isolated; they used to run one after another.
  ///
  /// The subtitle preference stays chained after the detail: applying it
  /// reads the tracks `_extractSubtitlesFromFiles` builds from the detail.
  /// Season episodes no longer waits for the detail to succeed, so a failed
  /// detail now costs one extra query rather than skipping it.
  Future<void> _fetchProgressAndEpisodes(GraphQLClient client, int gen) {
    return runIsolated({
      'detail and subtitle preference': () async {
        await _fetchDetail(client, gen);
        await _fetchSubtitlePreference(client, gen);
      },
      if (widget.mediaType == 'episode' &&
          widget.showId != null &&
          widget.seasonNumber != null)
        'season episodes': () => _fetchSeasonEpisodes(client, gen),
      'segments': () => _fetchSegments(client, gen),
      'subtitle offsets': () => _loadSubtitleOffsets(client, gen),
    });
  }

  /// Loads stored subtitle offsets for this media file.
  ///
  /// `subtitleTrackSettings` is a standalone root query rather than a field
  /// on `SubtitleTrack` precisely so this can fail without taking playback
  /// down with it -- see the query's own doc comment. Every failure here,
  /// including one from a server too old to know the field at all, lands on
  /// the same answer: no offsets, [_subtitleOffsetsLoaded] stays false, and
  /// [_selectedSubtitleTrack]/mpv are never touched by this method.
  ///
  /// Resets both fields at the top, before the request: this runs again on
  /// every media file this screen loads (see [_fetchProgressAndEpisodes]),
  /// and a previous file's offsets or its "loaded" flag must never survive
  /// into a new one just because this fetch happened to fail for it.
  Future<void> _loadSubtitleOffsets(GraphQLClient client, int gen) async {
    if (mounted) {
      setState(() {
        _subtitleOffsets = {};
        _subtitleOffsetsLoaded = false;
      });
    }

    try {
      final result = await client.query(
        QueryOptions(
          document: documentNodeQuerySubtitleTrackSettings,
          variables: Variables$Query$SubtitleTrackSettings(
            mediaFileId: widget.fileId,
          ).toJson(),
          // `client.query` defaults to `FetchPolicy.cacheFirst` over a
          // persistent `HiveStore`. A viewer who has played this file before
          // would otherwise get whatever offset was cached last time, and
          // `_saveSubtitleDelay` sends that stale baseline plus the current
          // nudge -- silently overwriting a newer server offset with an
          // older one. See player_screen_subtitle_offsets_cache_test.dart.
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Subtitle offsets unavailable: ${result.exception}');
        return;
      }

      final data = result.data;
      if (data == null) {
        debugPrint('[PlayerScreen] No data returned for subtitle offsets');
        return;
      }

      final settings =
          Query$SubtitleTrackSettings.fromJson(data).subtitleTrackSettings;
      if (!_isCurrentLoad(gen)) return;

      setState(() {
        _subtitleOffsets = {
          for (final s in settings) s.trackRef: s.offsetMs,
        };
        _subtitleOffsetsLoaded = true;

        // Defensive, not expected to fire in the normal flow: this is
        // awaited inside [_fetchProgressAndEpisodes], which always
        // completes before any track is auto-selected or picked. If a
        // track were already selected by the time this resolves, its
        // baked offset -- assumed zero until now for anything not read
        // straight from the container -- needs to catch up to what the
        // server actually shifted into the body it already delivered.
        final current = _selectedSubtitleTrack;
        if (current != null && !isMpvNativeSubtitleTrackId(current.id)) {
          _bakedSubtitleOffsetMs = _subtitleOffsets[current.id] ?? 0;
        }
      });
      await _syncSubtitleDelay();
    } catch (e) {
      debugPrint('[PlayerScreen] Subtitle offsets unavailable: $e');
    }
  }

  /// Resets the live nudge and recomputes the baked offset for whichever
  /// track is now selected, then applies the result to mpv and the sheet's
  /// delay display.
  ///
  /// Called from every site that can change [_selectedSubtitleTrack] --
  /// both success paths of [_showSubtitleSelector], the auto-detected
  /// default track in [_onTracksChanged], and the remote-control
  /// `selectTrack` -- so a delay nudged for one track never leaks onto the
  /// next regardless of which of those paths picked it.
  ///
  /// [keepNudge] is for the restore after a source switch: the viewer did
  /// not change tracks, so a delay they nudged survives, while the baked
  /// offset is still recomputed for whichever track id the restore landed
  /// on (the server's copy of a stream and mpv's own differ there).
  Future<void> _onSubtitleTrackChanged({bool keepNudge = false}) async {
    final track = _selectedSubtitleTrack;
    if (!keepNudge) _subtitleNudgeMs = 0;
    _bakedSubtitleOffsetMs =
        bakedSubtitleOffsetMs(track: track, offsets: _subtitleOffsets);
    await _syncSubtitleDelay();
  }

  /// Applies [effectiveSubtitleDelayMs] to mpv for whichever track is
  /// currently selected, and refreshes [_subtitleDelayDisplay] alongside
  /// it -- the two must never drift apart, since the display is the only
  /// place the viewer can see the number this just sent to mpv.
  Future<void> _syncSubtitleDelay() async {
    final track = _selectedSubtitleTrack;
    final storedOffsetMs = _subtitleOffsets[track?.id] ?? 0;

    if (mounted) {
      _subtitleDelayDisplay.value = subtitleDelayDisplayMs(
        trackId: track?.id,
        offsetsLoaded: _subtitleOffsetsLoaded,
        storedOffsetMs: storedOffsetMs,
        nudgeMs: _subtitleNudgeMs,
      );
    }

    final player = _player;
    if (player == null) return;

    await applySubtitleDelay(
      player,
      effectiveSubtitleDelayMs(
        storedOffsetMs: storedOffsetMs,
        bakedOffsetMs: _bakedSubtitleOffsetMs,
        nudgeMs: _subtitleNudgeMs,
      ),
    );
  }

  /// Nudges the live subtitle delay by [deltaMs] and applies it immediately.
  /// Bound to the `z`/`shift+z` keys and the sheet's steppers.
  ///
  /// Gated on [_subtitleOffsetsLoaded]: with the offsets query never having
  /// succeeded, [_subtitleOffsets] cannot be trusted to hold the server's
  /// real baseline (see that field's dartdoc), so nudging would move mpv
  /// relative to an unknown starting point and a viewer would have no way
  /// to tell how far off zero they actually are. No-ops rather than
  /// nudging partially-informed.
  Future<void> _nudgeSubtitleDelay(int deltaMs) async {
    final track = _selectedSubtitleTrack;
    if (track == null || !_subtitleOffsetsLoaded) return;

    setState(() => _subtitleNudgeMs += deltaMs);
    final total = (_subtitleOffsets[track.id] ?? 0) + _subtitleNudgeMs;

    await _syncSubtitleDelay();

    // applySubtitleDelay is a genuine no-op on web -- there is no mpv
    // sub-delay to set, and the body a web viewer sees always comes
    // pre-baked from the SubtitleContent query. The nudge is still tracked
    // and still contributes to what Save persists, but the OSD must not
    // claim a visible change that has not happened yet.
    _showToast(
      subtitleDelayToastMessage(
        totalMs: total,
        appliesImmediately: !kIsWeb,
      ),
    );
  }

  /// Discards the live nudge, returning the delay to whatever is actually
  /// stored for this track (or zero, for a track the server has no
  /// correction for).
  Future<void> _resetSubtitleDelay() async {
    final track = _selectedSubtitleTrack;
    if (track == null || !_subtitleOffsetsLoaded) return;
    if (_subtitleNudgeMs == 0) return;

    setState(() => _subtitleNudgeMs = 0);
    await _syncSubtitleDelay();
  }

  /// Persists the current nudge, replacing whatever offset the server had
  /// stored for this track.
  ///
  /// `storedOffsetMs` (via [_subtitleOffsets]) absorbs the nudge and
  /// `nudgeMs` resets, which leaves [effectiveSubtitleDelayMs] at exactly
  /// the same value -- see that function's dartdoc. Nothing refetches,
  /// nothing flickers, and the displayed number does not jump.
  ///
  /// The sheet already hides its Save button for an mpv-native track (see
  /// [canSaveSubtitleDelay]), but this checks again rather than trusting
  /// that UI gate alone -- the same defensive posture every other guard in
  /// this method already takes.
  ///
  /// On web this only ever persists the offset and updates local state; it
  /// never evicts or refetches the `SubtitleContent` body already cached in
  /// [_mediaKitSubtitleTrackMap] for [track], so what the viewer sees does
  /// not actually change until the track loads again. See
  /// [subtitleDelaySavedMessage]'s dartdoc for why that gap is closed with
  /// an honest message rather than a reload.
  Future<void> _saveSubtitleDelay() async {
    final track = _selectedSubtitleTrack;
    if (track == null || !_subtitleOffsetsLoaded) return;
    if (!canSaveSubtitleDelay(track.id)) return;
    if (widget.fileId == 'offline') return;

    final graphqlClient = _graphqlClient;
    if (graphqlClient == null) return;

    final total = (_subtitleOffsets[track.id] ?? 0) + _subtitleNudgeMs;

    try {
      final result = await graphqlClient.mutate(
        MutationOptions(
          document: documentNodeMutationSetSubtitleOffset,
          variables: Variables$Mutation$SetSubtitleOffset(
            mediaFileId: widget.fileId,
            trackRef: track.id,
            offsetMs: total,
          ).toJson(),
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Could not save subtitle delay: ${result.exception}');
        _showToast('Could not save the subtitle delay', kind: ToastKind.error);
        return;
      }

      if (!mounted) return;

      // Safe regardless of what is selected now: this is keyed by
      // `track.id`, the specific track this save was for. Resetting the
      // live nudge is not -- that only belongs to whichever track is
      // *currently* selected, so it is skipped entirely if the viewer
      // picked a different track while this request was in flight. An
      // unconditional reset here would wipe out a nudge already in
      // progress for a track this save was never about.
      setState(
        () => _subtitleOffsets = {..._subtitleOffsets, track.id: total},
      );
      if (_selectedSubtitleTrack?.id == track.id) {
        setState(() => _subtitleNudgeMs = 0);
        await _syncSubtitleDelay();
      }

      // On web this save never touches the SubtitleContent body already
      // cached in _mediaKitSubtitleTrackMap for this track -- it still has
      // the old offset baked in, so nothing the viewer sees actually moves
      // yet. See subtitleDelaySavedMessage's dartdoc for why a refetch was
      // not built to close that gap.
      _showToast(
        subtitleDelaySavedMessage(appliesImmediately: !kIsWeb),
        kind: ToastKind.success,
      );
    } catch (e) {
      debugPrint('[PlayerScreen] Could not save subtitle delay: $e');
      _showToast('Could not save the subtitle delay', kind: ToastKind.error);
    }
  }

  /// Extract subtitle tracks from media files returned by GraphQL
  void _extractSubtitlesFromFiles(List<Fragment$MediaFileFragment?>? files) {
    if (files == null || files.isEmpty) return;

    // Find the file matching the current fileId. This always matches on
    // `widget.fileId`, never `playFileId`, so on the self-heal path in
    // [_initializePlayer] (server rejected the selected file and re-ranked
    // one instead) this is comparing against the id the server just
    // rejected. No file matches, so external subtitles are silently
    // dropped for that playback. Intentional for now — see
    // [_fetchStreamingCandidates] for the self-heal itself.
    for (final file in files) {
      if (file == null) continue;
      if (file.id == widget.fileId) {
        final subtitles = file.subtitles;
        if (subtitles != null) {
          _serverSubtitleTracks = subtitles
              .whereType<Fragment$MediaFileFragment$subtitles>()
              .map((sub) => app_models.SubtitleTrack.fromGraphQL(sub))
              .toList();
          _refreshSubtitleTracks();
          debugPrint('Extracted ${_serverSubtitleTracks.length} subtitle '
              'tracks from GraphQL');
        }
        break;
      }
    }
  }

  /// Drop the previous media's segments and re-arm the once-per-session skip
  /// guard, but only when the media actually changed.
  ///
  /// The comparison, not the clearing, is the load-bearing half. This runs on
  /// every [_initializePlayer] call, and a seek past the transcoded end
  /// restarts the whole session for the *same* file. Resetting unconditionally
  /// would let auto-skip fire a second time on a segment the viewer had
  /// deliberately seeked back into, which is precisely what the guard exists
  /// to prevent.
  ///
  /// The clearing half runs on every file switch: a reused State re-enters
  /// [_initializePlayer] through [_switchToFile].
  void _resetSegmentsIfMediaChanged() {
    final mediaKey = '${widget.mediaType}:${widget.mediaId}:${widget.fileId}';
    if (_skipTrackerMediaKey == mediaKey) return;

    _skipTrackerMediaKey = mediaKey;
    _segments = const [];
    _skipTracker.reset();
    _nextSeasonEpisodes = null;
    _nextSeasonResolved = false;
  }

  /// Fetch the skippable segments for the file now playing.
  ///
  /// This is a **separate query on purpose, and has to stay that way.** An
  /// unknown field is a document-level validation error in GraphQL, not a
  /// field-level one, so a server predating the segments schema rejects the
  /// whole query the selection appears in and returns no data at all. Folded
  /// back into `MediaFileFragment` as a tidy-up, that would cost the resume
  /// position and the external subtitle list on every episode and movie detail
  /// view. Here it costs exactly one thing, the skip button.
  ///
  /// That is the common path rather than an edge case: the player auto-updates
  /// from an app store while the operator upgrades the server by hand,
  /// sometimes months later, so "newer player, older server" is the norm.
  ///
  /// Every failure lands on the same answer, no segments. Detection is
  /// additive background work and must never surface as a playback error.
  Future<void> _fetchSegments(GraphQLClient client, int gen) async {
    final root = switch (widget.mediaType) {
      'movie' => 'movie',
      'episode' => 'episode',
      _ => null,
    };
    if (root == null) return;

    try {
      final result = await client.query(
        QueryOptions(
          document: root == 'movie'
              ? documentNodeQueryMovieSegments
              : documentNodeQueryEpisodeSegments,
          variables: root == 'movie'
              ? Variables$Query$MovieSegments(id: widget.mediaId).toJson()
              : Variables$Query$EpisodeSegments(id: widget.mediaId).toJson(),
        ),
      );
      if (!_isCurrentLoad(gen)) return;

      if (result.hasException) {
        debugPrint('[PlayerScreen] No segments available: ${result.exception}');
        return;
      }

      // Matched on `widget.fileId`, never `playFileId`, so on the self-heal
      // path in [_initializePlayer] (server rejected the selected file and
      // re-ranked one instead) this looks up segments for the id the server
      // just rejected and finds none. Skip markers are silently dropped for
      // that playback. Intentional for now — see [_fetchStreamingCandidates]
      // for the self-heal itself.
      _segments = MediaSegment.forFile(
        result.data,
        root: root,
        fileId: widget.fileId,
      );
      debugPrint('[PlayerScreen] ${_segments.length} skippable segment(s)');
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching segments: $e');
    }
  }

  /// Load the viewer's per-show subtitle choice for the file now playing.
  ///
  /// Its own document rather than a field on `MediaFileFragment`, for the
  /// reason `subtitle_preference.graphql` spells out: an unknown field fails
  /// the whole document, and inside the fragment that cost the resume
  /// position and the external subtitle list on every detail view against an
  /// older server.
  ///
  /// Every failure lands on the same answer, no preference. A remembered
  /// subtitle is additive and must never surface as a playback error.
  ///
  /// Applies the preference itself on success. The inline read this replaced
  /// was deliberately sequenced after `_refreshSubtitleTracks`, so it could
  /// not be consumed by a rebuild with no player behind it. Arriving later is
  /// safe, but it opens the opposite gap: if this lands after the last
  /// track-list revision, nothing else would trigger an apply.
  /// [_applySubtitlePreference] is idempotent past its own one-shot, so this
  /// costs nothing when a revision got there first.
  Future<void> _fetchSubtitlePreference(GraphQLClient client, int gen) async {
    final root = switch (widget.mediaType) {
      'movie' => 'movie',
      'episode' => 'episode',
      _ => null,
    };
    if (root == null) return;

    try {
      final result = await client.query(
        QueryOptions(
          document: root == 'movie'
              ? documentNodeQueryMovieSubtitlePreference
              : documentNodeQueryEpisodeSubtitlePreference,
          variables: root == 'movie'
              ? Variables$Query$MovieSubtitlePreference(id: widget.mediaId)
                  .toJson()
              : Variables$Query$EpisodeSubtitlePreference(id: widget.mediaId)
                  .toJson(),
          // Same reason as `_loadSubtitleOffsets`: `client.query` defaults to
          // `FetchPolicy.cacheFirst` over a persistent `HiveStore`, and a
          // viewer who has played this file before would otherwise get the
          // choice they had made last time rather than the current one.
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      if (result.hasException) {
        debugPrint('[PlayerScreen] Subtitle preference unavailable: '
            '${result.exception}');
        return;
      }

      final data = result.data;
      if (data == null) return;

      // Matched on `widget.fileId`, never `playFileId`, for the same reason
      // `_extractSubtitlesFromFiles` and `_fetchSegments` are: on the
      // self-heal path the server re-ranked a different file, and looking up
      // the id it just rejected finds nothing. The preference is silently
      // dropped for that playback.
      final preferred = preferredSubtitleJsonForFile(
        data,
        root: root,
        fileId: widget.fileId,
      );
      if (!_isCurrentLoad(gen)) return;

      _subtitlePreference = subtitlePreferenceFrom(
        mode: preferred?['mode'] as String?,
        language: preferred?['language'] as String?,
        forced: preferred?['forced'] as bool?,
        hearingImpaired: preferred?['hearingImpaired'] as bool?,
        trackTitle: preferred?['trackTitle'] as String?,
      );

      // The track list may already be complete and settled, in which case no
      // further revision is coming to trigger this.
      await _applySubtitlePreference();
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching subtitle preference: $e');
    }
  }

  /// Sample whatever media_kit knows right now.
  ///
  /// Covers anything mpv had already published before [watchTracks] went
  /// live; every later revision arrives through that subscription instead.
  /// Both paths land in [_onTracksChanged], so there is one code path that
  /// can change the track lists.
  void _detectTracks() {
    final player = _player;
    if (player == null) return;

    _onTracksChanged(player.state.tracks);
  }

  /// Point [_selectedAudioTrack] at whichever detected track media_kit is
  /// actually playing, so the selector opens on the real current choice.
  void _syncSelectedAudioTrack() {
    final player = _player;
    if (player == null) return;

    final currentMkAudio = player.state.track.audio;
    if (currentMkAudio == AudioTrack.auto() ||
        currentMkAudio == AudioTrack.no()) {
      return;
    }

    for (final appTrack in _audioTracks) {
      if (_mediaKitAudioTrackMap[appTrack.id]?.id == currentMkAudio.id) {
        _selectedAudioTrack = appTrack;
        return;
      }
    }
  }

  /// Point [_selectedSubtitleTrack] at whatever the player is actually
  /// showing after [_detectTracks] rebuilt the track list, and re-arm the
  /// selection state around it.
  ///
  /// [_detectTracks] runs once per [_initializePlayer], and that includes
  /// the restarts a seek past the transcoded end or a quality change
  /// triggers. Those hand back a *new* player with no subtitle applied and
  /// an empty [_mediaKitSubtitleTrackMap], while both selection fields
  /// still pointed at the previous player's choice. The sheet then showed
  /// a track checked with nothing on screen, and re-tapping it was
  /// swallowed by [shouldStartSubtitleSelection] as a no-op against the
  /// stale [_pendingSubtitleSelection] -- the viewer's subtitles were gone
  /// with no way to get them back short of picking a different track.
  ///
  /// Resolved from the player rather than blanked to null, because in
  /// direct play mpv may have auto-enabled a default or forced track of
  /// its own, and reporting "Off" over a track that is genuinely rendering
  /// is the same lie in the other direction. Streaming has no embedded
  /// tracks in the map at all, so it lands on null either way.
  ///
  /// Adopts what the player is showing, so that a revision that lands after a
  /// viewer pick reports the pick rather than wiping it.
  ///
  /// Leaves [_subtitleSelectionGeneration] alone. That counter is bumped only
  /// where a selection is genuinely superseded: [_applySubtitleSelection]
  /// (every new attempt) and [_switchSource] (when it carries an intent). A
  /// track-list revision is neither of those. media_kit revises its list
  /// several times per playback, and a bump here used to discard whatever
  /// selection happened to be in flight at that moment -- a tap whose fetch
  /// was still resolving, or a preference apply, which could only answer by
  /// spending one of its [_maxPreferenceApplyRetries]. The bump could not even
  /// preempt anything on its own: this runs inside a `setState` body, so a
  /// continuation it "cancelled" only observes the bumped value after that
  /// callback has returned anyway. Leaving the generation alone is also what
  /// makes an apply a revision merely re-adopted distinguishable from one that
  /// was genuinely discarded, which [_applySubtitlePreference]'s retry has to
  /// tell apart.
  ///
  /// Stands down while a source switch is in flight or its restore is still
  /// pending. media_kit's `open()` resets its record of the selection to
  /// `auto`, so a sync then would wipe the choice [_switchSource] is
  /// carrying, and it would overwrite a restore still fetching a subtitle
  /// body. [_restoreSubtitleIntent] sets both fields itself once the choice is
  /// back on screen.
  void _syncSelectedSubtitleTrack() {
    final player = _player;
    if (player == null) return;

    if (!shouldSyncSubtitleSelectionFromPlayer(
      switchInFlight: _switchingSource,
      intentPending: _subtitleIntentAcrossSwitch != null,
    )) {
      return;
    }

    final currentMkSubtitle = player.state.track.subtitle;
    app_models.SubtitleTrack? applied;

    if (currentMkSubtitle != SubtitleTrack.auto() &&
        currentMkSubtitle != SubtitleTrack.no()) {
      for (final appTrack in _subtitleTracks) {
        if (_mediaKitSubtitleTrackMap[appTrack.id]?.id ==
            currentMkSubtitle.id) {
          applied = appTrack;
          break;
        }
      }
    }

    _selectedSubtitleTrack = applied;
    // Adopting what mpv is already doing is not an attempt, so this reads as
    // idle when nothing is applied and the viewer has not chosen. The
    // generation is deliberately not touched; see the dartdoc above.
    _pendingSubtitleSelection = _appliedSubtitleTarget;
  }

  /// Adopt a track list media_kit published, whether sampled directly after
  /// `open()` by [_detectTracks] or delivered later by [watchTracks].
  void _onTracksChanged(Tracks tracks) {
    if (!mounted) return;

    final previousSubtitleId = _selectedSubtitleTrack?.id;

    setState(() {
      final audio = detectAudioTracks(tracks.audio);
      _audioTracks = audio.tracks;
      _mediaKitAudioTrackMap = audio.byId;
      _syncSelectedAudioTrack();

      _applySubtitleTracks(tracks.subtitle);
    });

    // Covers the case `_showSubtitleSelector` does not: mpv auto-enabling a
    // default or forced embedded track on its own in direct play, with no
    // viewer tap involved. `_applySubtitleTracks` only reaches
    // `_syncSelectedSubtitleTrack` past its own no-op guard, so most calls
    // here leave `_selectedSubtitleTrack` untouched and this comparison is
    // a no-op too -- it must be, or a benign track-list revision mid-stream
    // would silently wipe out a nudge the viewer already made.
    if (_selectedSubtitleTrack?.id != previousSubtitleId) {
      unawaited(_onSubtitleTrackChanged());
    }

    debugPrint('[PlayerScreen] Detected ${_audioTracks.length} audio tracks, '
        '${_subtitleTracks.length} subtitle tracks '
        '(directPlay=$_isDirectPlay)');
  }

  /// Rebuild [_subtitleTracks] from [_serverSubtitleTracks] and whatever
  /// media_kit has probed so far.
  ///
  /// Call inside a `setState`; this does not call one itself, so the audio
  /// and subtitle halves of [_onTracksChanged] share a single rebuild.
  ///
  /// Returns early from the *rebuild* when the derived list is unchanged,
  /// which is load-bearing rather than an optimisation: the rebuild rewrites
  /// [_selectedSubtitleTrack] through [_syncSelectedSubtitleTrack], and
  /// replaces the `mk_` half of [_mediaKitSubtitleTrackMap]. media_kit revises
  /// its track list more than once per playback and most of those revisions
  /// change nothing, so an unguarded rebuild would re-derive the selection
  /// against an unchanged list and drop the cached bodies of every track the
  /// viewer had already fetched. [_applySubtitlePreference] is deliberately
  /// left outside that guard; see its call site below.
  ///
  /// The comparison is by id, since `SubtitleTrack.operator ==` is
  /// id-based. That is the right granularity: the button's gate and every
  /// selection path key on id, so a revision that changes only a title
  /// genuinely does not need a rebuild.
  void _applySubtitleTracks(List<SubtitleTrack> mkTracks) {
    final mpvTracks = <app_models.SubtitleTrack>[];
    final mpvById = <String, SubtitleTrack>{};

    for (final mkTrack in mkTracks) {
      if (mkTrack == SubtitleTrack.auto() || mkTrack == SubtitleTrack.no()) {
        continue;
      }

      final appTrack = app_models.SubtitleTrack(
        id: 'mk_${mkTrack.id}',
        language: mkTrack.language ?? 'und',
        title: mkTrack.title,
        embedded: true,
      );
      mpvTracks.add(appTrack);
      mpvById[appTrack.id] = mkTrack;
    }

    final derived = resolveSubtitleTracks(
      serverTracks: _serverSubtitleTracks,
      mpvTracks: mpvTracks,
      isDirectPlay: _isDirectPlay,
      imageSidecars: !kIsWeb,
    );

    if (!listEquals(derived, _subtitleTracks)) {
      _subtitleTracks = derived;

      // Only the `mk_` half of this map is media_kit's to republish. The rest
      // is the lazily fetched `SubtitleTrack.data` bodies
      // [_resolveMediaKitSubtitleTrack] caches by server track id. Assigning
      // the whole map, as detection used to, would drop that cache and refetch
      // -- re-running a server-side ffmpeg extraction -- for every track the
      // viewer had already selected this session.
      _mediaKitSubtitleTrackMap
        ..removeWhere((id, _) => id.startsWith('mk_'))
        ..addAll(mpvById);

      _syncSelectedSubtitleTrack();
    }

    // Outside the rebuild above and after it, not inside: this runs on every
    // revision, including one that does not change the derived list. A
    // revision that changes nothing is still the moment media_kit may have
    // become live, and a direct-play file whose own track list is already
    // complete never produces a second changed one -- so gating this on the
    // comparison, as the rebuild is gated, is a preference that silently never
    // applies. [_applySubtitlePreference] is idempotent past its own flag.
    unawaited(_applySubtitlePreference());
  }

  /// Re-derive [_subtitleTracks] after the *server's* list changed, against
  /// whatever media_kit has already published.
  ///
  /// The counterpart to [_onTracksChanged]: that one runs when media_kit
  /// revises its side, this one when [_extractSubtitlesFromFiles] or a
  /// freshly downloaded sidecar revises the server's.
  void _refreshSubtitleTracks() {
    if (!mounted) return;

    final mkTracks = _player?.state.tracks.subtitle ?? const <SubtitleTrack>[];
    setState(() => _applySubtitleTracks(mkTracks));
  }

  Future<void> _fetchSeasonEpisodes(GraphQLClient client, int gen) async {
    _graphQLClient = client;
    if (widget.showId == null || widget.seasonNumber == null) return;

    try {
      final result = await client.query(
        QueryOptions(
          document: documentNodeQuerySeasonEpisodes,
          variables: Variables$Query$SeasonEpisodes(
            showId: widget.showId!,
            seasonNumber: widget.seasonNumber!,
          ).toJson(),
        ),
      );

      if (result.data != null) {
        final episodes =
            Query$SeasonEpisodes.fromJson(result.data!).seasonEpisodes;
        if (episodes != null && _isCurrentLoad(gen)) {
          setState(() {
            _seasonEpisodes = episodes
                .whereType<Query$SeasonEpisodes$seasonEpisodes>()
                .toList();
            _currentEpisodeIndex =
                _seasonEpisodes?.indexWhere((ep) => ep.id == widget.mediaId);
          });
          _publishNowPlaying();
        }
      }
    } catch (e) {
      debugPrint('Error fetching season episodes: $e');
    }
  }

  Future<void> _fetchNextSeason() async {
    if (_nextSeasonResolved) return;
    if (widget.showId == null || widget.seasonNumber == null) {
      _nextSeasonResolved = true;
      return;
    }
    _nextSeasonResolved = true;

    final client = _graphQLClient;
    if (client == null) return;

    try {
      final result = await client.query(
        QueryOptions(
          document: documentNodeQuerySeasonEpisodes,
          variables: Variables$Query$SeasonEpisodes(
            showId: widget.showId!,
            seasonNumber: widget.seasonNumber! + 1,
          ).toJson(),
        ),
      );

      if (result.data == null || !mounted) return;
      final episodes =
          Query$SeasonEpisodes.fromJson(result.data!).seasonEpisodes;
      if (episodes == null) return;
      _nextSeasonEpisodes =
          episodes.whereType<Query$SeasonEpisodes$seasonEpisodes>().toList();
    } catch (e) {
      // No offer is the right failure mode: this runs fired-and-forgotten off
      // a position tick, with no caller waiting on a result.
      debugPrint('[PlayerScreen] Could not fetch next season: $e');
    }
  }

  void _onPlaybackProgress() {
    final player = _player;
    if (player == null || !mounted) return;

    // Strictly greater, against a mark seeded with the resume offset, so that
    // neither a resume seek nor a position that simply stands still counts as
    // playback. See [_playbackAdvanced].
    final position = player.state.position;
    if (position > _furthestPosition) {
      _furthestPosition = position;
      _playbackAdvanced = true;
    }

    _maybeAutoSkipSegment(player);

    // Offer the next episode once real credits are known to have started;
    // only a file with no detected credits segment falls back to a fixed
    // window before the real end. See [shouldOfferUpNext].
    if (shouldOfferUpNext(
      segments: _segments,
      position: _timeline.toReal(player.state.position),
      duration: _timeline.resolveDuration(player.state.duration),
    )) {
      _maybeShowUpNext();
    }

    final isWatched = _progressService?.isWatched(player) == true;
    if (isWatched) {
      debugPrint('Content is considered watched (90% complete)');

      if (!_watchedInvalidationSent) {
        _watchedInvalidationSent = true;
        // Save the current position before invalidating: the server only
        // learns position/duration from a save (the periodic sync, or this
        // one), never a watched flag, so it derives "watched" the same way
        // the client does — from position. Invalidating first would refetch
        // pre-watched data and re-stamp the fetch log as freshly fetched
        // with the wrong value.
        _saveProgress().whenComplete(_invalidateAfterPlayback);
      }
    }
  }

  /// Surface a playback failure media_kit reported after the media opened.
  ///
  /// Only fatal-looking failures reach the UI: see [_playbackAdvanced] for why
  /// an error arriving mid-playback is logged and otherwise ignored.
  ///
  /// Clearing [_isLoading] matters as much as setting [_error]: a failure
  /// during `open` leaves the screen still loading, and `_buildBody` checks
  /// the loading state first, so an error set on its own would never be
  /// reached.
  ///
  /// A browser's autoplay refusal is routed to [_autoplayBlocked] instead of
  /// [_error], because it is the one message on this stream that does not mean
  /// the video failed. Checked after the [_playbackAdvanced] gate, not before:
  /// once playback is under way the ordinary transport controls are on screen
  /// and can start it again, and throwing a full-bleed overlay over a running
  /// video would be the worse answer.
  void _onPlaybackError(String message) {
    debugPrint('[PlayerScreen] Playback error: $message');
    if (!mounted) return;

    // A direct or copy source reports faults to the policy so it can fall
    // back. Only a fallback that fails reaches the error page.
    final policy = _policy;
    if (policy != null &&
        policy.source != SourceKind.transcode &&
        !policy.done) {
      debugPrint('[PlayerScreen] Deferring error to verification: $message');
      return;
    }

    if (_playbackAdvanced) {
      // Already playing, so this is something the stream can survive. Killing
      // the video over it would be the regression, not the fix.
      return;
    }

    if (kIsWeb && autoplayBlocked(message)) {
      setState(() {
        _autoplayBlocked = true;
        _isLoading = false;
        // These are two mutually exclusive views of one screen and
        // `_buildBody` reads `_error` first, so a stale one left set here
        // would draw the error page over a video that only wants a tap.
        // `_initializePlayer`'s catch can set it after `play()` has already
        // been called — a throw while wiring up progress tracking, say — and
        // the refusal then arrives behind it on the error stream. The refusal
        // is the newer and better news of the two: a stream broken badly
        // enough to fail never gets as far as being declined a start. If it
        // is broken anyway, the tap raises a fresh error and the error screen
        // comes straight back.
        _error = null;
      });
      _remoteTargetController.notifyChanged();
      return;
    }

    setState(() {
      _error = playbackErrorMessage(message);
      _isLoading = false;
    });
    _remoteTargetController.notifyChanged();
  }

  /// Start the playback the browser declined to start on its own.
  ///
  /// The [Player.play] call has to happen inside the tap handler itself. That
  /// is the entire point: the gesture is what the browser was missing, and
  /// awaiting anything first would spend it. For the same reason this does not
  /// re-run [_initializePlayer] the way the error screen's Retry does — the
  /// media is already open, and re-initialising would abandon a perfectly good
  /// HLS session and make the server transcode the opening of the file twice.
  void _playAfterAutoplayBlock() {
    final player = _player;
    if (player == null) return;

    unawaited(player.play());
    setState(() {
      _autoplayBlocked = false;
    });
  }

  /// Seek past a detected segment the viewer opted into skipping.
  ///
  /// Runs on every position tick, so the once-per-session bookkeeping lives
  /// inside [SegmentSkipTracker.takeAutoSkip] rather than here: a segment is
  /// consumed by the same call that reports it, and seeking back into one that
  /// has already been skipped does nothing.
  void _maybeAutoSkipSegment(Player player) =>
      _maybeAutoSkipAt(_timeline.toReal(player.state.position), seekToReal);

  /// The auto-skip decision itself, in real media coordinates.
  ///
  /// Shared by local playback and casting because only the two ends differ:
  /// where a position comes from, and what a seek means. The preference, the
  /// once-per-session tracker and the segment lookup are one rule, and a
  /// second copy of it is the thing that would drift.
  void _maybeAutoSkipAt(
    Duration position,
    Future<void> Function(Duration) seek,
  ) {
    if (!_autoSkipSegments || _segments.isEmpty) return;

    final target = _skipTracker.takeAutoSkip(_segments, position);
    if (target == null) return;

    debugPrint('[PlayerScreen] Auto-skipping to ${target.end}');
    unawaited(seek(target.end));
  }

  /// Seek the receiver, in the same real coordinates [seekToReal] takes.
  ///
  /// `CastSessionManager.seek` owns both the mapping onto receiver coordinates
  /// and the session restart for a target the running stream cannot reach, so
  /// nothing here needs to know which of the two a given skip requires.
  /// Skipping credits well past the start offset is squarely the second case.
  ///
  /// Never completes with an error, because neither caller can catch one. The
  /// button's `onSkip` is a void callback and auto-skip fires from a provider
  /// listener, so a rejected seek would escape into the zone as a crash rather
  /// than a failed skip. A receiver that has gone away is routine, and it
  /// already announces itself: the session goes stale, which withdraws this
  /// button and turns the placeholder to "Lost connection". Failing a skip
  /// loudly on top of that would be the second telling of one story.
  Future<void> _castSeekToReal(Duration target) async {
    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      await manager.seek(target);
    } catch (e) {
      debugPrint('[PlayerScreen] Cast skip to $target failed: $e');
    }
  }

  /// The segment covering [position], or null when playback is between them.
  MediaSegment? _segmentAt(Duration position) {
    for (final segment in _segments) {
      if (segment.containsPosition(position)) return segment;
    }
    return null;
  }

  /// Show the "Up Next" overlay if conditions are met.
  void _maybeShowUpNext() {
    // Don't show if already showing, cancelled, or not an episode
    if (_showUpNext || _autoPlayCancelled || widget.mediaType != 'episode') {
      return;
    }

    // Check if there's a next episode
    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return;
    }

    var target = resolveInSeasonNext(
      _upNextCandidates(_seasonEpisodes!),
      _currentEpisodeIndex!,
    );

    if (target == null) {
      if (!mayCrossIntoNextSeason(
        seasonNumber: widget.seasonNumber,
        currentIndex: _currentEpisodeIndex!,
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
      target = resolveSeasonPremiere(_upNextCandidates(nextSeason));
      if (target == null) return;
    }

    // Offline/local playback can only ever autoplay into a next episode
    // that is itself already on disk — the next one existing in the season
    // is not enough, since there may be no connection to stream or fetch it
    // when the countdown lands.
    if (_isDownloadedSource) {
      unawaited(_maybeShowUpNextForDownloadedNext(target));
      return;
    }

    _showUpNextOverlay(target);
  }

  /// The download-gated half of [_maybeShowUpNext].
  ///
  /// Re-checks [_showUpNext]/[_autoPlayCancelled] after the lookup: both can
  /// change while the (async) download-manager query is in flight, e.g. the
  /// viewer already dismissed a still-pending offer some other way.
  Future<void> _maybeShowUpNextForDownloadedNext(UpNextTarget target) async {
    final DownloadedMedia? downloaded;
    try {
      final manager = await ref.read(downloadManagerProvider.future);
      downloaded = manager.getDownloadedMediaById(target.episodeId);
    } catch (e) {
      // Simply not offering Up Next is the right failure mode here: this
      // runs fired-and-forgotten off a position tick, with no return value
      // and no caller waiting on it, so there is nothing to propagate an
      // error to.
      debugPrint('[PlayerScreen] Could not check next-episode download: $e');
      return;
    }

    if (!mounted || downloaded == null) return;
    if (_showUpNext || _autoPlayCancelled) return;

    _showUpNextOverlay(target);
  }

  void _showUpNextOverlay(UpNextTarget target) {
    _upNextCountdown?.dispose();
    final countdown = UpNextCountdown(
      onElapsed: bindUpNextCountdownElapsed(_playNextEpisode),
    );
    _upNextCountdown = countdown;

    if (!mounted) return;
    setState(() {
      _upNextTarget = target;
      _showUpNext = true;
    });

    // Playback being paused is its own hold, so a viewer who pauses during
    // the credits does not come back to a different episode. A live
    // subscription, not a one-shot check: a pause or resume that happens
    // while the prompt is already up must reach the countdown too.
    _upNextPlayingSub?.cancel();
    final player = _player;
    if (player != null) {
      if (!player.state.playing) countdown.hold(UpNextHold.paused);
      _upNextPlayingSub = player.stream.playing.listen((playing) {
        playing
            ? countdown.release(UpNextHold.paused)
            : countdown.hold(UpNextHold.paused);
      });
    }
    countdown.start();
  }

  /// Stops the up-next countdown and its play/pause listener.
  void _stopUpNextTimers() {
    _upNextCountdown?.cancel();
    _upNextPlayingSub?.cancel();
    _upNextPlayingSub = null;
  }

  /// Forgets the up-next prompt entirely, for a file that has not offered it.
  /// Pure; callers wrap it in `setState` when mounted.
  void _resetUpNext() {
    _stopUpNextTimers();
    _upNextCountdown?.dispose();
    _upNextCountdown = null;
    _upNextTarget = null;
    _showUpNext = false;
    _autoPlayCancelled = false;
  }

  /// Cancel the prompt and the countdown, for the rest of this file.
  void _cancelAutoPlay() {
    // Synchronous, before any setState: a dismiss that only lands next frame
    // can lose to a fire scheduled this one.
    _stopUpNextTimers();
    if (mounted) {
      setState(() {
        _showUpNext = false;
        _autoPlayCancelled = true;
      });
    }
  }

  /// Play the next episode immediately.
  ///
  /// [fromAutoCountdown] is true only when the up-next countdown elapsed on
  /// its own. Manual transport, keyboard, and remote actions pass false so
  /// a prior dismiss of auto-play does not block explicit navigation.
  void _playNextEpisode({bool fromAutoCountdown = false}) {
    _upNextCountdown?.cancel();
    _upNextPlayingSub?.cancel();
    _upNextPlayingSub = null;

    // Re-check after the countdown: `_cancelAutoPlay` may have run between
    // the fire being scheduled and this executing. Manual next is unaffected.
    if (shouldBlockAutoPlayNext(
      autoPlayCancelled: _autoPlayCancelled,
      fromAutoCountdown: fromAutoCountdown,
    )) {
      return;
    }

    final target = _upNextTarget;
    if (target != null) {
      _navigateToEpisode(
        target.episodeId,
        target.fileId,
        target.routeTitle,
        seasonNumber: target.seasonNumber,
      );
      return;
    }

    // Keyboard PageDown and the transport's next button reach this with no
    // prompt showing, so the in-season lookup still has to happen here.
    final episodes = _seasonEpisodes;
    final index = _currentEpisodeIndex;
    if (episodes == null || index == null) return;
    final resolved = resolveInSeasonNext(_upNextCandidates(episodes), index);
    if (resolved == null) return;
    _navigateToEpisode(
      resolved.episodeId,
      resolved.fileId,
      resolved.routeTitle,
      seasonNumber: resolved.seasonNumber,
    );
  }

  /// Play the previous episode immediately.
  void _playPreviousEpisode() {
    _upNextCountdown?.cancel();
    _upNextPlayingSub?.cancel();
    _upNextPlayingSub = null;

    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return;
    }

    final previousIndex = _currentEpisodeIndex! - 1;
    if (previousIndex < 0) {
      return;
    }

    final previousEpisode = _seasonEpisodes![previousIndex];
    final files = previousEpisode.files;
    if (files == null || files.isEmpty) {
      return;
    }

    final firstFile = files.first;
    if (firstFile == null) {
      return;
    }

    final title =
        'S${previousEpisode.seasonNumber}E${previousEpisode.episodeNumber}${previousEpisode.title != null ? ' - ${previousEpisode.title}' : ''}';
    _navigateToEpisode(
      previousEpisode.id,
      firstFile.id,
      title,
      seasonNumber: previousEpisode.seasonNumber,
    );
  }

  /// Adapts the generated season-episode rows to the shape the resolvers in
  /// `up_next_policy.dart` take. Keeping the resolvers off the GraphQL layer
  /// is what makes them unit testable without codegen having run.
  List<UpNextCandidate> _upNextCandidates(
    List<Query$SeasonEpisodes$seasonEpisodes> episodes,
  ) {
    return episodes
        .map(
          (episode) => UpNextCandidate(
            id: episode.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title ?? 'Episode ${episode.episodeNumber}',
            fileIds: (episode.files ??
                    const <Query$SeasonEpisodes$seasonEpisodes$files?>[])
                .whereType<Query$SeasonEpisodes$seasonEpisodes$files>()
                .map((file) => file.id)
                .toList(),
            thumbnailUrl: episode.thumbnailUrl,
          ),
        )
        .toList();
  }

  Future<void> _navigateToEpisode(
    String episodeId,
    String fileId,
    String title, {
    required int seasonNumber,
  }) async {
    // Save current progress before navigating
    await _saveProgress();

    if (!mounted) return;

    // `seasonNumber` is the *target's*, not `widget.seasonNumber`. Passing the
    // current screen's season would tell this same PlayerScreen, reloading
    // for the next file, it is in the season it just left, so its
    // `_fetchSeasonEpisodes` would load the wrong list, `_currentEpisodeIndex`
    // would resolve to -1, and up-next would be dead for that entire season.
    context.go(
      '/player/episode/$episodeId?fileId=$fileId&title=${Uri.encodeComponent(title)}&showId=${widget.showId}&seasonNumber=$seasonNumber',
    );
  }

  /// Saves the current position under this widget's own identity; see
  /// [_saveProgressFor].
  Future<void> _saveProgress() => _saveProgressFor(
        mediaType: widget.mediaType,
        mediaId: widget.mediaId,
      );

  /// Saves the current position against [mediaType]/[mediaId] rather than
  /// `widget`'s own, so a caller mid-switch can still credit the file being
  /// replaced instead of the one taking over `widget`. See [_switchToFile].
  Future<void> _saveProgressFor({
    required String mediaType,
    required String mediaId,
  }) async {
    final player = _player;
    if (player == null) return;

    // Downloaded media is the only source that writes locally: it is the only
    // one that can be played with no server in reach. Streaming playback
    // writes straight to the server, which is reachable by definition.
    final store = _progressStore;
    final progressService = _progressService;
    if (_isDownloadedSource && store != null) {
      final position = player.state.position;
      final duration = _totalDuration ?? player.state.duration;

      // With a server in reach, both writes happen together so the local
      // record can be marked synced only if the server actually took it.
      // Writing locally and saving to the server as two independent steps is
      // what left every downloaded-while-online record permanently unsynced,
      // queued behind a flush that would one day replay them over newer
      // server progress.
      if (progressService != null) {
        await saveDownloadedProgress(
          store: store,
          progressService: progressService,
          mediaId: mediaId,
          mediaType: mediaType,
          position: position,
          duration: duration,
          now: DateTime.now(),
        );
        return;
      }

      await recordLocalProgress(
        store: store,
        mediaId: mediaId,
        mediaType: mediaType,
        position: position,
        duration: duration,
        now: DateTime.now(),
      );
    }

    if (progressService == null) return;

    if (mediaType == 'movie') {
      await progressService.saveMovieProgress(player, mediaId);
    } else if (mediaType == 'episode') {
      await progressService.saveEpisodeProgress(player, mediaId);
    }
  }

  /// Seeks to a real media position, restarting the stream if necessary.
  ///
  /// On an HLS stream the playlist only covers what FFmpeg has transcoded so
  /// far, so a target well beyond it cannot be reached by seeking: media_kit
  /// clamps to the end of what it has and playback appears to snap back. When
  /// that happens the session is restarted at the target offset instead —
  /// but only past [kSeekRestartTolerance], since a restart is far more
  /// disruptive than the snap-back it avoids for a small skip.
  Future<void> seekToReal(Duration target) async {
    final player = _player;
    if (player == null) return;

    // A switch owns the current player, including while saving progress.
    // The next request can use the new source's real-coordinate timeline.
    if (_switchingSource) return;

    final clamped = target.isNegative ? Duration.zero : target;

    // A viewer who scrubs back into the episode is plainly not finished with
    // it. Free to read here, since every seek already routes through this.
    if (_showUpNext) {
      final current = _timeline.toReal(player.state.position);
      if (clamped < current) _cancelAutoPlay();
    }

    final local = _timeline.toPlayer(clamped);

    // `player.state.duration` is deliberately the RAW player duration here, not
    // a timeline lookup. Everywhere else that value is the bug; here it is
    // exactly the question being asked, namely how much of the stream can
    // actually be seeked into right now.
    final seekableEnd = player.state.duration;

    if (shouldRestartForSeek(
      isDirectPlay: _isDirectPlay,
      fullPlaylist: _fullPlaylist,
      realTarget: clamped,
      localTarget: local,
      seekableEnd: seekableEnd,
      startOffset: _timeline.startOffset,
    )) {
      // A WINDOW playlist needs a fresh session for an out-of-range seek.
      final plan = _plan;
      if (plan == null) return;
      try {
        await _switchSource(plan, at: clamped);
      } catch (e) {
        debugPrint('[PlayerScreen] Seek restart failed: $e');
      }
      return;
    }

    // Within [kSeekRestartTolerance] of the transcoded end, land on the end
    // rather than past it. media_kit would clamp an out-of-range target
    // anyway; doing it here keeps the small-overshoot case explicit and
    // costs nothing when the target is already in range. Skipped when the
    // player has no duration yet (a stream that has not reported one), where
    // clamping would turn every forward skip into a seek to zero.
    final seekTarget = seekableEnd > Duration.zero && local > seekableEnd
        ? seekableEnd
        : local;

    // mpv rebuffers after a seek, which is no evidence about the link.
    _monitor?.noteInterruption();
    await player.seek(seekTarget);
    // MPRIS clients extrapolate position; a jump needs announcing.
    _remoteTargetController.notifyChanged();
  }

  /// Switches the audio track, noting the switch with the monitor first.
  ///
  /// mpv rebuffers after a track switch, which is no evidence about the link.
  /// Noting it before the call, as [seekToReal] does for seeks, puts the
  /// switch on record ahead of the stall it causes, however late media_kit's
  /// own `stream.track` event arrives.
  Future<void> _setAudioTrack(Player player, AudioTrack track) {
    _monitor?.noteInterruption();
    return player.setAudioTrack(track);
  }

  /// Switches the subtitle track, noting the switch first; see
  /// [_setAudioTrack].
  ///
  /// Goes through [_switchGate], so it never reaches a player a switch is
  /// replacing, and returns whether it ran: false when the selection issued
  /// under [generation] was superseded while it waited (see
  /// [_canApplySubtitleSelection]). Reads `_player` only once let through,
  /// since a web switch replaces the player.
  Future<bool> _setSubtitleTrack(int generation, SubtitleTrack track) =>
      _switchGate.pass(() => _canApplySubtitleSelection(generation), () {
        final player = _player;
        if (player == null) return Future<void>.value();
        _monitor?.noteInterruption();
        return player.setSubtitleTrack(track);
      });

  /// Hands the browser the cues of whatever was just applied, or stops it
  /// drawing when subtitles went off.
  ///
  /// Only ever called where a selection has actually taken effect on the
  /// player, so it reads `_player` directly rather than going through
  /// [_switchGate]: the gate has already let that call through, and a switch
  /// arriving now replaces the element this would have touched anyway. A
  /// no-op on native and whenever the player has gone.
  void _showSubtitleCues({required bool enabled}) {
    final player = _player;
    if (player == null) return;
    showSubtitleCues(player, enabled: enabled);
  }

  /// Refreshes everything that reflects watched state. Deliberately not called
  /// from the 10-second progress sync: that would refetch Home hundreds of
  /// times per movie over what may be a p2p relay.
  void _invalidateAfterPlayback() {
    _invalidator.invalidate(
      InvalidationRules.playbackFinished(
        mediaType: widget.mediaType,
        mediaId: widget.mediaId,
        showId: widget.showId,
      ),
    );
  }

  /// Runs only when the screen really goes away (`dispose`, tab close). A
  /// file switch on a reused State ends its session through [_switchToFile]
  /// and keeps the proxy hold, since `this` still needs it. On a real route
  /// replacement the incoming screen has already started the proxy (Flutter
  /// mounts the new route before disposing the old one), so an unconditional
  /// stop here would close the server it streams from.
  ///
  /// Reads only the fields captured in [initState] ([_mediaProxy],
  /// [_graphqlClient]) — never `ref` directly. This
  /// runs from `dispose()` (as well as the web beforeunload handler), and
  /// `ref.read`/`ref.watch` unconditionally throw once `dispose()` has
  /// started: `BuildContext.mounted` is already `false` throughout it, a
  /// core Flutter invariant. Before this, every call from `dispose()` threw
  /// on its very first line, before doing any of the cleanup below.
  Future<void> _terminateHlsSession() async {
    // Releases this screen's hold rather than stopping the proxy outright.
    // On a next-episode navigation the incoming screen has already started
    // it — Flutter mounts the new route before disposing the old one — so an
    // unconditional stop here closed the server the episode now playing was
    // streaming from.
    //
    // Deliberately unconditional. This used to run only while the connection
    // was still in p2p mode, which tracked the *current* mode rather than the
    // one this screen took the proxy under — and a reconnect can move a
    // viewer between the two mid-episode. Skipping the release then stranded
    // the hold for good: it is keyed on a State that is about to stop
    // existing, so nothing could ever let go of it and the proxy stayed up
    // for the rest of the session. Releasing a hold that was never taken is
    // a no-op, so there is nothing to guard against.
    try {
      await _mediaProxy.stop(this);
      debugPrint('[PlayerScreen] Media proxy released');
    } catch (e) {
      debugPrint('[PlayerScreen] Error stopping local proxy: $e');
    }

    // The controller resolves the client through the same captured field
    // `ref.listenManual` keeps fresh, so this is safe from dispose().
    await _playback?.endSession();
  }

  // Note: Subtitle tracks are now loaded via GraphQL in _fetchProgressAndEpisodes
  // The _loadSubtitleTracks method has been removed.

  /// Shows the subtitle sheet and applies whatever the viewer picked.
  ///
  /// The apply itself is [_applySubtitleSelection], shared with the remote
  /// `selectTrack` and the restore after a source switch. What stays here
  /// is specific to a tap on the sheet: a dismissal changes nothing, and
  /// re-picking what is already pending is a no-op (see
  /// [shouldStartSubtitleSelection]).
  Future<void> _showSubtitleSelector() async {
    // Same as the quality picker: a switch in flight carries the current
    // choice across itself, and a pick now would apply to the file it is
    // about to replace.
    if (!shouldAcceptSubtitlePick(switchInFlight: _switchingSource)) return;

    final outcome = await showSubtitleTrackSelector(
      context,
      _subtitleTracks,
      _selectedSubtitleTrack,
      onSearch: _searchSubtitles,
      onDownload: _downloadSubtitle,
      subtitleDelayMs: _subtitleDelayDisplay,
      canSaveDelay: canSaveSubtitleDelay(_selectedSubtitleTrack?.id),
      onNudgeSubtitleDelay: _nudgeSubtitleDelay,
      onResetSubtitleDelay: _resetSubtitleDelay,
      onSaveSubtitleDelay: _saveSubtitleDelay,
    );

    // A dismissed sheet (barrier tap, back gesture) must leave every
    // subtitle field alone. Before [SubtitleTrackSelection] existed, the
    // sheet returned a bare `SubtitleTrack?` and a dismissal was
    // indistinguishable from choosing "Off" -- with a pick already in
    // flight, that silently cancelled it. See that sealed class for the
    // full account.
    if (outcome is SubtitleTrackSelectionCancelled) return;

    final selected = outcome is SubtitleTrackPicked ? outcome.track : null;
    final requested =
        selected == null ? const TargetOff() : TargetTrack(selected);

    if (!shouldStartSubtitleSelection(
      requested: requested,
      pending: _pendingSubtitleSelection,
      mounted: mounted,
    )) {
      return;
    }
    // Rechecked: a fallback can start while the sheet is open.
    if (!shouldAcceptSubtitlePick(switchInFlight: _switchingSource)) return;

    _subtitleChosenThisPlayback = true;
    _subtitleIntentAcrossSwitch = null;
    final generation = await _applySubtitleSelection(selected);
    // After the apply, not before: a pick that fails to load should not be
    // remembered as the show's preference. The generation the apply ran
    // under goes with it: a pick a later one superseded is not a choice
    // worth storing, and its write is dropped rather than sent.
    unawaited(_rememberSubtitlePreference(selected, generation: generation));
  }

  /// Applies [selected] (null for "Off") to the player, and returns the
  /// selection generation it ran under.
  ///
  /// Deliberately does not set [_selectedSubtitleTrack] until the choice has
  /// actually taken effect on the player. An earlier version committed it
  /// eagerly, before the (now-async, network-bound) work that applies it;
  /// on a failed fetch that left the sheet's checkmark pointing at a track
  /// that was not actually playing, and -- because the sheet's no-op guard
  /// used to compare against [_selectedSubtitleTrack] -- permanently wedged
  /// that track until the viewer picked something else. Committing only on
  /// success means a retry is just picking the same track again.
  ///
  /// Every point where this resumes from an `await` calls
  /// [_canApplySubtitleSelection] before doing anything further -- touching
  /// `_player`, calling `setState` -- rather than each checking its own
  /// subset of "is this still current". An earlier revision did the latter:
  /// the check after the content fetch verified generation and `mounted`
  /// but not the player, the check after the "Off" call verified generation
  /// and `mounted` too, and the final `setState` after actually applying a
  /// resolved track had no check at all -- surfacing as `setState` after
  /// `dispose()`, or media_kit's `AssertionError` on a disposed `Player`,
  /// if the viewer navigated away during that specific `await`.
  /// [shouldApplySubtitleSelection] and its tests are what replaced
  /// re-deriving this by hand at each site.
  ///
  /// Every one of those same exits, when it isn't a successful apply, also
  /// calls [_resetPendingSubtitleSelection]. [_pendingSubtitleSelection] is
  /// written once, up front, to whatever this call is requesting -- and a
  /// version that only ever wrote it and never reverted it left a failed
  /// attempt's target stuck there forever, so re-tapping the very track a
  /// "could not load" toast had just told the viewer to retry was
  /// silently swallowed by the sheet's no-op guard. See
  /// [pendingSubtitleSelectionAfterFailure]. Those calls are backstopped by
  /// a `finally` around the whole body, which is what also covers the two
  /// `setSubtitleTrack` awaits -- they can *throw* rather than return, and
  /// not every caller awaits this; see the comment on the `try` below.
  ///
  /// [keepNudge] passes through to [_onSubtitleTrackChanged]; only the
  /// restore after a source switch sets it.
  ///
  /// The returned generation equals [_subtitleSelectionGeneration] afterwards
  /// exactly when nothing superseded this call, which is how
  /// [_restoreSubtitleIntent] tells a finished restore from a cancelled one.
  Future<int> _applySubtitleSelection(
    app_models.SubtitleTrack? selected, {
    bool keepNudge = false,
  }) async {
    // Recorded before anything else below, including the no-player bailout
    // right after: this is what makes a tap whose target matches an
    // in-flight request's own target (a retry, or a cancel back to
    // whatever's still displayed as current) register as a real tap
    // instead of silently matching stale state. See
    // [_pendingSubtitleSelection]'s dartdoc for why the sheet's comparison
    // uses this field and not [_selectedSubtitleTrack].
    _pendingSubtitleSelection =
        selected == null ? const TargetOff() : TargetTrack(selected);

    // See [_subtitleSelectionGeneration]'s dartdoc for why this is bumped
    // unconditionally, before the no-player bailout below, rather than
    // after it.
    final generation = ++_subtitleSelectionGeneration;

    // Everything past this point runs under a `finally` that resets the
    // pending target, because two of the exits below are not `return`s.
    // Both `setSubtitleTrack` calls can *throw*: media_kit 1.2.6 raises
    // `AssertionError('[Player] has been disposed')` from both its native
    // and web backends when the player is disposed during the await, which
    // is exactly what the viewer leaving playback mid-selection does. The
    // sheet's tap and the restore after a switch are fire-and-forget, so
    // such a throw escapes into a future nothing awaits and every explicit
    // reset below is skipped -- leaving [_pendingSubtitleSelection] pointed
    // at a track that was never applied (so re-tapping it is swallowed by
    // the sheet's no-op guard), or pointed at `null` while a track is still
    // applied (so re-tapping "Off" is swallowed). The `finally` covers the
    // six `return`s and both throw sites together, so "which exits reset"
    // stops being a list a later change can get wrong.
    //
    // It is a no-op on both success paths. After the content path's
    // `setState`, [_selectedSubtitleTrack] is `selected` and the request is
    // still the current generation (nothing else could have written the
    // pending target without bumping it), so the reset recomputes
    // `pending = applied = selected` -- the value already there. After the
    // "Off" path's `setState` both are `null`. The reset is idempotent
    // besides, recomputing the same value from the same inputs, so running
    // it a second time on an exit that already called it changes nothing.
    try {
      if (_player == null) {
        _resetPendingSubtitleSelection(generation);
        return generation;
      }

      if (selected == null) {
        // "Off" - disable subtitles. Nothing was sent when this was
        // superseded while waiting at the gate for a switch.
        if (!await _setSubtitleTrack(generation, SubtitleTrack.no()) ||
            !_canApplySubtitleSelection(generation)) {
          _resetPendingSubtitleSelection(generation);
          return generation;
        }
        setState(() => _selectedSubtitleTrack = null);
        _showSubtitleCues(enabled: false);
        await _onSubtitleTrackChanged(keepNudge: keepNudge);
        debugPrint('[PlayerScreen] Subtitles turned off');
        return generation;
      }

      // Feedback while the extraction runs server-side: closing the sheet
      // and showing nothing further while that fetch is in flight is
      // exactly what let a viewer re-tap and reach the concurrency guard
      // [_canApplySubtitleSelection] exists to enforce. Shown for every
      // pick, existing or freshly downloaded -- both reach this same fetch.
      //
      // Checked directly in front of the `context` use below: not every
      // caller checked `mounted` before calling in, and
      // `use_build_context_synchronously` needs to see the check here
      // rather than trust a helper it cannot look inside. Routed through
      // the same reset as every other exit rather than a bare `return`.
      if (!mounted) {
        _resetPendingSubtitleSelection(generation);
        return generation;
      }
      // The handle this specific call gets back is closed by itself below,
      // never "whatever toast is current" after the await. A second pick (B)
      // started while this one (A) is still in flight passes
      // `shouldStartSubtitleSelection` (different target) and shows its own
      // indicator, replacing A's. When A's fetch then resolves, closing A's
      // handle is a no-op, so B's indicator stays up while B is still
      // running. Closing the current toast instead would leave the viewer
      // mid-fetch with nothing on screen -- precisely the blank-screen
      // condition that invites the re-tap `_canApplySubtitleSelection`
      // exists to guard against.
      // A bitmap track's first pick waits on the server copying it out of
      // the whole source, which can take minutes, so its indicator says so
      // and stays up for as long as the fetch may take.
      //
      // Only when there is something to wait for. An mpv track, or a body
      // this playback already fetched, resolves from
      // [_mediaKitSubtitleTrackMap] with no network at all, and a toast for
      // it would sit over a subtitle that is already showing.
      final preparingImage = !_isDirectPlay && isImageSubtitleTrack(selected);
      final loadingToast = _mediaKitSubtitleTrackMap.containsKey(selected.id)
          ? null
          : Toaster.of(context).show(
              preparingImage
                  ? kImageSubtitlePreparingMessage
                  : 'Loading subtitle...',
              kind: ToastKind.progress,
              duration: preparingImage ? kImageSidecarTimeLimit : null,
            );

      final resolved = await _resolveMediaKitSubtitleTrack(
        selected,
        generation: generation,
      );
      final mkTrack = resolved.track;
      // Unconditional: `ToastHandle.close` does not use this screen's
      // context (the layer lives above the route). Gating on `mounted` was
      // leftover from `SnackBar.close` and left the indicator up after the
      // viewer left playback, until the 30s timeout. A no-op if this toast
      // was already dismissed (its own timeout, or a later pick replacing
      // it).
      loadingToast?.close();

      // Superseded while the fetch was in flight (a re-tap, "Off", or the
      // screen/player went away): drop this result silently rather than
      // reporting a failure — or applying a success — for a choice the
      // viewer has already moved past.
      if (!_canApplySubtitleSelection(generation)) {
        _resetPendingSubtitleSelection(generation);
        return generation;
      }

      if (mkTrack == null) {
        debugPrint(
            '[PlayerScreen] No media_kit track found for: ${selected.id}');
        // The ordinary failure path — a dropped connection, a server error,
        // an empty extraction — and it must leave a retry possible: reset
        // the pending target back to whatever's actually applied so a
        // second tap on this same track starts a fresh attempt instead of
        // matching this one's own, now-abandoned target.
        _resetPendingSubtitleSelection(generation);
        // `_canApplySubtitleSelection` above already confirmed `mounted`,
        // but that check is behind a helper the analyzer can't see through,
        // so it cannot itself prove `context` is safe to use here. This
        // repeats the same check directly so it can.
        if (!mounted) return generation;
        showToast(context, resolved.failureMessage, kind: ToastKind.error);
        return generation;
      }

      // `_setSubtitleTrack` reads `_player` itself once the gate lets it
      // through: `_restartLocalPlayback` and a web source switch replace it
      // while a fetch can still be in flight. Nothing was sent when this
      // was superseded while waiting for a switch.
      //
      // Re-checked after the set as well: dispose() or
      // _restartLocalPlayback landing during *this specific* call is exactly
      // as possible as during the fetch above, and `setState` after unmount
      // throws just as surely as calling into a disposed `Player` does.
      if (!await _setSubtitleTrack(generation, mkTrack) ||
          !_canApplySubtitleSelection(generation)) {
        _resetPendingSubtitleSelection(generation);
        return generation;
      }
      setState(() => _selectedSubtitleTrack = selected);
      _showSubtitleCues(enabled: true);
      await _onSubtitleTrackChanged(keepNudge: keepNudge);
      debugPrint('[PlayerScreen] Set subtitle track: ${selected.displayName}');
    } finally {
      _resetPendingSubtitleSelection(generation);
    }
    return generation;
  }

  /// Search every subtitle provider the server has enabled for subtitles
  /// matching this file, in [languages].
  ///
  /// Never throws. The sheet renders [SubtitleSearchOutcome.error] inline,
  /// above the (empty) result list and below the language chips that
  /// produced it, so adjusting a language and retrying stays one tap away.
  /// Throwing instead would drop the viewer onto the sheet's generic
  /// "search failed" copy and lose the server's own reason, which is
  /// usually the actionable half ("this file has no hash or metadata IDs
  /// to search with" is not a retry).
  Future<SubtitleSearchOutcome> _searchSubtitles(
    List<String> languages,
  ) async {
    // The `'offline'` sentinel means this is a downloaded file playing with
    // no server file id behind it, so there is nothing to search *for*.
    // Caught here rather than left to the server, which would answer a
    // flat "media file not found" for what is really "you are offline".
    if (widget.fileId == 'offline') {
      return const SubtitleSearchOutcome(
        results: [],
        providers: [],
        error: 'Subtitle search needs a connection to your server.',
      );
    }

    try {
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);
      final result = await graphqlClient.query(
        QueryOptions(
          document: documentNodeQuerySubtitleSearch,
          variables: Variables$Query$SubtitleSearch(
            mediaFileId: widget.fileId,
            languages: languages,
          ).toJson(),
          // Never cached: each result carries a token the server signed for
          // a fifteen minute window, so a cache hit would hand back
          // candidates whose download is already guaranteed to fail.
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Subtitle search failed: ${result.exception}');
        return SubtitleSearchOutcome(
          results: const [],
          providers: const [],
          error: _friendlyGraphQLError(
            result.exception,
            'Could not reach the server. Try again.',
          ),
        );
      }

      // Same reasoning as [_resolveMediaKitSubtitleTrack]'s null check:
      // `data` is only ever null alongside `hasException` in this client,
      // but papering over it with `?? const {}` would defer the failure
      // one line into the generated `fromJson`'s non-nullable cast.
      final data = result.data;
      if (data == null) {
        debugPrint('[PlayerScreen] Subtitle search returned no data');
        return const SubtitleSearchOutcome(
          results: [],
          providers: [],
          error: 'The server returned no results. Try again.',
        );
      }

      final payload = Query$SubtitleSearch.fromJson(data).subtitleSearch;
      return SubtitleSearchOutcome(
        results: payload.results.map(SubtitleCandidate.fromGraphQL).toList(),
        providers:
            payload.providers.map(SubtitleProviderStatus.fromGraphQL).toList(),
      );
    } catch (e) {
      debugPrint('[PlayerScreen] Error searching subtitles: $e');
      return const SubtitleSearchOutcome(
        results: [],
        providers: [],
        error: 'Subtitle search failed. Try again.',
      );
    }
  }

  /// Download [candidate] into this file's library entry and return the
  /// track the server created for it.
  ///
  /// Throws on failure, which is what the sheet's contract asks for: it
  /// stays open on the results list so the viewer can pick a different
  /// release. A [SubtitleActionException] is shown verbatim, which is what
  /// carries the server's "search again" through on an expired token --
  /// the generic copy would invite re-tapping the same stale token forever.
  ///
  /// The returned track has no `content`: the body is fetched lazily by
  /// [_resolveMediaKitSubtitleTrack] when the selection is applied, the
  /// same path every other sidecar takes.
  Future<app_models.SubtitleTrack> _downloadSubtitle(
    SubtitleCandidate candidate,
  ) async {
    if (widget.fileId == 'offline') {
      throw const SubtitleActionException(
        'Downloading subtitles needs a connection to your server.',
      );
    }

    final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);
    final result = await graphqlClient.mutate(
      MutationOptions(
        document: documentNodeMutationDownloadSubtitle,
        variables: Variables$Mutation$DownloadSubtitle(
          mediaFileId: widget.fileId,
          token: candidate.token,
        ).toJson(),
      ),
    );

    if (result.hasException) {
      debugPrint(
          '[PlayerScreen] Subtitle download failed: ${result.exception}');
      throw SubtitleActionException(
        _friendlyGraphQLError(
          result.exception,
          'Could not download that subtitle. Try again.',
        ),
      );
    }

    final data = result.data;
    if (data == null) {
      throw const SubtitleActionException(
        'The subtitle downloaded but the server returned nothing.',
      );
    }

    final track = app_models.SubtitleTrack.fromDownload(
      Mutation$DownloadSubtitle.fromJson(data).downloadSubtitle,
    );

    // Added to the server list so it survives the sheet closing: the pick
    // that follows is applied against `_subtitleTracks`, and the controls'
    // track count and the next open of the sheet both read from it.
    // Guarded on identity because the server returns the existing row when
    // the same subtitle is downloaded twice, and a duplicate entry would
    // render the track twice in the list.
    //
    // Written to `_serverSubtitleTracks` rather than `_subtitleTracks`
    // because the latter is derived: a later media_kit revision rebuilds it
    // from this list, so an append made directly to the derived list would
    // vanish at the next revision. A downloaded sidecar is `embedded:
    // false, deliverable: true`, so every branch of `resolveSubtitleTracks`
    // keeps it.
    if (mounted && !_serverSubtitleTracks.any((t) => t.id == track.id)) {
      _serverSubtitleTracks = [..._serverSubtitleTracks, track];
      _refreshSubtitleTracks();
    }

    return track;
  }

  /// The line to show a viewer for a failed GraphQL operation.
  ///
  /// A resolver's own message is written for one -- "These search results
  /// expired. Search again.", "This file has no hash or metadata IDs to
  /// search with" -- and is the only part of the failure worth reading. A
  /// transport failure carries no such message, only a `linkException`
  /// whose `toString` is a socket dump, so those fall back to [fallback].
  String _friendlyGraphQLError(OperationException? exception, String fallback) {
    final message = exception?.graphqlErrors.firstOrNull?.message;
    if (message != null && message.isNotEmpty) return message;
    return fallback;
  }

  /// [_pendingSubtitleSelection]'s value for "no attempt is in flight, and
  /// here is what is actually on the player".
  ///
  /// The null case is the one that matters. Nothing applied is
  /// [TargetOff] only when the viewer put it there; otherwise no attempt has
  /// ever concluded and the tracker must read as idle, or the first Off tap
  /// of a playback compares equal to it and is swallowed. That distinction is
  /// exactly what [_subtitleChosenThisPlayback] exists to carry: see its own
  /// dartdoc, which names the same two states this getter separates.
  SubtitleSelectionTarget? get _appliedSubtitleTarget {
    final applied = _selectedSubtitleTrack;
    if (applied != null) return TargetTrack(applied);
    return _subtitleChosenThisPlayback ? const TargetOff() : null;
  }

  /// Whether a subtitle selection issued under [generation] is still the
  /// live one and safe to apply, right now.
  ///
  /// A thin adapter over the pure [shouldApplySubtitleSelection], reading
  /// this state's current values — see that function for what each input
  /// guards against and why the check has to be all of them together, not
  /// a subset re-derived per call site.
  bool _canApplySubtitleSelection(int generation) {
    return shouldApplySubtitleSelection(
      requestGeneration: generation,
      currentGeneration: _subtitleSelectionGeneration,
      mounted: mounted,
      hasPlayer: _player != null,
    );
  }

  /// Falls [_pendingSubtitleSelection] back to whatever is actually
  /// applied — unless a newer selection has since been requested, in which
  /// case that newer request already owns the pending value and this must
  /// not touch it.
  ///
  /// Called from a `finally` covering [_showSubtitleSelector]'s body, so it
  /// runs on every exit past the point [_pendingSubtitleSelection] was
  /// written, including the throwing ones and the two successful applies.
  /// On a successful apply it is a no-op: the apply has just made
  /// [_selectedSubtitleTrack] equal to the pending target, so this
  /// recomputes the value already there. It is idempotent for the same
  /// reason — same inputs, same result — so the explicit calls that remain
  /// at the individual failure exits are harmless alongside it.
  ///
  /// A thin adapter over the pure [pendingSubtitleSelectionAfterFailure];
  /// see that function's dartdoc for why leaving this unset was the
  /// regression a second review round caught.
  void _resetPendingSubtitleSelection(int generation) {
    _pendingSubtitleSelection = pendingSubtitleSelectionAfterFailure(
      requestGeneration: generation,
      currentGeneration: _subtitleSelectionGeneration,
      currentPending: _pendingSubtitleSelection,
      appliedTarget: _appliedSubtitleTarget,
    );
  }

  /// Resolve the media_kit track for [track], or say why it cannot be had.
  ///
  /// Embedded tracks the media_kit player already sees in the container (in
  /// direct play) are already in [_mediaKitSubtitleTrackMap] once
  /// [_detectTracks] runs, at no fetch cost. Everything else has nothing to
  /// load until this fetches it: a bitmap track on a streamed source as a
  /// sidecar file ([_fetchImageSubtitleTrack]), and every other track as a
  /// text body ([_fetchTextSubtitleTrack]). That fetch happens here, at
  /// selection time, rather than eagerly in [_detectTracks] for every
  /// selectable track: most tracks a file offers are never selected in a
  /// given playback, and each one costs the server an ffmpeg run.
  ///
  /// The result is cached in [_mediaKitSubtitleTrackMap] so re-selecting the
  /// same track later in the same session (or the sync in
  /// [_showSubtitleSelector] finding it already selected) does not refetch.
  Future<_ResolvedSubtitle> _resolveMediaKitSubtitleTrack(
    app_models.SubtitleTrack track, {
    required int generation,
  }) async {
    final cached = _mediaKitSubtitleTrackMap[track.id];
    if (cached != null) return (track: cached, failureMessage: '');

    if (isImageSubtitleTrack(track)) {
      return _fetchImageSubtitleTrack(track, generation: generation);
    }

    final fetched = await _fetchTextSubtitleTrack(track);
    return (track: fetched, failureMessage: kSubtitleLoadFailedMessage);
  }

  /// Fetches bitmap [track] as the sidecar the server copies out of the
  /// source into the HLS session, and hands mpv the local copy.
  ///
  /// See `image_subtitle_sidecar.dart` for why mpv only ever gets a local
  /// path, and why the first pick of a track can wait minutes. The poll
  /// stops as soon as a newer pick or the screen going away makes
  /// [generation] stale.
  Future<_ResolvedSubtitle> _fetchImageSubtitleTrack(
    app_models.SubtitleTrack track, {
    required int generation,
  }) async {
    final source = _playback?.sessionFile(imageSidecarName(track.id));
    if (source == null) {
      return (track: null, failureMessage: kImageSubtitleUnavailableMessage);
    }

    final fetch = await fetchImageSidecar(
      url: Uri.parse(source.url),
      headers: source.probeHeaders ?? source.headers,
      cancelled: () => !_canApplySubtitleSelection(generation),
    );

    switch (fetch) {
      case SidecarReady(:final path):
        _imageSidecarPaths.add(path);
        final mkTrack = SubtitleTrack.uri(
          path,
          title: track.title,
          language: track.language,
        );
        _mediaKitSubtitleTrackMap[track.id] = mkTrack;
        return (track: mkTrack, failureMessage: '');
      case SidecarCancelled():
        return (track: null, failureMessage: '');
      case SidecarUnsupported() || SidecarFailed():
        debugPrint(
            '[PlayerScreen] Bitmap subtitle ${track.id} unavailable: $fetch');
        return (track: null, failureMessage: imageSidecarFailureMessage(fetch));
    }
  }

  /// Fetches [track]'s text body over GraphQL and wraps it for media_kit.
  ///
  /// Two callers wanting the same body while it is still fetching share one
  /// request; see [_subtitleBodyFetches].
  Future<SubtitleTrack?> _fetchTextSubtitleTrack(
    app_models.SubtitleTrack track,
  ) {
    return _subtitleBodyFetches[track.id] ??=
        _fetchSubtitleBody(track).whenComplete(() {
      _subtitleBodyFetches.remove(track.id);
    });
  }

  /// Fetches [track]'s body over GraphQL and caches it in
  /// [_mediaKitSubtitleTrackMap]. Null on any failure, never throws. Called
  /// only from [_resolveMediaKitSubtitleTrack].
  Future<SubtitleTrack?> _fetchSubtitleBody(
    app_models.SubtitleTrack track,
  ) async {
    try {
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);
      final result = await graphqlClient.query(
        subtitleContentQueryOptions(
          mediaFileId: widget.fileId,
          trackId: track.id,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Failed to fetch subtitle content for ${track.id}: ${result.exception}');
        return null;
      }

      // `result.data` is only ever null alongside `hasException` in this
      // client, so this branch is not expected to run in practice — but it
      // is checked explicitly rather than papered over with `?? const {}`,
      // which looked like it handled a missing response gracefully while
      // actually just deferring the same failure into the generated
      // `fromJson`'s non-nullable `__typename` cast, one line down.
      final data = result.data;
      if (data == null) {
        debugPrint(
            '[PlayerScreen] No data returned for subtitle content ${track.id}');
        return null;
      }

      final content = Query$SubtitleContent.fromJson(data).subtitleContent;
      if (content == null || content.isEmpty) {
        debugPrint('[PlayerScreen] No subtitle content for ${track.id}');
        return null;
      }

      final mkTrack = SubtitleTrack.data(
        content,
        title: track.title,
        language: track.language,
      );
      _mediaKitSubtitleTrackMap[track.id] = mkTrack;
      return mkTrack;
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching subtitle content: $e');
      return null;
    }
  }

  /// Show audio track selector and apply selection via media_kit
  Future<void> _showAudioSelector() async {
    final selected = await showAudioTrackSelector(
      context,
      _audioTracks,
      _selectedAudioTrack,
    );

    if (selected != null && selected != _selectedAudioTrack && mounted) {
      setState(() {
        _selectedAudioTrack = selected;
      });

      final player = _player;
      if (player == null) return;

      final mkTrack = _mediaKitAudioTrackMap[selected.id];
      if (mkTrack != null) {
        await _setAudioTrack(player, mkTrack);
        debugPrint('[PlayerScreen] Set audio track: ${selected.displayName}');
      } else {
        debugPrint(
            '[PlayerScreen] No media_kit track found for: ${selected.id}');
      }

      // Applied to this playback above; remembered here so the next episode
      // opens on it too. Every other media server treats a pick as a one-off
      // and makes the viewer repeat it, which is the complaint this removes.
      await _rememberAudioLanguage(selected.language);
    }
  }

  /// Stores the picked language against the show or film, so later episodes
  /// open on it without another pick.
  ///
  /// Deliberately fire-and-forget from the viewer's perspective: the track
  /// has already changed by the time this runs, so a failure here costs the
  /// preference and not the playback the person is watching. It is awaited
  /// only so the debug line reports the real outcome.
  ///
  /// Skips an untagged track. `'und'` is ffprobe's "undetermined", and
  /// storing it would pin the show to a preference that can never match
  /// anything on the next file.
  Future<void> _rememberAudioLanguage(String language) async {
    if (language.isEmpty || language == 'und') return;
    if (widget.fileId == 'offline') return;

    final graphqlClient = _graphqlClient;
    if (graphqlClient == null) return;

    try {
      final result = await graphqlClient.mutate(
        MutationOptions(
          document: documentNodeMutationSetAudioLanguagePreference,
          variables: Variables$Mutation$SetAudioLanguagePreference(
            fileId: widget.fileId,
            language: language,
          ).toJson(),
        ),
      );

      if (result.hasException) {
        // A server too old to know this mutation answers with a GraphQL
        // validation error. That is a version gap, not a fault, and it stays
        // silent for the viewer: the track they picked has already changed.
        debugPrint(
            '[PlayerScreen] Could not remember audio language: ${result.exception}');
        return;
      }

      // Kept for the next media this screen opens without remounting, which
      // is what a season playing through does: go_router keys the page by
      // route pattern, so `initState` does not run again for the next
      // episode and the fresh Player built there reads this field.
      final data = result.data?['setAudioLanguagePreference'];
      final updated = data?['preferredAudioLanguages'];
      if (updated is List) {
        _preferredAudioLanguages = updated.cast<String>();
      }

      debugPrint('[PlayerScreen] Remembered audio language: $language');
    } catch (e) {
      debugPrint('[PlayerScreen] Could not remember audio language: $e');
    }
  }

  /// Stores the picked subtitle against the show or film, so later episodes
  /// open on it without another pick.
  ///
  /// Fire-and-forget from the viewer's perspective, the same trade
  /// [_rememberAudioLanguage] makes: the track has already changed by the
  /// time this runs, so a failure costs the preference and never the playback
  /// the person is watching. A server too old to know the mutation answers
  /// with a GraphQL validation error, which is a version gap rather than a
  /// fault and stays silent.
  ///
  /// Called only for a pick the viewer made -- the sheet's tile, or a remote
  /// `selectTrack` -- and always after [_applySubtitleSelection] has returned,
  /// so a track that never loaded is not remembered as what this show opens
  /// on. The preference applying itself from storage is deliberately not a
  /// call site: that is a choice being restored, not a new one, and writing
  /// it back would let one episode whose track list lacks the remembered
  /// title degrade what is stored for the rest of the show.
  ///
  /// An mpv-native pick has no disposition flags of its own: media_kit
  /// publishes a title and a language and nothing else. It is translated
  /// through its stream index to the server's own track, which does have
  /// them, by the same route [_captureSubtitleIntent] uses across a source
  /// switch. A track that cannot be translated stores its language and title
  /// with both flags false, which the matcher's title tiebreak still
  /// resolves on the next episode.
  ///
  /// Two picks in quick succession are queued rather than raced: see
  /// [_subtitlePreferenceWrite].
  ///
  /// [generation] is the selection generation the pick ran under, which the
  /// call sites pass straight back from [_applySubtitleSelection]. Omitted,
  /// whatever generation is live now is used, which is only correct because
  /// the call sites enqueue this immediately after their apply returned.
  /// Either way the write is bound to it: see [_writeSubtitlePreference] for
  /// why the queue cannot trust the state it reads once its turn comes.
  Future<void> _rememberSubtitlePreference(
    app_models.SubtitleTrack? track, {
    int? generation,
  }) async {
    final queued = (
      track: track,
      // Captured here, not read in the body: the queue can outlive both the
      // file this pick was made on and the attempt that made it.
      mediaKey: _mediaKey,
      fileId: widget.fileId,
      generation: generation ?? _subtitleSelectionGeneration,
    );
    // Appended rather than started, so two picks land in the order they were
    // made. `catchError` keeps a failed write from poisoning the tail: the
    // body already swallows its own errors, and a queue that stops on the
    // first exception would silently drop every later pick.
    _subtitlePreferenceWrite = _subtitlePreferenceWrite
        .then((_) => _writeSubtitlePreference(queued))
        .catchError((Object e) {
      debugPrint('[PlayerScreen] Could not remember subtitle preference: $e');
    });
    return _subtitlePreferenceWrite;
  }

  /// The queued body of [_rememberSubtitlePreference], which is the only
  /// caller: reaching this any other way would take the write back out of the
  /// order that method exists to keep.
  ///
  /// [queued] is the whole of what this sends. A queued write belongs to the
  /// file and the selection generation that made it, and it is dropped when
  /// either has moved on rather than rebuilt from the state now showing: the
  /// queue can outlive both. Navigating from one episode to the next reuses
  /// this State (see [didUpdateWidget]), so a pick still waiting here when the
  /// file changes would otherwise name the *new* file with the old file's
  /// track, and a pick a later one superseded would store a choice the viewer
  /// has already moved past. Both are invisible to a call site's own "after
  /// the apply" ordering, which is why the check is here and not there.
  ///
  /// Resolving the track against the server happens after those checks, not
  /// before: [_serverSideSubtitleTrack] reads the live player and the live
  /// server track list, so running it for a pick that has already been
  /// dropped would translate one file's track against another file's list.
  Future<void> _writeSubtitlePreference(
      _QueuedSubtitlePreference queued) async {
    final track = queued.track;

    // The pick has to be the one actually showing. [_applySubtitleSelection]
    // returns normally when a body never loaded, and when a later pick
    // superseded this one, so a call site's "after the apply" ordering is only
    // half the story -- this is the other half, and it is here rather than at
    // each call site so neither can forget it. `SubtitleTrack.operator ==` is
    // id-based, and null compares equal to null, which is exactly the "Off"
    // case: an explicit Off is a selection like any other and is remembered as
    // one.
    if (_selectedSubtitleTrack != track) return;

    // The rest of the identity, and only meaningful once the pick above is
    // still what is showing: a queued write that lost its file or its
    // generation is not a choice this screen can still speak for.
    if (queued.mediaKey != _mediaKey) return;
    if (queued.generation != _subtitleSelectionGeneration) return;

    if (queued.fileId == 'offline') return;

    final graphqlClient = _graphqlClient;
    if (graphqlClient == null) return;

    final resolved =
        track == null ? null : await _serverSideSubtitleTrack(track);

    // Re-checked after the await, not only before it. By now a later pick may
    // have won, and its own queued write is behind this one: sending this
    // would store a selection that is no longer showing. The file and the
    // generation are re-checked with it, for the same reason: the await above
    // is long enough for the viewer to have moved on to another episode.
    if (_selectedSubtitleTrack != track) return;
    if (queued.mediaKey != _mediaKey) return;
    if (queued.generation != _subtitleSelectionGeneration) return;

    // A track with no usable language tag would pin the show to a preference
    // that can never match anything on the next file, exactly as an 'und'
    // audio track would. Better to remember nothing.
    if (track != null && (resolved == null || !_hasUsableLanguage(resolved))) {
      return;
    }

    try {
      final result = await graphqlClient.mutate(
        MutationOptions(
          document: documentNodeMutationSetSubtitlePreference,
          variables: Variables$Mutation$SetSubtitlePreference(
            // The captured file, never a fresh read of `widget.fileId`: by
            // now this screen can be showing a different one.
            fileId: queued.fileId,
            mode: resolved == null
                ? Enum$SubtitlePreferenceMode.OFF
                : Enum$SubtitlePreferenceMode.TRACK,
            language: resolved?.language,
            forced: resolved?.forced,
            hearingImpaired: resolved?.hearingImpaired,
            trackTitle: resolved?.title,
          ).toJson(),
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Could not remember subtitle preference: ${result.exception}');
        return;
      }

      debugPrint('[PlayerScreen] Remembered subtitle preference');
    } catch (e) {
      debugPrint('[PlayerScreen] Could not remember subtitle preference: $e');
    }
  }

  /// [track] as the server knows it, or null when it cannot be translated.
  ///
  /// A server track is already in the server's id space and is returned as
  /// is. An mpv-native one is matched to the server's list through its
  /// stream index, which has to be read while its file is still loaded.
  Future<app_models.SubtitleTrack?> _serverSideSubtitleTrack(
    app_models.SubtitleTrack picked,
  ) async {
    if (!isMpvNativeSubtitleTrackId(picked.id)) return picked;

    final player = _player;
    if (player == null) return null;

    final mpvId = mpvIdOfSubtitleTrack(picked.id);
    if (mpvId == null) return null;

    final streamIndex = (await subtitleStreamIndices(player))[mpvId];
    final intent = subtitleIntentBeforeSwitch(
      selected: picked,
      viewerChose: true,
      selectedStreamIndex: streamIndex,
      serverTracks: _serverSubtitleTracks,
    );

    return switch (intent) {
      IntentTrack(:final track) => track,
      // Unmappable: keep what mpv told us. The language and title still
      // identify the track well enough for the next episode's list.
      _ => picked,
    };
  }

  /// Whether [track] names a language that can match a track on another file.
  ///
  /// `'und'` is ffprobe's "undetermined", which every untagged track reports,
  /// so storing it would pin the show to a preference that nothing can
  /// satisfy.
  bool _hasUsableLanguage(app_models.SubtitleTrack track) {
    final language = track.language.trim().toLowerCase();
    return language.isNotEmpty && language != 'und';
  }

  /// Shows the quality picker and switches sources at the current position.
  Future<void> _showQualitySelector() async {
    // A restart already in flight owns the player this would act on, exactly
    // as in [seekToReal]. Dropping the request beats queueing one against a
    // session on its way out.
    if (_switchingSource) return;

    final previous = _selectedQuality;

    final selected = await showQualityPicker(
      context,
      [QualityRung.auto, ..._qualityLadder],
      _selectedQuality,
      autoSubtitle: _autoDeliverySubtitle(),
      originalSubtitle: _originalDeliverySubtitle,
      clampNote: qualityClampNote(plan: _plan, effective: _effectiveQuality),
      statsEnabled: ref.read(statsOverlayEnabledProvider).value ?? false,
      onStatsChanged: (enabled) => unawaited(
        ref.read(statsOverlayEnabledProvider.notifier).set(enabled),
      ),
    );

    // A fallback or automatic seek can start while the dialog is open.
    if (selected == null ||
        selected == _selectedQuality ||
        !mounted ||
        _switchingSource) {
      return;
    }

    // Read after the choice, not before it: playback carries on behind the
    // open dialog, so a position captured when the picker appeared would
    // rewind the viewer by however long they spent deciding.
    //
    // Real coordinates, not the player's: on a resumed session the player's
    // zero is [StreamTimeline.startOffset] into the media, and
    // [_switchSource] takes a real target.
    final position = _timeline.toReal(_player?.state.position ?? Duration.zero);

    await applyQualityChoice(
      selected: selected,
      previous: previous,
      adopt: (rung) {
        // In memory, and only in memory. This is the channel the restart
        // below reads the rung from — [_resolveQualityForFile] carries
        // `_settledQuality` forward rather than re-reading storage.
        _settledQuality = rung;
        // A pick that delivers the same bytes reopens nothing, so the policy
        // already watching the source has to follow the choice. Starting a
        // fresh one would not: media_kit's streams do not replay, and a
        // monitor created mid-playback never sees playback as started.
        _policy?.reactsToBandwidth = !rung.isOriginal;
        if (mounted) setState(() {});
      },
      remember: (rung) =>
          ref.read(settingsServiceProvider).setDefaultQuality(rung.storageKey),
      restart: (rung, {required bool isFallback}) async {
        final inputs = _planInputs;
        if (inputs == null) return false;
        final plan =
            planPlayback(inputs.copyWith(choice: QualityChoice.fromRung(rung)));
        final current = _plan;
        if (!qualityPickNeedsReopen(
            next: plan, current: current, isFallback: isFallback)) {
          // Auto and Original both direct play this file, say: the choice
          // changes and the bytes do not, so there is nothing to reopen. Only
          // on the viewer's first attempt: a rollback always reopens, since
          // the attempt it undoes may have already moved the player onto
          // failing media before it threw, leaving the recorded plan stale.
          debugPrint('[PlayerScreen] Quality change: ${plan.describe()} '
              '(already playing)');
          if (mounted) setState(() => _plan = plan);
          return true;
        }
        debugPrint('[PlayerScreen] Quality change: ${plan.describe()}');
        _showToast(isFallback
            ? 'Returning to ${rung.label}'
            : 'Switching to ${rung.label}');
        return _switchSource(plan, at: position);
      },
      stillActive: () => mounted,
      onGaveUp: (error) => setState(() {
        _error = error.toString();
        _isLoading = false;
      }),
    );
  }

  /// The Auto row's subtitle: what is playing now when Auto is in effect,
  /// otherwise what Auto would do for this file.
  String _autoDeliverySubtitle() {
    final plan = _plan;
    if (_selectedQuality.isAuto && plan != null) {
      return autoDeliverySubtitle(plan, effective: _effectiveQuality);
    }
    final inputs = _planInputs;
    if (inputs == null) return kAutoPreferenceSubtitle;
    return autoDeliverySubtitle(
        planPlayback(inputs.copyWith(choice: QualityChoice.auto)));
  }

  void _onChromeVisibilityChanged() {
    if (_chromeVisibility.visible) return;
    if (_chromeFocusNode.hasFocus) _focusNode.requestFocus();
  }

  /// Handle keyboard shortcuts (desktop only)
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final player = _player;
    if (player == null) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    _upNextCountdown?.noteInput();

    // Arrow keys mean different things depending on the input tier and
    // whether the OSD is on screen. See `resolveArrowIntent`'s own dartdoc.
    final arrow = PlayerScreen.resolveArrowIntent(
      key: event.logicalKey,
      directionalPrimary: InputCapabilities.directionalPrimary,
      chromeVisible: _chromeVisibility.visible,
    );

    switch (arrow) {
      case ArrowIntent.seekBackward:
        _skipBy(const Duration(seconds: -10));
        return KeyEventResult.handled;

      case ArrowIntent.seekForward:
        _skipBy(const Duration(seconds: 10));
        return KeyEventResult.handled;

      case ArrowIntent.scrubBackward:
      case ArrowIntent.scrubForward:
        final forward = arrow == ArrowIntent.scrubForward;
        final started = _scrub.step(
          forward ? ScrubDirection.forward : ScrubDirection.backward,
          isRepeat: false,
        );
        if (started) {
          _chromeVisibility.show();
          _scrubberFocus.requestFocus();
        } else {
          // Unknown runtime: a cursor has nothing to be a fraction of.
          _skipBy(Duration(seconds: forward ? 10 : -10));
        }
        return KeyEventResult.handled;

      case ArrowIntent.volumeUp:
        player.setVolume((player.state.volume + 10.0).clamp(0.0, 100.0));
        return KeyEventResult.handled;

      case ArrowIntent.volumeDown:
        player.setVolume((player.state.volume - 10.0).clamp(0.0, 100.0));
        return KeyEventResult.handled;

      case ArrowIntent.revealChrome:
        _chromeVisibility.show();
        _osdPlayPauseFocus.requestFocus();
        return KeyEventResult.handled;

      case ArrowIntent.traverse:
        // Falls through to the switch below, which handles the non-arrow
        // keys. An arrow reaching here is deliberately left unhandled so
        // focus traversal moves between the OSD's controls.
        break;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        // Play/Pause
        player.playOrPause();
        return KeyEventResult.handled;

      // A remote's centre press. With the OSD hidden there is no focused
      // control to receive it — the controls' own FocusHighlight is what
      // handles select/enter normally — so OK would otherwise do nothing at
      // all. Revealing and focusing is the same move the arrow keys make.
      //
      // Gated on the directional tier because the key handler also runs on
      // desktop and web (`wantsKeyHandling` is true there via
      // `supportsKeyboardShortcuts`), where Enter previously fell through to
      // `ignored` and did nothing. A keyboard user pressing Enter over a
      // hidden OSD has not asked for the OSD.
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.gameButtonA:
        if (!InputCapabilities.directionalPrimary)
          return KeyEventResult.ignored;
        if (_chromeFocusNode.hasFocus) return KeyEventResult.ignored;
        _chromeVisibility.show();
        _osdPlayPauseFocus.requestFocus();
        return KeyEventResult.handled;

      // A remote's transport buttons. The Chromecast remote's play/pause is
      // the one that matters here; the rest arrive from fuller remotes and
      // from desktop keyboards with a media row, which get them for free.
      case LogicalKeyboardKey.mediaPlayPause:
        player.playOrPause();
        _chromeVisibility.show();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.mediaPlay:
        player.play();
        _chromeVisibility.show();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.mediaPause:
        player.pause();
        _chromeVisibility.show();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.mediaFastForward:
        final position = _timeline.toReal(player.state.position);
        final duration = _timeline.resolveDuration(player.state.duration);
        final target = position + const Duration(seconds: 30);
        seekToReal(target > duration ? duration : target);
        _chromeVisibility.show();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.mediaRewind:
        final position = _timeline.toReal(player.state.position);
        final target = position - const Duration(seconds: 30);
        seekToReal(target < Duration.zero ? Duration.zero : target);
        _chromeVisibility.show();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.mediaTrackNext:
        if (!_hasNextEpisode) return KeyEventResult.ignored;
        _playNextEpisode();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.mediaTrackPrevious:
        if (!_hasPreviousEpisode) return KeyEventResult.ignored;
        _playPreviousEpisode();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyF:
        // Gated on the same signal as the button, so the two cannot disagree
        // about whether fullscreen exists. Claiming the key while doing nothing
        // would swallow it from anything else that wants it.
        if (!_fullscreen.available.value) return KeyEventResult.ignored;
        _fullscreen.toggle();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyT:
        if (!PlatformFeatures.isDesktop) return KeyEventResult.ignored;
        _toggleAlwaysOnTop();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyM:
        // Toggle mute
        if (player.state.volume > 0) {
          player.setVolume(0.0);
        } else {
          player.setVolume(100.0);
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyZ:
        // mpv's own subtitle-delay binding: z earlier, shift+z later. A
        // no-op with no track selected or the offsets query never having
        // succeeded -- see [_nudgeSubtitleDelay].
        if (HardwareKeyboard.instance.isShiftPressed) {
          _nudgeSubtitleDelay(100);
        } else {
          _nudgeSubtitleDelay(-100);
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.escape:
        // The prompt takes the first branch: while it is up, Escape means
        // "not this", not "leave fullscreen". This case already returned
        // `handled` unconditionally, so nothing downstream changes.
        if (_showUpNext) {
          _cancelAutoPlay();
          return KeyEventResult.handled;
        }
        if (_fullscreen.isFullscreen.value) {
          _fullscreen.exit();
        }
        return KeyEventResult.handled;

      // Previous/next episode. This is the only reachable path to episode
      // navigation on a narrow window: below `PanelMetrics.touchTargets`'s
      // breakpoint, `ChromePanel`'s in-bar transport drops to play/pause
      // only (see `TransportSurface.compact`), and that gate is on viewport
      // *width*, not `PlatformFeatures.isMobile` — so a narrowed desktop or
      // web browser window loses the in-bar buttons too, with no
      // `UpNextOverlay` (autoplay-only, next-episode-only) or touch gesture
      // to fall back on. This actually covers web now that
      // `PlatformFeatures.supportsKeyboardShortcuts` includes it (see that
      // getter's own dartdoc) — previously this whole `Focus`/`onKeyEvent`
      // wrapper was desktop-only, so a narrowed *web* window had no
      // fallback at all, keyboard or otherwise.
      case LogicalKeyboardKey.pageUp:
      case LogicalKeyboardKey.pageDown:
        return handleEpisodeNavKey(
          event,
          hasPreviousEpisode: _hasPreviousEpisode,
          hasNextEpisode: _hasNextEpisode,
          onPreviousEpisode: _playPreviousEpisode,
          onNextEpisode: _playNextEpisode,
        );

      default:
        return KeyEventResult.ignored;
    }
  }

  /// The arrow keys' plain skip: a relative seek, then the OSD.
  ///
  /// Clamps to the runtime only when the runtime is known. Clamping against
  /// an unknown (zero) runtime turned every forward skip into a seek to the
  /// start, and the scrub fallback above sends exactly that case here.
  void _skipBy(Duration offset) {
    final player = _player;
    if (player == null) return;
    final duration = _timeline.resolveDuration(player.state.duration);
    var target = _timeline.toReal(player.state.position) + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    seekToReal(target);
    _chromeVisibility.show();
  }

  /// Points the scrub bubble at [fileId]'s trickplay frames.
  ///
  /// Direct HTTP only: the p2p local proxy forwards `/hls`, `/direct` and
  /// `/download` and nothing else, so over p2p the bubble shows the time
  /// alone. Remote tier only, the one tier that draws the bubble.
  void _attachScrubThumbnails({
    required String serverUrl,
    required String token,
    required String fileId,
    required bool isP2PMode,
  }) {
    _scrubThumbnails?.dispose();
    _scrubThumbnails = null;
    if (isP2PMode || !InputCapabilities.directionalPrimary) return;
    _scrubThumbnails = ScrubThumbnails(
      service: ThumbnailService(serverUrl: serverUrl, authToken: token),
      fileId: fileId,
    );
  }

  /// Rebuilds so the chrome's fullscreen icon follows observed state, and so
  /// the button appears and disappears with the route. Cheap: both notifiers
  /// only fire on a real transition.
  void _onFullscreenChanged() {
    _publishFullscreenReport();
    if (mounted) setState(() {});
  }

  /// Hands the current picture to `/settings/diagnostics`, which outlives this
  /// screen and is where a bug report is assembled. See
  /// `fullscreen_report_signal.dart`.
  void _publishFullscreenReport() =>
      fullscreenReportSignal.value = _fullscreen.report;

  /// Tells the viewer that a fullscreen request was refused.
  ///
  /// Only requests get a message. A capability probe that threw while the
  /// screen was opening is real and lands in `/settings/diagnostics`, but
  /// announcing it to someone who never asked for fullscreen is noise.
  ///
  /// The text stays plain on purpose: a WebKit rejection reason is not
  /// something a viewer can act on, and the detail is in the readout.
  void _onFullscreenFailure(FullscreenFailure failure) {
    _publishFullscreenReport();
    if (!failure.requestInitiated) return;
    if (!mounted) return;
    // A refused exit is also viewer-initiated, so it reaches here too. Saying
    // "could not enter" to someone trying to leave fullscreen would describe
    // the opposite of what they did.
    final message = switch (failure.cause) {
      FullscreenFailureCause.documentExitRejected ||
      FullscreenFailureCause.videoExitFailed =>
        'Could not exit fullscreen',
      _ => 'Could not enter fullscreen',
    };
    showToast(context, message, kind: ToastKind.error);
  }

  /// Toggle always-on-top across desktop platforms.
  ///
  /// Both call sites (the button and the `T` shortcut) are already gated on
  /// `PlatformFeatures.isDesktop`, so this only ever runs on desktop in
  /// practice. [setWindowAlwaysOnTop] gates on the same check independently,
  /// so the OS pin operation is a no-op if this were ever reached elsewhere
  /// — but `_isAlwaysOnTop` itself always flips when this method runs; it is
  /// not conditioned on platform.
  void _toggleAlwaysOnTop() {
    setState(() => _isAlwaysOnTop = !_isAlwaysOnTop);
    setWindowAlwaysOnTop(_isAlwaysOnTop);
  }

  @override
  void dispose() {
    // Detached first, before anything below can run: a remote command that
    // lands mid-teardown must find no player attached rather than reach a
    // `_player` that is about to be disposed out from under it.
    //
    // Passes `this` so a newer `PlayerScreen` that already attached over
    // this one (a remote `LoadContent` mounts before the old screen
    // disposes) is never clobbered by this late detach — see
    // `detachPlayer`'s own dartdoc. That mounts before disposal only when it
    // replaces the route; one that only changes the file reuses this State
    // (see [didUpdateWidget]).
    _remoteTargetController.detachPlayer(this);
    _nowPlaying.clear(this);
    final playbackNotifier = _localPlaybackNotifier;
    final acquired = _acquiredPlayback;
    if (playbackNotifier != null && acquired) {
      Future.microtask(() {
        playbackNotifier.release();
      });
    }

    // Order matters twice over. Stop listening *first*: in `systemUi` mode
    // `exit()` reports the transition synchronously, and the resulting
    // `setState` would assert — by the time `State.dispose` runs, the element
    // is already defunct (`StatefulElement.unmount` calls `super.unmount()`
    // before `state.dispose()`), and `markNeedsBuild` asserts on exactly that.
    // The `mounted` check in `_onFullscreenChanged` is not a guard here:
    // `_element` is nulled only after dispose returns, so it still reads true.
    // Then exit before `dispose()`, which disposes the notifier underneath it.
    _fullscreen.isFullscreen.removeListener(_onFullscreenChanged);
    _fullscreen.available.removeListener(_onFullscreenChanged);
    unawaited(_fullscreenFailures?.cancel());
    _fullscreenFailures = null;
    if (_fullscreen.isFullscreen.value) {
      _fullscreen.exit();
    }
    _fullscreen.dispose();

    // Un-pin the window if it was pinned — never let always-on-top leak
    // into the browse/library window behind this one.
    if (_isAlwaysOnTop) {
      setWindowAlwaysOnTop(false);
    }

    // Restores the window the user was browsing in and resumes geometry
    // persistence. Fire-and-forget: `dispose` cannot await, and the sizer
    // swallows its own failures. Null only if `initState` threw before the
    // assignment ran, in which case there is nothing to detach.
    final windowSizer = _windowSizer;
    if (windowSizer != null) {
      unawaited(windowSizer.detach());
    }

    // Final release restores normal orientations after the handoff frame. A
    // replacement PlayerScreen cancels that restore by acquiring its lease.
    if (_ownsOrientationLease) {
      playerOrientationLeaseController.release(_orientationLeaseOwner);
    }

    // Save progress before disposing (fire and forget - can't await in
    // dispose), then invalidate: the second of the roughly two invalidations
    // per session. Chained, not independent fire-and-forget calls, so the
    // refetch it triggers can't race the save and pick up pre-save data.
    // `whenComplete` (not `then`) so a failing save still lets the
    // invalidation run instead of it being silently dropped.
    _saveProgress().whenComplete(_invalidateAfterPlayback);

    // Terminate HLS session on server to stop FFmpeg (fire and forget)
    _stopVerification();
    _stopStatsCollector();
    _terminateHlsSession();

    // Unregister beforeunload handler on web
    if (kIsWeb) {
      web_lifecycle.unregisterBeforeUnload();
    }

    // Cancel stream subscriptions to prevent memory leaks
    _positionSubscription?.cancel();
    _tracksSubscription?.cancel();
    _errorSubscription?.cancel();
    _nowPlayingSubscription?.cancel();
    unawaited(_cancelMediaSessionSubscriptions());
    _firstFrameSubscription?.cancel();
    // Flush whatever marks this load reached; a no-op if a first frame (or
    // `_disposePlayer`) already logged the one summary line for this timeline.
    _playTimeline?.logOnce();

    // Cancel auto-play countdown
    _upNextCountdown?.dispose();
    _upNextPlayingSub?.cancel();
    _upNextPlayingSub = null;

    // Stop progress tracking
    _progressService?.stopSync();
    _progressService?.dispose();

    // Dispose player (VideoController is automatically disposed when player is disposed)
    //
    // Cleared first, the same way `_disposePlayer` does it. An
    // `_initializePlayer` still in flight when the screen unmounts runs its
    // own `_disposePlayer` afterwards, and with the field left set that
    // second call reached the same already-disposed `Player` and tripped
    // media_kit's own `Assertion failed: "[Player] has been disposed"`.
    // Clearing it makes the late call a no-op instead.
    final player = _player;
    _player = null;
    _videoController = null;
    player?.dispose();
    _focusNode.dispose();
    _osdPlayPauseFocus.dispose();
    _scrub.dispose();
    _scrubberFocus.dispose();
    _scrubThumbnails?.dispose();
    _chromeFocusNode.dispose();
    _chromeVisibility.removeListener(_onChromeVisibilityChanged);
    _chromeVisibility.dispose();
    _subtitleDelayDisplay.dispose();
    for (final path in _imageSidecarPaths) {
      unawaited(discardImageSidecar(path));
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // RemotePlayerBinding
  //
  // Forwards each command to the media_kit `Player` this screen already
  // owns. Nothing here duplicates playback logic: `seek` reuses `seekToReal`
  // (the same entry point the keyboard and gesture controls use), and
  // episode stepping reuses `_playNextEpisode`/`_playPreviousEpisode`. Track
  // selection is the one place this does less than the on-screen pickers —
  // it applies a track by id directly and skips their loading-toast and
  // remembered-language-preference side effects, which are UI concerns a
  // remote command has no use for.
  // ---------------------------------------------------------------------

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> stop() async => _player?.stop();

  @override
  Future<void> seek(Duration to) => seekToReal(to);

  /// [level] is 0.0-1.0 on the wire; media_kit's `Player.setVolume` is 0-100.
  /// See [remoteControlVolumeToPlayerVolume].
  @override
  Future<void> setVolume(double level) async =>
      _player?.setVolume(remoteControlVolumeToPlayerVolume(level));

  /// Mirrors the existing keyboard M-key handler: this player has no
  /// separate mute flag, only volume, so muting snaps to 0 and unmuting
  /// snaps to full rather than restoring whatever was set before muting. See
  /// [remoteControlMuteVolume].
  @override
  Future<void> setMuted(bool muted) async =>
      _player?.setVolume(remoteControlMuteVolume(muted));

  @override
  Future<void> selectTrack(TrackKind kind, String? id) async {
    switch (kind) {
      case TrackKind.audio:
        if (id == null) return;
        final track = findTrackById(_audioTracks, id, idOf: (t) => t.id);
        final mkTrack = _mediaKitAudioTrackMap[id];
        final player = _player;
        if (track == null || mkTrack == null || player == null) return;
        await _setAudioTrack(player, mkTrack);
        if (mounted) setState(() => _selectedAudioTrack = track);

      case TrackKind.subtitle:
        if (!shouldAcceptSubtitlePick(switchInFlight: _switchingSource)) {
          return;
        }

        // `id` names a track a remote peer chose; one this screen does not
        // list is dropped rather than guessed at, as for audio above.
        final app_models.SubtitleTrack? track;
        if (id == null) {
          track = null;
        } else {
          track = findTrackById(_subtitleTracks, id, idOf: (t) => t.id);
          if (track == null) return;
        }
        // The same routine as the sheet, so a remote pick gets the same
        _subtitleChosenThisPlayback = true;
        _subtitleIntentAcrossSwitch = null;
        final generation = await _applySubtitleSelection(track);
        // Remotely or by hand, a pick is a pick: remembered for the show,
        // bound to the generation it ran under exactly as the sheet's is.
        unawaited(_rememberSubtitlePreference(track, generation: generation));
    }
  }

  @override
  Future<void> stepEpisode(EpisodeStep step) async {
    switch (step) {
      case EpisodeStep.next:
        _playNextEpisode();
      case EpisodeStep.previous:
        _playPreviousEpisode();
    }
  }

  @override
  FlutterPlaybackSnapshot describe(int sequence) {
    final player = _player;
    final position = player == null
        ? Duration.zero
        : _timeline.toReal(player.state.position);
    final duration = player == null
        ? (_timeline.totalDuration ?? Duration.zero)
        : _timeline.resolveDuration(player.state.duration);

    return FlutterPlaybackSnapshot(
      state: _remoteControlPlaybackState(player),
      // For an episode `widget.mediaId` is the episode's own id and
      // `widget.showId` is the underlying media item; for a movie
      // `widget.mediaId` is the media item itself and there is no episode.
      mediaItemId:
          widget.mediaType == 'episode' ? widget.showId : widget.mediaId,
      episodeId: widget.mediaType == 'episode' ? widget.mediaId : null,
      title: widget.title ?? 'Untitled',
      subtitle: null,
      imageUrl: null,
      positionMs: BigInt.from(position.inMilliseconds),
      durationMs: BigInt.from(duration.inMilliseconds),
      volume: player == null
          ? null
          : playerVolumeToRemoteControlVolume(player.state.volume),
      muted: isPlayerVolumeMuted(player?.state.volume),
      audioTracks: _audioTracks
          .map((t) => FlutterTrackInfo(
              id: t.id, label: t.displayName, language: t.language))
          .toList(),
      subtitleTracks: _subtitleTracks
          .map((t) => FlutterTrackInfo(
              id: t.id, label: t.displayName, language: t.language))
          .toList(),
      selectedAudio: _selectedAudioTrack?.id,
      selectedSubtitle: _selectedSubtitleTrack?.id,
      capabilities: FlutterTargetCapabilities(
        // App-level output volume through media_kit, which works on every
        // platform this ships on. System volume is a different, harder
        // problem this target does not attempt.
        volume: true,
        trackSelection: true,
        // Reported per-title rather than unconditionally: a movie, or an
        // episode with no adjacent episode in this season, has nothing for
        // Next/Previous to do, and claiming the capability anyway would show
        // a controller a button that silently does nothing.
        nextPrevious: _hasNextEpisode || _hasPreviousEpisode,
      ),
      sequence: BigInt.from(sequence),
    );
  }

  /// Sends what the Dock menu should show. The title is the same string
  /// [describe] gives remote controllers.
  void _publishNowPlaying() {
    if (!mounted) return;
    // Same moments the Dock cares about (play/pause, episode list loaded)
    // matter to the OS media session.
    _remoteTargetController.notifyChanged();
    _nowPlaying.publish(
      this,
      NowPlaying(
        title: widget.title ?? 'Untitled',
        isPlaying: _player?.state.playing ?? false,
        hasNext: _hasNextEpisode,
      ),
    );
  }

  /// Reads this screen's own loading/error flags and the `Player`'s state,
  /// and hands them to [remoteControlPlaybackState] for the actual mapping.
  FlutterPlaybackState _remoteControlPlaybackState(Player? player) =>
      remoteControlPlaybackState(
        hasError: _error != null,
        isLoading: _isLoading,
        hasPlayer: player != null,
        buffering: player?.state.buffering ?? false,
        completed: player?.state.completed ?? false,
        playing: player?.state.playing ?? false,
      );

  @override
  Widget build(BuildContext context) {
    // Ending a cast rebinds the local proxy on a fresh ephemeral port (and
    // drops the LAN path token), which invalidates the URL media_kit is
    // holding. Nothing else re-initialises the local player, so without this
    // the screen comes back from casting to a dead video surface.
    ref.listen<bool>(isCastingProvider, (previous, next) {
      if (previous == true && next == false) {
        unawaited(_restartLocalPlayback());
      }
      // The receiver is now the thing the viewer is watching. A fault on the
      // backgrounded local player is not theirs to see, so it must not spend
      // a fallback or a failure-memory write on a source nothing is showing.
      //
      // The collector stops for a different reason: it does not feed
      // `AdaptationPolicy` at all, so nothing it observes is wrong while
      // casting, only pointless. `_buildBody`'s `Stack` (where the panel
      // lives) is not built while `isCastingProvider` is true -- `build`
      // swaps to `_buildCastPlaceholder` first -- so the panel is already
      // invisible without this. Invisible is not inactive: without also
      // stopping the collector here, its `Timer.periodic` keeps sampling
      // mpv once a second against a player that is not decoding anything,
      // for the whole cast session. `_startStatsCollector`, called
      // unconditionally from `_openPlayerAndStart`, re-arms it when local
      // playback resumes (`_restartLocalPlayback` -> `_initializePlayer`).
      if (previous == false && next == true) {
        _stopVerification();
        _stopStatsCollector();
      }
    });

    // Auto-skip while casting. Local playback rides the player's own position
    // listener, which casting never builds, so the session stream stands in
    // for it: `CastSessionManager` republishes the session on every receiver
    // position tick, already mapped into real media coordinates.
    //
    // Only as reliable as the app being awake, which is the honest limit of
    // driving this from the phone. A backgrounded player sails through the
    // intro, and fixing that properly means a custom receiver.
    ref.listen<AsyncValue<CastSession?>>(castSessionProvider, (_, next) {
      final session = next.value;
      final position = session?.mediaInfo?.position;
      if (session == null || position == null || session.isStale) return;
      _maybeAutoSkipAt(position, _castSeekToReal);
    });

    // Flipping the switch while a file is open must start or stop the
    // collector; without this the panel only appears on the next source.
    // Both branches call `setState`: `ref.listen`'s callback does not
    // itself trigger a rebuild, and nothing else guarantees one soon after
    // (`_onPlaybackProgress` does not `setState` every tick), so turning
    // the flag on mid-playback could otherwise leave the panel unbuilt
    // until some unrelated rebuild happened to come along.
    ref.listen<AsyncValue<bool>>(statsOverlayEnabledProvider, (_, next) {
      final player = _player;
      if (player == null) return;
      if (next.value ?? false) {
        // Guarded on casting too, not just on `_statsCollector == null`:
        // the `isCastingProvider` listener above only fires on the
        // transition into casting, so toggling this flag off then on again
        // while a cast session is already active reaches this branch with
        // no transition to intercept it. Without the guard, `_player` is
        // still the backgrounded local player -- casting hides it behind
        // the cast placeholder, it never gets torn down -- so
        // `_startStatsCollector` would rearm a `Timer.periodic` sampling
        // that hidden player for the rest of the session, the same defect
        // the transition guard above exists to prevent, reached by a
        // different path. Local playback resuming is what re-arms it
        // properly, through `_openPlayerAndStart`'s unconditional
        // `_startStatsCollector`.
        if (_statsCollector == null && !ref.read(isCastingProvider)) {
          setState(() => _startStatsCollector(player));
        }
      } else {
        setState(_stopStatsCollector);
      }
    });

    final isCasting = ref.watch(isCastingProvider);
    final castSession = ref.watch(castSessionProvider).value;
    Widget body = isCasting && castSession != null
        ? _buildCastPlaceholder(castSession)
        : _buildBody();

    // Wrap with the key handler wherever a physical keyboard exists (native
    // desktop or web, see supportsKeyboardShortcuts' own dartdoc) or a D-pad
    // does. A remote sends the same arrow, Enter and media key codes a
    // keyboard does, so one handler serves both.
    if (PlayerScreen.wantsKeyHandling(
          supportsKeyboardShortcuts: PlatformFeatures.supportsKeyboardShortcuts,
          directionalPrimary: InputCapabilities.directionalPrimary,
        ) &&
        !isCasting) {
      body = Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: body,
      );
    }

    // Android's back button, which is the remote's most-pressed key after the
    // D-pad. It arrives as a route pop rather than a key event, so it needs
    // its own guard: the first press dismisses the OSD, and only a press with
    // the OSD already hidden leaves playback. Without this, one stray press
    // during a film exits it.
    //
    // Gated on `blocksBack`, not on `!visible` alone: `_chromeVisibility`
    // reads `visible: true` while detached too, matching how the chrome
    // mounts, so a bare `!visible` check swallows every back press for as
    // long as there is no chrome to dismiss at all: the loading spinner
    // before the OSD ever mounts, the error screen, and the cast placeholder
    // (`_buildCastPlaceholder`, which swaps in for `_buildBody()` above and
    // never builds one either). None of those has anything on screen for a
    // back press to dismiss, and there is no other way out of them on a
    // remote, so back has to pass straight through in all three.
    //
    // Gated on the directional tier as well, because this is a remote-only
    // affordance. The chrome mounts on every platform, and it is showing far
    // more of the time on a phone than on a television: for the first seconds
    // of playback, after every tap, and for as long as playback is paused
    // (hiding requires `isPlaying`). Without the tier term, a phone viewer
    // would need two back presses to leave the player in all of those states,
    // which is a regression against the behaviour before this screen took a
    // `PopScope` at all. A remote has no gesture to dismiss the OSD with, so
    // only there does back need to do that job first. An active D-pad scrub
    // adds a layer in front of that: Back cancels the scrub first (see
    // resolveBackAction).
    //
    // Wrapped in a `ListenableBuilder` rather than reading the controller
    // once: `_chromeVisibility` changes from deep inside the chrome widget
    // tree (a timer, a tap, attaching or detaching), never through this
    // screen's own `setState`, so `canPop` has to be recomputed on every
    // notification or it goes stale and back either never exits or always
    // does.
    final frame = PlayerScreen.playerFrame(child: body);

    BackAction backAction() => PlayerScreen.resolveBackAction(
          directionalPrimary: InputCapabilities.directionalPrimary,
          scrubActive: _scrub.active,
          chromeBlocksBack: _chromeVisibility.blocksBack,
        );

    return ListenableBuilder(
      listenable: Listenable.merge([_chromeVisibility, _scrub]),
      builder: (context, _) => PopScope(
        canPop: backAction() == BackAction.pop,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          // Re-resolved rather than captured: state can change between the
          // build that set `canPop` and the press that reaches here.
          switch (backAction()) {
            case BackAction.cancelScrub:
              _scrub.cancel();
            case BackAction.hideChrome:
              _chromeVisibility.hide();
            case BackAction.pop:
              break;
          }
        },
        child: frame,
      ),
    );
  }

  /// Cancels every subscription bound to the current player and disposes it.
  ///
  /// Nulls `_player`/`_videoController` at the very top, before any `await`
  /// -- not at the end, as this used to. [_switchToFile] calls this
  /// unawaited and relies on that ordering: it starts this function, does
  /// not await it immediately, and only the synchronous prefix (this
  /// null-out) is guaranteed to have run by the time control returns to it.
  /// A second switch or `dispose()` racing in right after must see `_player`
  /// already gone, never a live reference to a player a switch is mid-way
  /// through replacing. Every existing caller awaits this fully regardless,
  /// so clearing the fields sooner only makes the guarantee stricter; none
  /// of the cancellations below read `_player` (each cancels its own
  /// subscription field, or a collector/service that already captured its
  /// own reference when it started), so moving the null-out ahead of them
  /// changes nothing else about what this function does.
  ///
  /// Also stops the stats collector, covering every disposal path rather
  /// than requiring each caller to remember it -- the same reasoning that
  /// put `rebind()` inside `_switchSource` instead of at its call sites. It
  /// matters most on the init-failure path: `_startStatsCollector` runs
  /// before `player.open()` has succeeded, and `_initializePlayer`'s own
  /// catch calls `_disposePlayer` on that throw, so without this a
  /// `Timer.periodic` would keep sampling a player nothing is using.
  /// `_stopStatsCollector` is idempotent, so calling it again here on a
  /// path that already stopped the collector is a no-op.
  Future<void> _disposePlayer() async {
    _scrub.reset();
    final player = _player;
    _player = null;
    _videoController = null;

    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _tracksSubscription?.cancel();
    _tracksSubscription = null;
    await _errorSubscription?.cancel();
    _errorSubscription = null;
    await _nowPlayingSubscription?.cancel();
    await _cancelMediaSessionSubscriptions();
    // Precedes every later `_openPlayerAndStart` call (the web source-switch
    // branch in `_attachSource`, and the error catch in `_initializePlayer`),
    // so this is where a first-frame watch that never fired gets cancelled
    // before the next one starts.
    //
    // Deliberately does *not* flush `_playTimeline` here: the web branch of
    // `_attachSource` calls this and then `_openPlayerAndStart` again for
    // the *same* timeline (an AdaptationPolicy fallback mid-load is the
    // common case), so logging here would lock in a summary missing
    // `first_frame` before the fallback source ever gets a chance to reach
    // it -- `logOnce()`'s own guard would then make the real call a no-op.
    // The timeline only genuinely ends in `State.dispose()` or at the top of
    // the next `_initializePlayer` run, and only those flush it.
    await _firstFrameSubscription?.cancel();
    _firstFrameSubscription = null;
    _progressService?.stopSync();
    _stopStatsCollector();

    await player?.dispose();
  }

  /// Rebuilds local playback when casting stops.
  Future<void> _restartLocalPlayback() async {
    _stopVerification();
    await _disposePlayer();
    if (mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
        _autoplayBlocked = false;
      });
    }

    if (!mounted) return;
    await _initializePlayer();
  }

  /// Keep the cast affordance reachable in every state.
  ///
  /// Casting is the natural remedy for a file the local player cannot decode,
  /// so hiding the button behind "local playback is ready" removes it exactly
  /// when it is most useful.
  ///
  /// Built through `PlayerTopBarSlot`, the same seam `PlaybackChrome` places
  /// its back/title/cast pills through, so this state's cast pill lands at
  /// the exact spot the playing state's does: level with the window controls
  /// on a windowed desktop, or 16px below the safe area everywhere else. A
  /// second, independently-positioned pill here would drift from that the
  /// next time either one's placement changed.
  Widget _withCastAffordance(Widget child) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        PlayerTopBarSlot(
          child: ChromeTopBar(
            showBack: false,
            castAction: castChromeActionFor(ref),
            onCastTap: _showCastDevicePicker,
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return _withCastAffordance(
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(
                color: Colors.red,
              ),
              if (_loadingMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  _loadingMessage!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[400],
                      ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return _withCastAffordance(_buildError());
    }

    if (_videoController == null) {
      return _withCastAffordance(
        const Center(
          child: CircularProgressIndicator(
            color: Colors.red,
          ),
        ),
      );
    }

    // Video widget fills available space with black background
    // Using SizedBox.expand ensures proper sizing on all platforms
    Widget videoPlayer = SizedBox.expand(
      child: Video(
        controller: _videoController!,
        controls: customVideoControlsBuilderWithCallback(
          timeline: _timeline,
          onSeekToReal: seekToReal,
          title: widget.title,
          chromeVisibility: _chromeVisibility,
          playPauseFocusNode: _osdPlayPauseFocus,
          chromeFocusNode: _chromeFocusNode,
          // Remote tier only. Elsewhere the bar is pointer-driven and a
          // cursor controller would only be something else to keep in sync.
          scrub: InputCapabilities.directionalPrimary ? _scrub : null,
          scrubberFocusNode: _scrubberFocus,
          scrubThumbnails: _scrubThumbnails,
          onBack: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
          // The chrome's own cast pill. Null on a build that cannot cast at
          // all, which drops the pill rather than drawing an empty one.
          castAction: castChromeActionFor(ref),
          onCastTap: _showCastDevicePicker,
          onAudioTap: _showAudioSelector,
          onSubtitleTap: _showSubtitleSelector,
          // Hidden when Auto and Original could never differ for this file
          // (a local file, no plan yet, or a lossy source with no adaptive
          // ladder), matching how audio disables itself at zero tracks
          // rather than opening a one-item menu.
          onQualityTap: qualityControlAvailable(
                  localFile: _isDownloadedSource,
                  plan: _plan,
                  sourceHeight: _planInputs?.sourceHeight)
              ? _showQualitySelector
              : null,
          // Null where no fullscreen route exists, which hides the button
          // rather than leaving a dead one — matching how `onQualityTap`
          // above hides itself at a single quality rung.
          onFullscreenTap:
              _fullscreen.available.value ? _fullscreen.toggle : null,
          onAlwaysOnTopTap: _toggleAlwaysOnTop,
          onPreviousEpisode: _hasPreviousEpisode ? _playPreviousEpisode : null,
          onNextEpisode: _hasNextEpisode ? _playNextEpisode : null,
          onActivity: () => _upNextCountdown?.noteInput(),
          isFullscreen: _fullscreen.isFullscreen.value,
          isAlwaysOnTop: _isAlwaysOnTop,
          audioTrackCount: _audioTracks.length,
          selectedAudioLabel: _selectedAudioTrack?.displayName,
          selectedSubtitleLabel: _selectedSubtitleTrack?.displayName,
          selectedQualityLabel: qualityControlLabel(
              selected: _selectedQuality, effective: _effectiveQuality),
        ),
        fill: Colors.black,
      ),
    );

    // Wrap with gesture controls for mobile
    final player = _player;
    if (InputCapabilities.supportsGestureControls && player != null) {
      videoPlayer = GestureControls(
        player: player,
        timeline: _timeline,
        onSeekToReal: seekToReal,
        child: videoPlayer,
      );
    }

    final panelMetrics = PanelMetrics.resolve(
      width: MediaQuery.sizeOf(context).width,
      touchPrimary: InputCapabilities.touchPrimary,
    );

    return Stack(
      children: [
        videoPlayer,
        // Skip Intro / Skip Credits. Driven by its own position stream rather
        // than a setState per tick, and stood down while the up-next overlay
        // is showing so the two do not stack in the same bottom-right corner.
        if (player != null && _segments.isNotEmpty && !_showUpNext)
          Positioned.fill(
            child: StreamBuilder<Duration>(
              stream: player.stream.position,
              initialData: player.state.position,
              builder: (context, snapshot) {
                final position =
                    _timeline.toReal(snapshot.data ?? Duration.zero);
                final segment = _segmentAt(position);
                if (segment == null) return const SizedBox.shrink();

                return SkipSegmentButton(
                  key: ValueKey(segment.key),
                  segment: segment,
                  position: position,
                  onSkip: (target) => seekToReal(target.end),
                  metrics: panelMetrics,
                );
              },
            ),
          ),
        // Up Next. Always interactive, independent of chrome visibility.
        if (_showUpNext && _upNextTarget != null && _upNextCountdown != null)
          Positioned.fill(
            child: UpNextPrompt(
              target: _upNextTarget!,
              countdown: _upNextCountdown!,
              metrics: panelMetrics,
              onPlayNow: _playNextEpisode,
              onDismiss: _cancelAutoPlay,
              onEngagedChanged: (engaged) => engaged
                  ? _upNextCountdown?.hold(UpNextHold.engaged)
                  : _upNextCountdown?.release(UpNextHold.engaged),
            ),
          ),
        // Last in the stack, so the tap that starts playback reaches this and
        // not the seek gestures underneath. Nothing below it can do anything
        // useful while the browser is still refusing to start.
        if (_autoplayBlocked) TapToPlayOverlay(onPlay: _playAfterAutoplayBlock),
        // Last, so it draws over the chrome rather than under it, and
        // outside `GestureControls` so a tap on the panel is not a seek.
        // `StatsMetrics.resolve` returns null on a viewport too short to
        // hold even the compact panel, which is when drawing nothing beats
        // drawing over the scrubber.
        if (_statsCollector != null) _buildStatsPanel(),
      ],
    );
  }

  /// Whether a previous episode exists in the current season's episode list.
  bool get _hasPreviousEpisode =>
      _seasonEpisodes != null &&
      _currentEpisodeIndex != null &&
      _currentEpisodeIndex! > 0;

  /// Whether a next episode exists in the current season's episode list.
  bool get _hasNextEpisode =>
      _seasonEpisodes != null &&
      _currentEpisodeIndex != null &&
      _currentEpisodeIndex! < _seasonEpisodes!.length - 1;

  Widget _buildStatsPanel() {
    final collector = _statsCollector;
    if (collector == null) return const SizedBox.shrink();

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
                final statsContext = _statsContext();
                return StatsPanel(
                  sample: sample,
                  context: statsContext,
                  metrics: metrics,
                  onCopy: metrics.showButtons
                      ? () => _copyStats(sample, statsContext)
                      : null,
                  onClose: metrics.showButtons
                      ? () => unawaited(
                            ref
                                .read(statsOverlayEnabledProvider.notifier)
                                .set(false),
                          )
                      : null,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The link path playback is on right now, or null while a p2p connection
  /// has no peer path. Read at the moment of use: the path can change
  /// mid-play, and a relay switch is exactly when a stall is likely.
  ///
  /// Plain HTTP returns before reading the p2p status, so an HTTP session
  /// never builds the p2p providers just to learn it is not using them.
  LinkPath? _currentLinkPath() {
    if (!ref.read(conn.connectionProvider).isP2PMode) return LinkPath.http;
    return linkPathFor(
      isP2P: true,
      type: ref.read(p2pStatusNotifierProvider).peerConnectionType,
    );
  }

  StatsContext _statsContext() {
    final player = _player;
    final status = ref.read(p2pStatusNotifierProvider);
    final isP2P = ref.read(conn.connectionProvider).isP2PMode;
    final summary = ConnectionSummary.from(
      isP2P: isP2P,
      type: status.peerConnectionType,
      isInitialized: status.isInitialized,
    );
    return buildStatsContext(
      plan: _plan,
      isDownloadedSource: _isDownloadedSource,
      selectedQuality: _selectedQuality,
      effectiveQuality: _effectiveQuality,
      duration: _timeline.resolveDuration(
        player?.state.duration ?? Duration.zero,
      ),
      lastFallback: _lastFallback,
      knownFailures: _planInputs?.knownFailures ?? const {},
      sourceHeight: _planInputs?.sourceHeight,
      sourceCodec: _sourceCodec(_planInputs),
      sourceBitrateKbps: _planInputs?.fileBitrateKbps,
      sourceContainer: _sourceContainer(_planInputs),
      videoTrack: player?.state.track.video,
      audioTrack: player?.state.track.audio,
      linkLabel: '${summary.label} - ${status.connectedPeersCount} peer'
          '${status.connectedPeersCount == 1 ? '' : 's'}',
      linkHealthy: !status.isRelayConnected,
      recentStall: _planInputs?.recentStall,
      now: DateTime.now(),
    );
  }

  /// The first candidate's video codec, or null when there is no plan or
  /// no candidate names one.
  ///
  /// A plain loop rather than `candidates.map((c) => c.videoCodec)
  /// .firstWhere((c) => c != null, orElse: () => null)`: that one-liner
  /// does typecheck and behave correctly (both "no match" and "found
  /// null" collapse to the same `orElse: () => null`), but it reads as
  /// more clever than the job needs.
  String? _sourceCodec(PlanInputs? inputs) {
    if (inputs == null) return null;
    for (final candidate in inputs.candidates) {
      if (candidate.videoCodec != null) return candidate.videoCodec;
    }
    return null;
  }

  /// The container implied by the first candidate's MIME type, matching
  /// [_sourceCodec]'s "first candidate describes the source file" reading
  /// (the same one `FileShape.fromCandidates` relies on for the failure
  /// memory's key).
  ///
  /// The base type before any `;` is one of the fixed set
  /// `CodecString.build_mime_type/3` emits server-side
  /// (`lib/mydia/streaming/codec_string.ex`), so this mirrors that mapping
  /// rather than inventing one. `video/mp4` covers three source extensions
  /// there (mp4, m4v, mov); the candidate does not say which one the file
  /// actually was, so all three read as "mp4". Anything unrecognised (or
  /// no plan at all) is null, which the Source row already omits
  /// gracefully.
  String? _sourceContainer(PlanInputs? inputs) {
    if (inputs == null || inputs.candidates.isEmpty) return null;
    final baseType = inputs.candidates.first.mime.split(';').first.trim();
    return switch (baseType) {
      'video/mp4' => 'mp4',
      'video/x-matroska' => 'mkv',
      'video/webm' => 'webm',
      'video/mp2t' => 'ts',
      'video/x-msvideo' => 'avi',
      _ => null,
    };
  }

  Future<void> _copyStats(StatsSample sample, StatsContext stats) async {
    final version = ref.read(updateProvider).currentVersion;
    try {
      await Clipboard.setData(
        ClipboardData(
          text: statsClipboardText(sample, stats, appVersion: version),
        ),
      );
    } catch (e) {
      // `onPressed` is fire-and-forget, so an uncaught failure here would
      // reach nothing the viewer can see.
      debugPrint('[PlayerScreen] Could not copy stats: $e');
      _showToast('Could not copy stats', kind: ToastKind.error);
      return;
    }
    _showToast('Stats copied', kind: ToastKind.success);
  }

  Widget _buildError() {
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
              _error!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[400],
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _initializePlayer,
            child: const Text('Retry'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  /// Show the cast device picker dialog, then hand the selected device to
  /// [CastSessionManager] to resolve a route and start playback.
  Future<void> _showCastDevicePicker() async {
    final device = await showCastDevicePicker(context);
    if (device == null || !mounted) return;

    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      final player = _player;
      final startPosition =
          player == null ? null : _timeline.toReal(player.state.position);

      final offeredSubtitles = _castSubtitleTracks();
      final localSelection = _selectedSubtitleTrack;
      // The one entry point that pre-selects: a viewer watching with
      // subtitles on and tapping cast keeps them on — but only when that
      // track is actually among the ones being offered. `_castSubtitleTracks`
      // drops undeliverable tracks (PGS, VobSub); a viewer watching one of
      // those locally and then casting must not send an id for a track the
      // receiver was never offered. `CastSessionManager` already treats an
      // unmatched id as off, but sending one we know won't match is
      // incoherent regardless of what the manager does with it.
      final selectedSubtitleTrackId = localSelection != null &&
              offeredSubtitles.any((t) => t.trackId == localSelection.id)
          ? localSelection.id
          : null;

      await pushToRemoteTarget(
        startCast: () => manager.startCast(
          device: device,
          request: CastLaunchRequest(
            fileId: widget.fileId,
            mediaId: widget.mediaId,
            mediaType: widget.mediaType,
            showId: widget.showId,
            title: widget.title ?? 'Untitled',
            startPosition: startPosition,
            // The receiver cannot work this out for itself: Mydia's HLS
            // playlists carry no `#EXT-X-ENDLIST` until FFmpeg finishes, so a
            // Chromecast reports `duration: -1` for the whole session. Hand it
            // the runtime the server already told us (`_totalDuration`, set
            // from the candidates metadata), falling back to whatever the
            // local player managed to work out.
            duration: _knownCastDuration(),
            subtitles: offeredSubtitles,
            selectedSubtitleTrackId: selectedSubtitleTrackId,
          ),
        ),
        stopLocal: () async => await _player?.pause(),
      );

      if (mounted) {
        showToast(context, 'Casting to ${device.name}');
      }
    } on CastBackendException catch (e) {
      if (!mounted) return;
      showCastErrorToast(context, e,
          ref: ref, isMydiaTarget: device.protocol == CastProtocolKind.mydia);
    } catch (e) {
      // Anything that isn't a CastBackendException: the session manager
      // itself resolving (Hive, GraphQL client), or a non-typed failure from
      // _setLanAccess/_store.save inside startCast. Without this, those
      // failures would close the picker with no toast and no log.
      debugPrint('[PlayerScreen] Unexpected error starting cast: $e');
      if (!mounted) return;
      showToast(context, 'Failed to start casting: $e', kind: ToastKind.error);
    }
  }

  /// What the player screen shows while the media is on a receiver.
  ///
  /// Deliberately inert: every control lives in `CastMiniController`, which is
  /// mounted over this screen by `app.dart`. Duplicating them here is the
  /// confusion this replaced — two surfaces showing the same title, device,
  /// play/pause and stop, with the bar clipping the remote's stop button.
  ///
  /// [session] rather than just the device: `isCastingProvider` stays true for
  /// a [CastSession] that has gone stale (its `mediaInfo` survives the drop —
  /// see `CastSession.copyWith`), and this is the app's single largest
  /// `Icons.cast_connected` glyph. Rendering it over a connection that no
  /// longer exists is exactly the false "connected" claim this feature exists
  /// to eliminate, so a stale session gets the same outline glyph and "Lost
  /// connection" wording as `CastMiniController`'s stale row, not a claim of
  /// a live cast.
  Widget _buildCastPlaceholder(CastSession session) {
    final device = session.device;
    final isStale = session.isStale;

    // The one control this screen does own while casting. It is not the
    // duplication the doc comment above warns about: `CastMiniController`
    // has no skip, so there is no second copy to disagree with, and the
    // alternative is the feature simply not existing on a TV.
    //
    // Withheld over a stale session for the reason the glyph goes outline —
    // the receiver is gone, and a control that silently does nothing is that
    // same false "connected" claim wearing a different hat.
    final castPosition = session.mediaInfo?.position ?? Duration.zero;
    final skipSegment = isStale ? null : _segmentAt(castPosition);
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
                  widget.title ?? 'Untitled',
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
              onSkip: (target) => _castSeekToReal(target.end),
              metrics: panelMetrics,
            ),
          ),
        Positioned(
          top: 8,
          left: 8,
          child: SafeArea(
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/');
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The item's runtime, from the most trustworthy source available.
  ///
  /// A Chromecast reports `duration: -1` for a Mydia HLS session, because the
  /// playlist carries no `#EXT-X-ENDLIST` until FFmpeg finishes. Hand it the
  /// figure the server gave us instead.
  Duration? _knownCastDuration() {
    final player = _player;
    if (player == null) return _timeline.totalDuration;

    final resolved = _timeline.resolveDuration(player.state.duration);
    return resolved > Duration.zero ? resolved : null;
  }
}

/// Pure `PageUp`/`PageDown` episode-navigation key handling, extracted from
/// `_PlayerScreenState._handleKeyEvent` so it can be unit-tested directly.
///
/// `_handleKeyEvent`'s other cases (`space`, arrows, `keyF`, `keyM`,
/// `escape`) all reach directly into a real media_kit [Player] or call
/// `setState`/native fullscreen APIs, and `PlayerScreen` itself is a
/// `ConsumerStatefulWidget` that creates its own real [Player] and depends on
/// Riverpod/GraphQL providers with no existing test harness — pumping the
/// full screen to test one `switch` case is impractical. This case is the
/// one exception: it only needs two booleans and two callbacks, so it is
/// pulled out as a free function that takes those as parameters instead of
/// closing over `State` fields, making it directly testable with a
/// synthetic [KeyEvent] and no widget tree at all.
///
/// Mirrors exactly what the in-bar previous/next-episode buttons do
/// (`TransportSurface`'s `onPreviousEpisode`/`onNextEpisode`, gated the same
/// way by [hasPreviousEpisode]/[hasNextEpisode]) — this key handler is a
/// fallback for when those buttons aren't reachable (see the call site's own
/// comment), not a separate, independently-gated feature.
@visibleForTesting
KeyEventResult handleEpisodeNavKey(
  KeyEvent event, {
  required bool hasPreviousEpisode,
  required bool hasNextEpisode,
  required VoidCallback onPreviousEpisode,
  required VoidCallback onNextEpisode,
}) {
  if (event is! KeyDownEvent) {
    return KeyEventResult.ignored;
  }

  switch (event.logicalKey) {
    case LogicalKeyboardKey.pageUp:
      if (hasPreviousEpisode) {
        onPreviousEpisode();
      }
      return KeyEventResult.handled;

    case LogicalKeyboardKey.pageDown:
      if (hasNextEpisode) {
        onNextEpisode();
      }
      return KeyEventResult.handled;

    default:
      return KeyEventResult.ignored;
  }
}

/// The countdown's `onElapsed` callback, bound so a fire is always marked
/// as automatic.
///
/// A tear-off of `_playNextEpisode` would pass `fromAutoCountdown: false`
/// (the default), which is exactly the regression this helper exists to
/// prevent: after a dismiss, an elapsed countdown would navigate. Tests
/// pin this binding independently of mounting `PlayerScreen`.
@visibleForTesting
VoidCallback bindUpNextCountdownElapsed(
  void Function({bool fromAutoCountdown}) playNext,
) =>
    () => playNext(fromAutoCountdown: true);

/// media_kit's current audio track list mapped onto the app's own model,
/// together with the reverse lookup needed to hand a chosen track back to
/// media_kit.
@visibleForTesting
class AudioTrackDetection {
  const AudioTrackDetection({required this.tracks, required this.byId});

  /// Selectable tracks, in the order media_kit reports them. Never contains
  /// the `auto`/`no` sentinels.
  final List<app_models_audio.AudioTrack> tracks;

  /// [app_models_audio.AudioTrack.id] to the media_kit track it came from.
  /// `_showAudioSelector` passes the resolved value to `setAudioTrack`, so a
  /// missing entry silently no-ops the user's choice.
  final Map<String, AudioTrack> byId;
}

/// Maps media_kit's audio tracks onto the app's model.
///
/// Extracted as a free function so the mapping can be unit-tested without a
/// live `Player` — see [shouldRestartForSeek]'s dartdoc for why one cannot be
/// constructed under `flutter test`.
///
/// Which track counts as the default comes from media_kit's own `isDefault`
/// flag, which carries the container's disposition. Position is only the
/// fallback, for files that flag nothing: a dual-language release can order
/// its tracks one way and flag another, and picking by position alone
/// mislabels those.
@visibleForTesting
AudioTrackDetection detectAudioTracks(List<AudioTrack> mkTracks) {
  final tracks = <app_models_audio.AudioTrack>[];
  final byId = <String, AudioTrack>{};

  for (final mkTrack in mkTracks) {
    // Skip the "auto" and "no" sentinel tracks
    if (mkTrack == AudioTrack.auto() || mkTrack == AudioTrack.no()) continue;

    tracks.add(
      app_models_audio.AudioTrack(
        id: mkTrack.id,
        language: mkTrack.language ?? 'und',
        title: mkTrack.title,
        isDefault: mkTrack.isDefault ?? false,
      ),
    );
    byId[mkTrack.id] = mkTrack;
  }

  if (tracks.isNotEmpty && !tracks.any((t) => t.isDefault)) {
    final first = tracks.first;
    tracks[0] = app_models_audio.AudioTrack(
      id: first.id,
      language: first.language,
      title: first.title,
      isDefault: true,
    );
  }

  return AudioTrackDetection(tracks: tracks, byId: byId);
}

/// Reports media_kit's track list every time it is revised.
///
/// mpv discovers tracks asynchronously while it probes the file, and revises
/// the list afterwards, so sampling it once at a fixed moment after `open()`
/// races the probe. On a slow enough source the sample lands before any
/// track exists and the selectors are left permanently empty. Driving
/// detection off the stream instead means a late arrival still reaches the
/// UI.
///
/// `player.stream.tracks` is a plain broadcast stream with no replay, so
/// callers must subscribe before opening the media and still run a detection
/// pass afterwards to cover anything emitted in between.
/// A picked subtitle track made loadable, or null with the line to show the
/// viewer instead. See `_resolveMediaKitSubtitleTrack`.
typedef _ResolvedSubtitle = ({SubtitleTrack? track, String failureMessage});

/// A viewer pick waiting in [_PlayerScreenState._subtitlePreferenceWrite] to
/// be written back, together with everything that identifies the choice it
/// is.
///
/// The track alone is not enough, because the queue can outlive the attempt
/// that filled it. [mediaKey] is the file the pick was made on, [fileId] is
/// the file the mutation has to name, and [generation] is the selection
/// generation that pick ran under -- see `_writeSubtitlePreference`, which
/// sends this only while all three still describe what is on screen.
typedef _QueuedSubtitlePreference = ({
  app_models.SubtitleTrack? track,
  String mediaKey,
  String fileId,
  int generation,
});

@visibleForTesting
StreamSubscription<Tracks> watchTracks(
  Stream<Tracks> tracks,
  void Function(Tracks tracks) onTracks,
) {
  return tracks.listen(onTracks);
}

/// Converts the wire's 0.0-1.0 volume level to media_kit's 0-100 scale, used
/// by [_PlayerScreenState.setVolume]. Clamps out-of-range input rather than
/// trusting the caller — a remote peer, not this app, decides what crosses
/// the wire.
///
/// Extracted as a free function, alongside its inverse
/// [playerVolumeToRemoteControlVolume] and [remoteControlMuteVolume], so the
/// 0-1/0-100 conversion `_PlayerScreenState`'s `RemotePlayerBinding`
/// implementation depends on is directly unit-tested rather than only
/// exercised indirectly through `RemoteTargetController`'s own tests, which
/// drive a hand-written fake binding and never reach this arithmetic. See
/// [shouldRestartForSeek]'s dartdoc for why a real `Player` cannot stand in
/// for it under `flutter test` instead.
@visibleForTesting
double remoteControlVolumeToPlayerVolume(double level) =>
    level.clamp(0.0, 1.0) * 100;

/// The inverse of [remoteControlVolumeToPlayerVolume], for reporting the
/// current volume back out through [_PlayerScreenState.describe].
@visibleForTesting
double playerVolumeToRemoteControlVolume(double playerVolume) =>
    playerVolume / 100;

/// media_kit has no separate mute flag on this screen, only volume: muting
/// snaps it to 0 and unmuting snaps it to full, mirroring
/// `_handleKeyEvent`'s existing `keyM` case exactly rather than restoring
/// whatever was set before muting, which would need new state this screen
/// does not keep.
@visibleForTesting
double remoteControlMuteVolume(bool muted) => muted ? 0.0 : 100.0;

/// Whether [_PlayerScreenState.describe] should report the player as muted.
/// Paired with [remoteControlMuteVolume] rather than a tracked mute flag:
/// muted is exactly "volume is 0" (including when there is no player at
/// all, since `null == 0` is false).
@visibleForTesting
bool isPlayerVolumeMuted(double? playerVolume) => playerVolume == 0;

/// Finds the element of [tracks] whose [idOf] equals [id], or null when
/// nothing matches — the case every `selectTrack` branch in
/// [_PlayerScreenState] must silently no-op for rather than throw, since
/// `id` names a track a *remote peer* chose, which this screen never
/// validated before it arrived.
@visibleForTesting
T? findTrackById<T>(
  List<T> tracks,
  String id, {
  required String Function(T track) idOf,
}) =>
    tracks.where((track) => idOf(track) == id).firstOrNull;

/// Maps [_PlayerScreenState]'s own loading/error flags and the `Player`'s
/// state onto the wire's [FlutterPlaybackState], for
/// [_PlayerScreenState.describe] by way of
/// [_PlayerScreenState._remoteControlPlaybackState].
///
/// Order is significant, checked in this priority: [hasError] wins over
/// everything else — a player still decoding through a stream error is not
/// meaningfully "playing". [isLoading]/`!hasPlayer` come next because this
/// screen's own `_isLoading`/`_error` fields describe *screen* phases where
/// `Player.state` may not exist yet or may be stale from a session this
/// screen already tore down, so they are trusted ahead of whatever the
/// `Player` itself reports. [buffering] and [completed] are checked before
/// [playing] because media_kit can report `playing: true` while buffering,
/// and after the file has already ended.
@visibleForTesting
FlutterPlaybackState remoteControlPlaybackState({
  required bool hasError,
  required bool isLoading,
  required bool hasPlayer,
  required bool buffering,
  required bool completed,
  required bool playing,
}) {
  if (hasError) return FlutterPlaybackState.error;
  if (isLoading || !hasPlayer) return FlutterPlaybackState.loading;
  if (buffering) return FlutterPlaybackState.buffering;
  if (completed) return FlutterPlaybackState.ended;
  return playing ? FlutterPlaybackState.playing : FlutterPlaybackState.paused;
}

/// Casts to a remote target, stopping local playback only once the receiver
/// has confirmed the load — never before, and never at all if it refuses.
///
/// This ordering is what makes "Push" (spec term: capture position and
/// track selections, `Hello`, `LoadContent`, only then stop locally)
/// non-destructive. An unreachable receiver or a rejected codec must never
/// cost the viewer their place in a film: when [startCast] throws, [stopLocal]
/// simply never runs, and whatever [_PlayerScreenState._player] was doing
/// keeps doing it. The caller's own `catch` (see `_showCastDevicePicker`) is
/// what turns that exception into a toast instead of a crash.
///
/// Extracted as a free function for the same reason as [applyQualityChoice]
/// and [shouldRestartForSeek]: proving this ordering under `flutter test`
/// needs to observe whether local playback kept running, and this suite can
/// never construct a real, playing media_kit `Player` to observe that
/// against (see [shouldRestartForSeek]'s dartdoc) — so the ordering itself
/// is what gets pinned instead, independent of any real player.
@visibleForTesting
Future<void> pushToRemoteTarget({
  required Future<void> Function() startCast,
  required Future<void> Function() stopLocal,
}) async {
  await startCast();
  await stopLocal();
}
