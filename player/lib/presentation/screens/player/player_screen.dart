import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import '../../../core/auth/auth_status.dart';
import '../../../core/connection/connection_provider.dart' as conn;
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/invalidation_rules.dart';
import '../../../core/graphql/watch/watcher_registry.dart';
import '../../../core/player/audio_language.dart';
import '../../../core/player/codec_support.dart';
import '../../../core/player/progress_service.dart';
import '../../../core/playback/playback_progress_providers.dart';
import '../../../core/playback/playback_progress_store.dart';
import '../../../core/utils/file_utils.dart' as file_utils;
import '../../../core/utils/web_lifecycle.dart' as web_lifecycle;
import '../../../core/player/fullscreen/fullscreen_controller.dart';
import '../../../core/player/input_capabilities.dart';
import '../../../core/player/platform_features.dart';
import '../../../core/player/playback_error.dart';
import '../../../core/player/stream_timeline.dart';
import '../../../core/player/web_session_limits.dart';
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
import '../../widgets/cast_button.dart';
import '../../widgets/cast_device_picker.dart';
import '../../widgets/video_controls/cast_chrome_icon.dart';
import '../../widgets/video_controls/custom_video_controls.dart';
import '../../widgets/video_controls/playback_chrome.dart';
import '../../widgets/video_controls/skip_segment_button.dart';
import '../../widgets/video_controls/chrome_panel.dart';
import '../../widgets/tap_to_play_overlay.dart';
import '../../widgets/video_controls/up_next_countdown.dart';
import '../../widgets/video_controls/up_next_policy.dart';
import '../../widgets/video_controls/up_next_prompt.dart';
import '../../../domain/models/audio_track.dart' as app_models_audio;
import '../../../domain/models/media_segment.dart';
import '../../../domain/models/quality_delivery_subtitle.dart';
import '../../../domain/models/quality_rung.dart';
import '../../../domain/models/subtitle_candidate.dart';
import '../../../domain/models/subtitle_track.dart' as app_models;
import '../../../domain/models/cast_device.dart';
import '../../../domain/models/download.dart';
import '../../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../../graphql/queries/movie_detail.graphql.dart';
import '../../../graphql/queries/episode_detail.graphql.dart';
import '../../../graphql/queries/media_segments.graphql.dart';
import '../../../graphql/queries/season_episodes.graphql.dart';
import '../../../graphql/mutations/start_streaming_session.graphql.dart';
import '../../../graphql/mutations/start_streaming_session_legacy.graphql.dart';
import '../../../graphql/mutations/end_streaming_session.graphql.dart';
import '../../../graphql/mutations/set_audio_language_preference.graphql.dart';
import '../../../graphql/queries/streaming_candidates.graphql.dart';
import '../../../graphql/queries/subtitle_content.graphql.dart';
import '../../../graphql/queries/subtitle_search.graphql.dart';
import '../../../graphql/mutations/download_subtitle.graphql.dart';
import '../../../graphql/schema.graphql.dart';
import '../../../core/p2p/media_proxy.dart';
import '../../../core/p2p/media_proxy_factory.dart';
import '../../../core/window/desktop_window.dart';
import '../../../core/window/player_window_sizer.dart';
import '../../../core/player/hls_strategy_selection.dart';
import '../../../core/player/resume_plan.dart';
import '../../../core/remote/remote_control_intent.dart';
import '../../../core/remote/remote_target_controller.dart';
import '../../../native/lib.dart';
import '../settings/settings_controller.dart';
import 'subtitle_track_builder.dart';

export '../../../core/player/resume_plan.dart'
    show
        kMinResumeThresholdSeconds,
        kEndOfMediaThresholdSeconds,
        kWatchedThreshold,
        shouldOfferResume;

/// How far past the transcoded window a seek may land before the HLS session
/// is torn down and restarted at the new position.
///
/// Restarting is expensive and visible: it ends the session, disposes the
/// player, makes two GraphQL round trips, starts a fresh FFmpeg and waits for
/// a playlist, all behind a spinner. Early in a session only a few seconds
/// have been transcoded — and that is exactly the state playback returns to
/// after every resume and every restart — so without a tolerance a single
/// 10-second arrow-key skip or double-tap-forward would overshoot the
/// seekable end and pay that cost, over and over, potentially looping.
///
/// Within this tolerance the seek is clamped to the seekable end instead,
/// which is what the player did before restarts existed. Only a deliberate
/// jump well beyond what has been transcoded is worth a restart.
const Duration kSeekRestartTolerance = Duration(seconds: 30);

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
  /// strip a second time, pushing the media_kit `Video` down by 28pt and
  /// putting a black band above every video — `NativePlayerWindowSizer` then
  /// snaps the window to the video's aspect ratio *without* that 28pt, so
  /// media_kit adds side pillars too. `playback_chrome.dart`'s own
  /// `SafeArea` is what insets the on-screen chrome (back pill, transport)
  /// instead; it is unaffected by this.
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
        return ArrowIntent.seekBackward;
      case LogicalKeyboardKey.arrowRight:
        return ArrowIntent.seekForward;
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
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    implements RemotePlayerBinding {
  Player? _player;
  VideoController? _videoController;
  ProgressService? _progressService;

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

  /// True for the entire duration of [_restartSessionAt], including while it
  /// awaits — `_player` is not set to null until partway through that method,
  /// so [seekToReal] cannot rely on the null check alone to reject a seek
  /// that arrives mid-restart. Nothing disables the keyboard/gesture
  /// callbacks that reach `seekToReal` while the loading spinner is showing,
  /// so without this flag a second seek near the transcoded boundary would
  /// independently reach the same restart decision on the still-live old
  /// player and start a second, concurrent `_initializePlayer()` — leaking
  /// an HLS session and its FFmpeg process. Always cleared, including on the
  /// error paths, by [trackRestartInFlight].
  bool _isRestartingSession = false;
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

  /// The tracks actually offered to the viewer, and the list
  /// `subtitleTrackCount` gates the subtitle button on. Derived: never
  /// assigned outside [_applySubtitleTracks].
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
  /// a cancel. `null` means "Off is the most recently requested state",
  /// same as [_selectedSubtitleTrack]'s `null`; both start `null` because
  /// nothing has been requested yet.
  ///
  /// Written once, up front, to whatever a call is requesting, and — this
  /// is the part a second review round found missing — reverted by
  /// [_resetPendingSubtitleSelection] on every exit that concludes without
  /// applying. Left un-reverted, a failed fetch stuck this at the track
  /// that had just failed, so re-tapping that exact track (the natural
  /// response to a "could not load, try again" snackbar) matched this
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
  app_models.SubtitleTrack? _pendingSubtitleSelection;

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

  // Mapping from app model track IDs to media_kit track objects
  Map<String, AudioTrack> _mediaKitAudioTrackMap = {};
  Map<String, SubtitleTrack> _mediaKitSubtitleTrackMap = {};

  // Whether current playback is direct play (vs HLS)
  bool _isDirectPlay = false;

  /// The rung in effect, or null before anything has settled one for this
  /// playback.
  ///
  /// Null is what makes secure storage a *seed* rather than a channel.
  /// [_resolveQualityForFile] consults storage only while this is null; once
  /// a rung is settled, every later re-initialization — a quality change, a
  /// seek past the transcoded window, the next episode — carries this value
  /// forward. A viewer's choice therefore reaches the restart it triggers in
  /// memory, and never has to survive a round trip through a platform
  /// channel that can fail. [_resumeOverrideSeconds] hands the position
  /// across the same restart for the same reason.
  QualityRung? _settledQuality;

  /// The rung the viewer chose, which is what gets requested.
  QualityRung get _selectedQuality => _settledQuality ?? QualityRung.original;

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

  /// Set when this server rejected the maxHeight argument, meaning it
  /// predates height support. Rungs still work through maxBitrate alone;
  /// they just land at whatever resolution the old server picks. Sticky for
  /// the widget's lifetime so the detection costs one extra round trip per
  /// session rather than one per request.
  bool _serverLacksHeightSupport = false;

  // HLS session tracking for cleanup
  String? _hlsSessionId;

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

  /// Handle on the OSD's shown or hidden state, so `_handleKeyEvent` can
  /// decide what an arrow press means and reveal the chrome on demand.
  final ChromeVisibilityController _chromeVisibility =
      ChromeVisibilityController();

  /// Fullscreen state, owned by the controller and sourced from platform
  /// events. Deliberately not a local bool: the previous field was flipped
  /// optimistically and never learned that the platform had refused, which is
  /// why the button reported "exit fullscreen" over an inline video on
  /// iPhone Safari.
  final FullscreenController _fullscreen = FullscreenController();

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

  @override
  void initState() {
    super.initState();
    _invalidator = ref.read(invalidatorProvider);
    _mediaProxy = ref.read(mediaProxyProvider);
    _remoteTargetController = ref.read(remoteTargetControllerProvider);
    _remoteTargetController.attachPlayer(this);

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
    final windowSizer = createPlayerWindowSizer();
    _windowSizer = windowSizer;
    unawaited(windowSizer.attach());

    _loadAutoSkipPreference();
    _fullscreen.isFullscreen.addListener(_onFullscreenChanged);
    _initializePlayer();

    // Force landscape orientation on mobile devices. Skipped on a television,
    // which is already landscape and has nothing to rotate.
    if (PlayerScreen.wantsForcedLandscape(
      isMobile: PlatformFeatures.isMobile,
      directionalPrimary: InputCapabilities.directionalPrimary,
    )) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    // Register beforeunload handler for web to terminate HLS session on tab close
    if (kIsWeb) {
      web_lifecycle.registerBeforeUnload(_terminateHlsSession);
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Downloads cannot be cast — playing on this device.'),
        ));
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
          showCastErrorSnackBar(context, e, ref: ref);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed to start casting: $e'),
            backgroundColor: Colors.red,
          ));
        }
      }
      return false;
    }
  }

  Future<void> _initializePlayer() async {
    _resetSegmentsIfMediaChanged();

    // Cleared up front so the branches that never reach a streaming session —
    // offline, and already-downloaded — cannot inherit a ladder derived for a
    // previous one. Both return early below, and a local file has no session
    // to restart and nothing to switch between, so Original alone is right
    // for them and hides the control.
    _qualityLadder = const [QualityRung.original];
    _effectiveQuality = null;
    _originalDeliverySubtitle = kOriginalTranscodeSubtitle;

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
            if (!mounted) return null;
            return showResumeDialog(context, saved, total);
          },
        );
        if (plan == null) return;

        if (await _castToTargetIfSet(plan, fileId: widget.fileId)) return;

        await _openPlayerAndStart(offlinePath, {}, plan: plan);
        return;
      }

      // In online mode, if content is downloaded locally, play it directly
      // without requiring network for streaming
      if (downloadedMedia != null && !kIsWeb) {
        final localPath =
            await _resolveDownloadedFilePath(downloadedMedia.filePath);
        if (localPath != null) {
          debugPrint('Playing from local file: $localPath');

          // Try to initialize progress sync (optional - local playback
          // works even if server is unreachable)
          try {
            final graphqlClient =
                await ref.read(asyncGraphqlClientProvider.future);
            _progressService = ProgressService(graphqlClient);
            await _fetchProgressAndEpisodes(graphqlClient);
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
              if (!mounted) return null;
              return showResumeDialog(context, saved, total);
            },
          );
          if (plan == null) return;

          if (await _castToTargetIfSet(plan, fileId: widget.fileId)) return;

          await _openPlayerAndStart(localPath, {}, plan: plan);
          return;
        }
        debugPrint('Downloaded file not found, falling back to streaming');
      }

      // Online mode - initialize network services
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);

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
        debugPrint('[PlayerScreen] Media proxy serving at ${proxy.baseUrl}');
      }

      // Initialize progress service
      _progressService = ProgressService(graphqlClient);

      // Fetch saved progress and episode list for TV shows
      await _fetchProgressAndEpisodes(graphqlClient);

      // Fetch streaming candidates to determine optimal strategy
      if (mounted) {
        setState(() {
          _loadingMessage = 'Checking file compatibility...';
        });
      }

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
      var candidatesFetch = await _fetchStreamingCandidates(
        graphqlClient,
        byFile ? 'file' : mediaContentType,
        byFile ? widget.fileId : widget.mediaId,
      );

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

      await _resolveQualityForFile(candidatesResult);
      _rememberOriginalDeliverySubtitle(candidatesResult?.candidates);

      // Determine if direct play is possible.
      //
      // A chosen rung vetoes direct play. Direct play hands the file over
      // untouched, so there is no encoder to give a cap to — honouring the
      // choice means going through a transcoded HLS session instead. Original
      // is the only rung with nothing to ask for, so it is the only one that
      // leaves the cheap path available.
      final canDirect = !kIsWeb &&
          candidatesResult != null &&
          _canDirectPlay(candidatesResult.candidates) &&
          _selectedQuality.isOriginal;

      _isDirectPlay = canDirect;

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
          if (!mounted) return null;
          return showResumeDialog(context, saved, total);
        },
      );
      if (plan == null) return;

      if (await _castToTargetIfSet(plan, fileId: playFileId)) return;

      String mediaSource;
      Map<String, String> httpHeaders = {};

      if (canDirect) {
        // Direct play path (native only)
        debugPrint('[PlayerScreen] Direct play for file_id=$playFileId');

        if (isP2PMode) {
          mediaSource =
              ref.read(mediaProxyProvider).buildDirectStreamUrl(playFileId);
        } else {
          // Get media token for URL (if available)
          final mediaTokenService =
              await ref.read(asyncMediaTokenServiceProvider.future);
          await mediaTokenService.ensureValidToken();
          final mediaToken = await mediaTokenService.getToken();

          mediaSource =
              '$serverUrl/api/v1/stream/file/$playFileId?strategy=DIRECT_PLAY';
          if (mediaToken != null) {
            mediaSource += '&token=$mediaToken';
          } else {
            httpHeaders = {'Authorization': 'Bearer $token'};
          }
        }
      } else {
        // HLS path (both web and native fallback)

        // Caught here, before a streaming session is even requested. Anything
        // past this point starts an FFmpeg transcode on the instance and pulls
        // relay bytes we pay for, so a browser that cannot play the result has
        // to be turned away first, not after.
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

        if (mounted) {
          setState(() {
            _loadingMessage = 'Starting stream...';
          });
        }

        // Determine HLS strategy from candidates
        final hlsStrategy = _pickHlsStrategy(candidatesResult?.candidates);

        // The resume decision was already made above, before the cast fork —
        // it has to be: the offset is an input to FFmpeg, not something that
        // can be seeked to once a live-style playlist is already running.
        final startPositionSeconds = plan.position.inSeconds;

        // Start HLS session via GraphQL mutation (works for both modes)
        final result = await _startSessionMutation(
          graphqlClient: graphqlClient,
          fileId: playFileId,
          hlsStrategy: hlsStrategy,
          startPositionSeconds: startPositionSeconds,
        );

        if (result.hasException) {
          throw Exception(
              'Failed to start streaming session: ${result.exception}');
        }

        final sessionData =
            Mutation$StartStreamingSession.fromJson(result.data!);
        final sessionResult = sessionData.startStreamingSession;
        if (sessionResult == null) {
          throw Exception('No session data returned from server');
        }

        _hlsSessionId = sessionResult.sessionId;
        debugPrint('[PlayerScreen] HLS session started: $_hlsSessionId');

        // Label from what the server applied, not what was asked for: a relay
        // connection clamps to kWebMaxBitrateKbps and kWebMaxHeight (3000kbps,
        // 720p) regardless of the request.
        //
        // Only a server that echoes at all gets to decide the label. The
        // legacy request does not select the echo fields, so reading them
        // there would report "no caps applied" for every rung and label a
        // capped stream Original. Null instead, which falls the label back to
        // what was requested and suppresses the clamp note — the honest
        // answer when the server never said.
        _effectiveQuality = _serverLacksHeightSupport
            ? null
            : effectiveRungLabel(
                maxHeight: sessionResult.maxHeight,
                maxBitrateKbps: sessionResult.maxBitrate,
              );

        // Use the echoed offset, not the requested one. The server clamps the
        // value, and `-ss` lands on the nearest keyframe, so the stream can
        // legitimately start earlier than asked. An older server omits the
        // field entirely, which correctly yields offset zero.
        final serverOffset = sessionResult.startPosition ?? 0;

        if (_totalDuration == null && sessionResult.duration != null) {
          _totalDuration = Duration(
            milliseconds: (sessionResult.duration! * 1000).round(),
          );
        }

        _timeline = StreamTimeline(
          startOffset: Duration(seconds: serverOffset),
          totalDuration: _totalDuration,
        );
        debugPrint('[PlayerScreen] Stream timeline: $_timeline');

        // Build HLS URL based on mode
        if (isP2PMode) {
          mediaSource =
              ref.read(mediaProxyProvider).buildHlsUrl(_hlsSessionId!);
        } else {
          mediaSource = '$serverUrl/api/v1/hls/$_hlsSessionId/index.m3u8';
        }
        debugPrint('[PlayerScreen] HLS URL: $mediaSource');

        // Wait for playlist to be ready
        // In P2P mode, proxy handles auth; in direct mode, pass bearer token
        await _waitForPlaylist(
          mediaSource,
          headers: isP2PMode ? null : {'Authorization': 'Bearer $token'},
        );
      }

      // `canDirect` is exactly the HLS/non-HLS split of this method: the HLS
      // branch above has already baked the resume decision into the
      // session's start offset, so acting on `plan` again here would
      // double-apply it via a seek on top of that offset. The direct-play
      // branch has no server-side offset to bake it into and must resume
      // with a plain seek, which is what passing `plan` through does.
      await _openPlayerAndStart(
        mediaSource,
        httpHeaders,
        plan: canDirect ? plan : ResumePlan.fromStart,
      );
    } catch (e) {
      debugPrint('Error initializing player: $e');
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

  /// Pick the best HLS strategy from streaming candidates.
  ///
  /// Delegates to [pickHlsStrategy], which reads the leading candidate as
  /// the server's compatibility verdict for this file: a leading `HLS_COPY`
  /// means `:needs_transcoding`, and `HLS_COPY` never re-encodes, so it is
  /// never a safe choice in that case. See that function's doc comment for
  /// why this is correct against both an old server and one carrying the
  /// #564 fix.
  Enum$StreamingStrategy _pickHlsStrategy(
    List<Query$StreamingCandidates$streamingCandidates$candidates>? candidates,
  ) {
    final values = candidates?.map((c) => c.strategy.toJson()).toList() ??
        const <String>[];

    return pickHlsStrategy(values) == 'HLS_COPY'
        ? Enum$StreamingStrategy.HLS_COPY
        : Enum$StreamingStrategy.TRANSCODE;
  }

  /// Rebuilds the quality ladder for the file about to play and settles which
  /// rung this playback will request.
  ///
  /// The ladder is per-file, not per-widget: it depends on the source height,
  /// and a rung chosen while watching a taller file may not exist in this
  /// one's ladder. Falling back to Original there beats requesting an
  /// upscale, which costs encode time to produce a larger, blurrier picture.
  ///
  /// The rung is *seeded* from storage and then carried in memory. Re-reading
  /// it here on every re-initialization would put a fallible platform channel
  /// on the only path carrying the viewer's choice: a swallowed write failure
  /// would make the restart negotiate the rung they just replaced, and the
  /// label would revert in front of them. See [_settledQuality].
  Future<void> _resolveQualityForFile(
    Query$StreamingCandidates$streamingCandidates? candidatesResult,
  ) async {
    _qualityLadder = deriveQualityLadder(
      sourceHeight: candidatesResult?.metadata.height,
    );

    final requested = _settledQuality ?? await _storedDefaultQuality();

    _settledQuality =
        _qualityLadder.contains(requested) ? requested : QualityRung.original;
  }

  /// The rung stored as this install's default, for the first session of a
  /// playback.
  ///
  /// Secure storage being unreadable is no reason to fail playback, and the
  /// safe answer is the cheapest one for the server. Matches how
  /// `_loadAutoSkipPreference` treats the same failure.
  Future<QualityRung> _storedDefaultQuality() async {
    try {
      final storedKey =
          await ref.read(settingsServiceProvider).getDefaultQuality();
      return QualityRung.fromStorageKey(storedKey) ?? QualityRung.original;
    } catch (e) {
      debugPrint('[PlayerScreen] Could not read default quality: $e');
      return QualityRung.original;
    }
  }

  /// Starts the streaming session, degrading gracefully on a server that
  /// predates the height cap.
  ///
  /// Mydia installs update on their own schedule and the native player ships
  /// separately from the server, so a newer player routinely meets an older
  /// one. Against such a server the current document is rejected outright —
  /// the `maxHeight` argument and the echo fields it selects are both
  /// validation errors, which fail the whole request rather than degrading —
  /// so the first failure of that shape is retried through the legacy
  /// document, which asks only for what every server since the bitrate cap
  /// has had. [_serverLacksHeightSupport] makes that a once-per-session cost
  /// rather than once per request.
  Future<QueryResult<Object?>> _startSessionMutation({
    required GraphQLClient graphqlClient,
    required String fileId,
    required Enum$StreamingStrategy hlsStrategy,
    required int startPositionSeconds,
  }) async {
    final startPosition =
        startPositionSeconds > 0 ? startPositionSeconds : null;

    // Public web (web.mydia.dev) is relay-only forever, since a browser
    // cannot hole-punch, so every byte of that session is bandwidth we pay
    // for. The instance-hosted `/player` build reaches its own origin over
    // plain HTTP and costs us nothing, so it stays uncapped. Whichever of the
    // viewer's own choice or the relay ceiling is more restrictive wins: a
    // viewer who already picked a lower rung than the cap keeps that choice
    // instead of being pushed up to it.
    final webLimits = webSessionLimits(relayed: _relayed);
    final maxBitrate =
        tighterCap(_selectedQuality.maxBitrateKbps, webLimits.maxBitrate);
    final maxHeight = tighterCap(_selectedQuality.height, webLimits.maxHeight);

    Future<QueryResult<Object?>> runLegacy() {
      return graphqlClient.mutate(
        MutationOptions(
          document: documentNodeMutationStartStreamingSessionLegacy,
          variables: Variables$Mutation$StartStreamingSessionLegacy(
            fileId: fileId,
            strategy: hlsStrategy,
            maxBitrate: maxBitrate,
            startPosition: startPosition,
          ).toJson(),
        ),
      );
    }

    if (_serverLacksHeightSupport) return runLegacy();

    final result = await graphqlClient.mutate(
      MutationOptions(
        document: documentNodeMutationStartStreamingSession,
        variables: Variables$Mutation$StartStreamingSession(
          fileId: fileId,
          strategy: hlsStrategy,
          maxBitrate: maxBitrate,
          maxHeight: maxHeight,
          startPosition: startPosition,
        ).toJson(),
      ),
    );

    if (_looksLikeMissingHeightSupport(result)) {
      debugPrint(
        '[PlayerScreen] Server does not know maxHeight; '
        'retrying without the height cap',
      );
      _serverLacksHeightSupport = true;
      return runLegacy();
    }

    return result;
  }

  /// True when the failure is this server's schema not knowing about
  /// `maxHeight`, rather than a transport, authorization, or resolver
  /// problem. Only the former is worth retrying through the legacy document.
  ///
  /// Both messages are Absinthe's verbatim validation text — see
  /// `Absinthe.Phase.Document.Validation.KnownArgumentNames` and
  /// `.FieldsOnCorrectType`. An old server emits both at once (the argument
  /// and the echoed fields arrived in the same change), so either is enough.
  /// Matching the exact phrasing rather than loose keywords keeps a genuine
  /// failure from being mistaken for version skew and silently retried.
  bool _looksLikeMissingHeightSupport(QueryResult<Object?> result) {
    final graphqlErrors = result.exception?.graphqlErrors ?? const [];
    return graphqlErrors.any((error) {
      final message = error.message;
      return message.contains('Unknown argument "maxHeight"') ||
          message.contains('Cannot query field "maxHeight"');
    });
  }

  /// Shared tail of _initializePlayer: create player, open the media, start
  /// playback.
  ///
  /// Reached by three paths, not just the HLS one: the HLS branch, the
  /// direct-play branch, and the "already downloaded, still online" branch.
  /// It no longer prompts — the resume decision is made once, upstream of
  /// every fork, by [resolveResumePlan] — it only executes [plan]. The HLS
  /// branch bakes that same decision into the session's FFmpeg start offset,
  /// the only way to resume a live-style playlist; the other two hold the
  /// entire file locally, have no server-side session to give an offset to,
  /// and seek correctly, so for them resuming is a plain [Player.seek] after
  /// the media opens.
  Future<void> _openPlayerAndStart(
    String mediaSource,
    Map<String, String> httpHeaders, {
    required ResumePlan plan,
  }) async {
    if (mounted) {
      setState(() {
        _loadingMessage = null;
      });
    }

    // Create media_kit player
    final player = Player();
    _player = player;
    _videoController = VideoController(player);
    // Hands the backend the media_kit player so the web backend can reach the
    // underlying HTMLVideoElement. A no-op on native.
    _fullscreen.attach(player);

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

    // Re-bound whenever `_initializePlayer` runs again for this screen: a
    // source switch, a session restart, or a fresh `PlayerScreen` state for
    // a new queue item. It is *not* re-bound by navigating to the next
    // episode of a season -- that reuses this same `PlayerScreen` state
    // (go_router keys the page by route pattern, not the resolved path), so
    // `initState` and this call do not run again then. The sizer cancels
    // the previous subscription itself.
    _windowSizer?.bindVideoParams(player.stream.videoParams);

    // Subscribe before opening. `player.stream.tracks` is a plain broadcast
    // stream with no replay, so a revision published between `open()` and the
    // detection pass below would otherwise be lost — which is the whole
    // failure this guards against.
    await _tracksSubscription?.cancel();
    _tracksSubscription = watchTracks(player.stream.tracks, _onTracksChanged);

    // Before `open`, deliberately: mpv chooses its audio track while loading
    // the file, so a preference applied afterwards does not reselect and the
    // viewer still starts on the wrong language. Without this, mpv falls
    // through to whatever the container flagged `default`, which on a
    // dual-language release is routinely the dub — the reason an English show
    // could open in Russian.
    await AudioLanguage.apply(player, _preferredAudioLanguages);

    // Open media
    await player.open(
      Media(mediaSource, httpHeaders: httpHeaders),
      play: false,
    );

    // Wait for player to be ready
    await Future.delayed(const Duration(milliseconds: 500));

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

    // A plain seek, not a `seekToReal`: these paths hold the whole file, so
    // the player's own coordinates already are the real ones and there is no
    // session that could need restarting.
    if (plan.resumes) {
      await player.seek(plan.position);
    }

    // The bar a position has to clear to count as playback. Zero on the HLS
    // branch, which always arrives here with `ResumePlan.fromStart` because
    // its offset went into FFmpeg's `-ss` instead, so its player-local
    // coordinates genuinely do start at zero.
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

  /// Check if the first candidate supports direct play on native.
  ///
  /// Delegates to [firstStrategyAllowsDirectPlay], which accepts only
  /// DIRECT_PLAY and REMUX. HLS_COPY is deliberately excluded even when it
  /// leads the list: the server only ever leads with HLS_COPY from its
  /// `:needs_transcoding` branch, and HLS_COPY repackages the stream
  /// without re-encoding it, so it still carries the exact video codec the
  /// server just said this device cannot decode. Treating a leading
  /// HLS_COPY as direct-playable is what let a Fire HD 10 — whose HEVC
  /// decoder is Main 8-bit only, with no Main 10 support — stream an HEVC
  /// Main 10 file untouched, straight into mpv's "Could not open codec.".
  ///
  /// This guard used to stay permissive on the theory that the native
  /// device profile the server checks against hadn't been validated on real
  /// hardware and might under-report a device's true decoder support. That
  /// hedge no longer applies: `android_codec_capabilities.dart`'s
  /// `MediaCodecList` probe against a Fire HD 10 confirmed its decoder is
  /// exactly as limited as the server's verdict assumed — `video/hevc`
  /// capped at 8-bit, `video/vp9` capped at 10-bit — so a
  /// `:needs_transcoding` verdict for a codec this device cannot decode is
  /// trustworthy, and HLS_COPY must not be used to second-guess it. REMUX
  /// stays accepted because it only repackages a codec the compatibility
  /// check already found acceptable into a different container — an
  /// unrelated case.
  bool _canDirectPlay(
    List<Query$StreamingCandidates$streamingCandidates$candidates> candidates,
  ) {
    final values = candidates.map((c) => c.strategy.toJson()).toList();
    return firstStrategyAllowsDirectPlay(values);
  }

  /// Cache the Original-rung delivery subtitle from resolved candidates.
  ///
  /// Labels only — does not change the [_canDirectPlay] playback gate.
  void _rememberOriginalDeliverySubtitle(
    List<Query$StreamingCandidates$streamingCandidates$candidates>? candidates,
  ) {
    final values = candidates?.map((c) => c.strategy.toJson()).toList() ??
        const <String>[];

    final canDirect = !kIsWeb && firstStrategyAllowsDirectPlay(values);
    final lossless = strategiesAllowLosslessDelivery(values);
    _originalDeliverySubtitle = originalDeliverySubtitle(
      canDirectPlay: canDirect,
      hasLosslessDelivery: lossless,
    );
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

  Future<void> _fetchProgressAndEpisodes(GraphQLClient client) async {
    try {
      if (widget.mediaType == 'movie') {
        // Fetch movie progress
        final result = await client.query(
          QueryOptions(
            document: documentNodeQueryMovieDetail,
            variables: Variables$Query$MovieDetail(id: widget.mediaId).toJson(),
          ),
        );

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

        if (result.data != null) {
          final episode = Query$EpisodeDetail.fromJson(result.data!).episode;
          _savedPositionSeconds = episode?.progress?.positionSeconds;
          _savedDurationSeconds = episode?.progress?.durationSeconds;
          _serverLastWatchedAt =
              DateTime.tryParse(episode?.progress?.lastWatchedAt ?? '');
          _runtimeMinutes = episode?.runtime;

          // Extract subtitle tracks from files
          _extractSubtitlesFromFiles(episode?.files);

          // If we have show and season info, fetch episode list for navigation
          if (widget.showId != null && widget.seasonNumber != null) {
            await _fetchSeasonEpisodes(client);
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching progress: $e');
    }

    // Deliberately outside the block above: segments are their own query, and
    // neither failure may take the other down with it.
    await _fetchSegments(client);
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
  /// The clearing half is insurance, not a live path. go_router derives the
  /// page key for `/player/:type/:id` from the route *pattern* rather than the
  /// resolved location, so a next-episode navigation updates this State in
  /// place instead of building a new one, and `PlayerScreen` has no
  /// `didUpdateWidget` to notice the new parameters. [_initializePlayer] is
  /// therefore never re-entered on that path and neither is this. It is
  /// written to be correct if that gap is ever closed, and until then the
  /// media key only ever transitions from null on first mount.
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
  Future<void> _fetchSegments(GraphQLClient client) async {
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
  /// Bumps [_subtitleSelectionGeneration] so any selection still in flight
  /// against the player being replaced backs off instead of applying its
  /// result to the new one; [pendingSubtitleSelectionAfterFailure] leaves
  /// the values set here alone when that superseded attempt unwinds.
  void _syncSelectedSubtitleTrack() {
    final player = _player;
    if (player == null) return;

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
    _pendingSubtitleSelection = applied;
    _subtitleSelectionGeneration++;
  }

  /// Adopt a track list media_kit published, whether sampled directly after
  /// `open()` by [_detectTracks] or delivered later by [watchTracks].
  void _onTracksChanged(Tracks tracks) {
    if (!mounted) return;

    setState(() {
      final audio = detectAudioTracks(tracks.audio);
      _audioTracks = audio.tracks;
      _mediaKitAudioTrackMap = audio.byId;
      _syncSelectedAudioTrack();

      _applySubtitleTracks(tracks.subtitle);
    });

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
  /// Returns early when the derived list is unchanged, which is
  /// load-bearing rather than an optimisation: [_syncSelectedSubtitleTrack]
  /// bumps [_subtitleSelectionGeneration], and a bump makes
  /// [shouldApplySubtitleSelection] discard whatever selection the viewer
  /// has in flight. media_kit revises its track list more than once per
  /// playback, so an unguarded rebuild would swallow a tap every time it
  /// did.
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
    );

    if (listEquals(derived, _subtitleTracks)) return;

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

  Future<void> _fetchSeasonEpisodes(GraphQLClient client) async {
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
        if (episodes != null && mounted) {
          setState(() {
            _seasonEpisodes = episodes
                .whereType<Query$SeasonEpisodes$seasonEpisodes>()
                .toList();
            _currentEpisodeIndex =
                _seasonEpisodes?.indexWhere((ep) => ep.id == widget.mediaId);
          });
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
      return;
    }

    setState(() {
      _error = playbackErrorMessage(message);
      _isLoading = false;
    });
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
    final countdown = UpNextCountdown(onElapsed: _playNextEpisode);
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

  /// Cancel the prompt and the countdown, for the rest of this file.
  void _cancelAutoPlay() {
    // Synchronous, before any setState: a dismiss that only lands next frame
    // can lose to a fire scheduled this one.
    _upNextCountdown?.cancel();
    _upNextPlayingSub?.cancel();
    _upNextPlayingSub = null;
    if (mounted) {
      setState(() {
        _showUpNext = false;
        _autoPlayCancelled = true;
      });
    }
  }

  /// Play the next episode immediately.
  void _playNextEpisode() {
    _upNextCountdown?.cancel();
    _upNextPlayingSub?.cancel();
    _upNextPlayingSub = null;

    // Re-check after the countdown: `_cancelAutoPlay` may have run between
    // the fire being scheduled and this executing.
    if (_autoPlayCancelled) return;

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
            fileIds: (episode.files ?? const <Fragment$MediaFileFragment?>[])
                .whereType<Fragment$MediaFileFragment>()
                .map((file) => file.id)
                .toList(),
            thumbnailUrl: episode.thumbnailUrl,
          ),
        )
        .toList();
  }

  /// Wait for HLS playlist to be ready with enough segments.
  ///
  /// Polls the playlist URL with exponential backoff until it has at least 3 segments.
  /// Pass [headers] for direct mode (auth); omit for P2P (proxy handles auth).
  Future<void> _waitForPlaylist(
    String playlistUrl, {
    Map<String, String>? headers,
  }) async {
    const maxRetries = 20;
    const minSegments = 3;
    const baseDelay = Duration(milliseconds: 500);
    const maxDelay = Duration(milliseconds: 3000);

    for (var i = 0; i < maxRetries; i++) {
      try {
        final response = await http.get(
          Uri.parse(playlistUrl),
          headers: headers ?? {},
        );

        if (response.statusCode == 200) {
          final playlistText = response.body;
          // Count .ts segments in playlist
          final segmentCount = '.ts'.allMatches(playlistText).length;

          if (segmentCount >= minSegments) {
            if (i > 0) {
              debugPrint(
                  '[PlayerScreen] Playlist ready after ${i + 1} attempt(s) with $segmentCount segments');
            }
            return;
          }

          final percentage = (segmentCount / minSegments * 100).round();
          debugPrint(
              '[PlayerScreen] Playlist has $segmentCount/$minSegments segments ($percentage%)');
          if (mounted) {
            setState(() {
              _loadingMessage = 'Preparing stream... $percentage%';
            });
          }
        } else {
          debugPrint(
              '[PlayerScreen] Playlist not ready (${response.statusCode}), retrying...');
          if (mounted) {
            setState(() {
              _loadingMessage =
                  'Starting transcoding... (${i + 1}/$maxRetries)';
            });
          }
        }

        // Exponential backoff with max cap
        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1))
              .clamp(
                baseDelay.inMilliseconds,
                maxDelay.inMilliseconds,
              )
              .toInt(),
        );
        await Future.delayed(delay);
      } catch (e) {
        debugPrint(
            '[PlayerScreen] Error checking playlist (attempt ${i + 1}/$maxRetries): $e');
        if (mounted) {
          setState(() {
            _loadingMessage = 'Starting transcoding... (${i + 1}/$maxRetries)';
          });
        }

        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1))
              .clamp(
                baseDelay.inMilliseconds,
                maxDelay.inMilliseconds,
              )
              .toInt(),
        );
        await Future.delayed(delay);
      }
    }

    throw Exception('Playlist not ready after maximum retry attempts');
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
    // current screen's season would tell the next PlayerScreen it is in the
    // season it just left, so its `_fetchSeasonEpisodes` would load the wrong
    // list, `_currentEpisodeIndex` would resolve to -1, and up-next would be
    // dead for that entire season. Only reachable once Task 10 lands, but
    // wrong either way.
    context.go(
      '/player/episode/$episodeId?fileId=$fileId&title=${Uri.encodeComponent(title)}&showId=${widget.showId}&seasonNumber=$seasonNumber',
    );
  }

  Future<void> _saveProgress() async {
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
          mediaId: widget.mediaId,
          mediaType: widget.mediaType,
          position: position,
          duration: duration,
          now: DateTime.now(),
        );
        return;
      }

      await recordLocalProgress(
        store: store,
        mediaId: widget.mediaId,
        mediaType: widget.mediaType,
        position: position,
        duration: duration,
        now: DateTime.now(),
      );
    }

    if (progressService == null) return;

    if (widget.mediaType == 'movie') {
      await progressService.saveMovieProgress(player, widget.mediaId);
    } else if (widget.mediaType == 'episode') {
      await progressService.saveEpisodeProgress(player, widget.mediaId);
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

    // A restart already in flight is dropped outright, not queued: the
    // player this call would act on is on its way out (see
    // `_isRestartingSession`'s dartdoc), and by the time the in-flight
    // restart finishes, this target is stale anyway — the next seek the
    // user makes will land in real coordinates against whatever the new
    // session actually starts at.
    if (_isRestartingSession) return;

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
      realTarget: clamped,
      localTarget: local,
      seekableEnd: seekableEnd,
      startOffset: _timeline.startOffset,
    )) {
      await _restartSessionAt(clamped);
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

    await player.seek(seekTarget);
  }

  /// Tears down the current HLS session and starts a new one at [target].
  ///
  /// The whole body runs under [trackRestartInFlight], which flips
  /// [_isRestartingSession] on before anything else and guarantees it is
  /// cleared afterward — including if any step throws — so [seekToReal]'s
  /// re-entrancy guard can never wedge shut for the rest of the session.
  ///
  /// [loadingMessage] names what the viewer asked for, since a restart is the
  /// same machinery behind two different requests: seeking past the
  /// transcoded window, and changing quality. Telling someone who picked
  /// 720p that the player is "Seeking" describes the implementation rather
  /// than what they did.
  Future<void> _restartSessionAt(
    Duration target, {
    String loadingMessage = 'Seeking...',
  }) async {
    await trackRestartInFlight(
      (inFlight) => _isRestartingSession = inFlight,
      () async {
        if (mounted) {
          setState(() {
            _loadingMessage = loadingMessage;
            _isLoading = true;
          });
        }

        // Persist where the user actually is before the old session goes
        // away, so an interrupted restart does not lose their place.
        await _saveProgress();

        final sessionId = _hlsSessionId;
        if (sessionId != null) {
          await _endStreamingSession(sessionId);
        }

        await _positionSubscription?.cancel();
        _positionSubscription = null;
        await _tracksSubscription?.cancel();
        _tracksSubscription = null;
        await _errorSubscription?.cancel();
        _errorSubscription = null;
        _progressService?.stopSync();
        await _player?.dispose();
        _player = null;
        _videoController = null;

        _resumeOverrideSeconds = target.inSeconds;
        await _initializePlayer();
      },
    );
  }

  /// Terminates the server-side HLS session. Safe to call more than once.
  ///
  /// Distinct from [_terminateHlsSession]: this is called mid-session, while
  /// the widget is still live, so it resolves the GraphQL client fresh via
  /// `ref.read` rather than through the captured field that dispose-time
  /// cleanup is forced to use. It also does not stop the local P2P proxy —
  /// unlike a final teardown, a seek-driven restart immediately starts a new
  /// session over the same proxy.
  Future<void> _endStreamingSession(String sessionId) async {
    debugPrint('[PlayerScreen] Terminating HLS session: $sessionId');
    try {
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);
      final result = await graphqlClient.mutate(
        MutationOptions(
          document: documentNodeMutationEndStreamingSession,
          variables: Variables$Mutation$EndStreamingSession(
            sessionId: sessionId,
          ).toJson(),
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Failed to terminate HLS session: ${result.exception}');
      } else {
        debugPrint('[PlayerScreen] HLS session terminated successfully');
      }
    } catch (e) {
      debugPrint('[PlayerScreen] Error terminating HLS session: $e');
    }
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

  /// Terminate the HLS session on the server and clean up P2P resources.
  /// This stops FFmpeg and cleans up server-side resources.
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

    // End HLS session via GraphQL (works for both modes)
    final sessionId = _hlsSessionId;
    final graphqlClient = _graphqlClient;
    if (sessionId != null && graphqlClient != null) {
      debugPrint('[PlayerScreen] Terminating HLS session: $sessionId');
      try {
        final result = await graphqlClient.mutate(
          MutationOptions(
            document: documentNodeMutationEndStreamingSession,
            variables: Variables$Mutation$EndStreamingSession(
              sessionId: sessionId,
            ).toJson(),
          ),
        );

        if (result.hasException) {
          debugPrint(
              '[PlayerScreen] Failed to terminate HLS session: ${result.exception}');
        } else {
          debugPrint('[PlayerScreen] HLS session terminated successfully');
        }
      } catch (e) {
        debugPrint('[PlayerScreen] Error terminating HLS session: $e');
      }
    } else if (sessionId != null) {
      // Extremely narrow window: disposed before `asyncGraphqlClientProvider`
      // ever resolved once. The old code awaited it fresh every time (from
      // inside `dispose()`, which is what made it unsafe); this only has
      // whatever `ref.listenManual` had captured by now.
      debugPrint(
          '[PlayerScreen] Cannot terminate HLS session $sessionId: no GraphQL client resolved yet');
    }
  }

  // Note: Subtitle tracks are now loaded via GraphQL in _fetchProgressAndEpisodes
  // The _loadSubtitleTracks method has been removed.

  /// Show subtitle track selector and apply selection via media_kit
  ///
  /// Deliberately does not set [_selectedSubtitleTrack] until the choice has
  /// actually taken effect on the player. An earlier version committed it
  /// eagerly, before the (now-async, network-bound) work that applies it;
  /// on a failed fetch that left the sheet's checkmark pointing at a track
  /// that was not actually playing, and — because the no-op guard below
  /// used to compare against [_selectedSubtitleTrack] — permanently wedged
  /// that track until the viewer picked something else. Committing only on
  /// success means a retry is just picking the same track again.
  ///
  /// Every point past the no-op guard where this method resumes from an
  /// `await` calls [_canApplySubtitleSelection] before doing anything
  /// further — touching `_player`, calling `setState` — rather than each
  /// checking its own subset of "is this still current". An earlier
  /// revision did the latter: the check after the content fetch verified
  /// generation and `mounted` but not the player, the check after the
  /// "Off" call verified generation and `mounted` too, and the final
  /// `setState` after actually applying a resolved track had no check at
  /// all — surfacing as `setState` after `dispose()`, or media_kit's
  /// `AssertionError` on a disposed `Player`, if the viewer navigated away
  /// during that specific `await`. See the Task 14 fix reports for the
  /// history; [shouldApplySubtitleSelection] and its tests are what
  /// replaced re-deriving this by hand at each site.
  ///
  /// Every one of those same exits, when it isn't a successful apply, also
  /// calls [_resetPendingSubtitleSelection]. [_pendingSubtitleSelection] is
  /// written once, up front, to whatever this call is requesting — and a
  /// version of this method that only ever wrote it and never reverted it
  /// left a failed attempt's target stuck there forever, so re-tapping the
  /// very track a "could not load" snackbar had just told the viewer to
  /// retry was silently swallowed by the no-op guard at the top of this
  /// method. See [pendingSubtitleSelectionAfterFailure] and the Task 14 fix
  /// reports for that regression's history. Those calls are backstopped by
  /// a `finally` around the whole body, which is what also covers the two
  /// `setSubtitleTrack` awaits — they can *throw* rather than return, and
  /// nothing awaits this method's future to catch it; see the comment on
  /// the `try` below.
  Future<void> _showSubtitleSelector() async {
    final outcome = await showSubtitleTrackSelector(
      context,
      _subtitleTracks,
      _selectedSubtitleTrack,
      onSearch: _searchSubtitles,
      onDownload: _downloadSubtitle,
    );

    // A dismissed sheet (barrier tap, back gesture) must leave every
    // subtitle field alone. Before [SubtitleTrackSelection] existed, the
    // sheet returned a bare `SubtitleTrack?` and a dismissal was
    // indistinguishable from choosing "Off" -- with a pick already in
    // flight, that silently cancelled it. See that sealed class for the
    // full account.
    if (outcome is SubtitleTrackSelectionCancelled) return;

    final selected = outcome is SubtitleTrackPicked ? outcome.track : null;

    if (!shouldStartSubtitleSelection(
      requested: selected,
      pending: _pendingSubtitleSelection,
      mounted: mounted,
    )) {
      return;
    }

    // Recorded before anything else below, including the no-player bailout
    // right after: this is what makes a tap whose target matches an
    // in-flight request's own target (a retry, or a cancel back to
    // whatever's still displayed as current) register as a real tap
    // instead of silently matching stale state. See
    // [_pendingSubtitleSelection]'s dartdoc for why the comparison above
    // uses this field and not [_selectedSubtitleTrack].
    _pendingSubtitleSelection = selected;

    // See [_subtitleSelectionGeneration]'s dartdoc for why this is bumped
    // unconditionally, before the no-player bailout below, rather than
    // after it.
    final generation = ++_subtitleSelectionGeneration;

    // Everything past this point runs under a `finally` that resets the
    // pending target, because two of the exits below are not `return`s.
    // Both `setSubtitleTrack` calls can *throw*: media_kit 1.2.6 raises
    // `AssertionError('[Player] has been disposed')` from both its native
    // and web backends when the player is disposed during the await, which
    // is exactly what the viewer leaving playback mid-selection does. This
    // method is fire-and-forget from `onSubtitleTap`, so such a throw
    // escapes into a future nothing awaits and every explicit reset below
    // is skipped — leaving [_pendingSubtitleSelection] pointed at a track
    // that was never applied (so re-tapping it is swallowed by the no-op
    // guard at the top of this method), or pointed at `null` while a track
    // is still applied (so re-tapping "Off" is swallowed). The `finally`
    // covers the six `return`s and both throw sites together, so "which
    // exits reset" stops being a list a later change can get wrong.
    //
    // It is a no-op on both success paths. After the content path's
    // `setState`, [_selectedSubtitleTrack] is `selected` and the request is
    // still the current generation (nothing else could have written the
    // pending target without bumping it), so the reset recomputes
    // `pending = applied = selected` — the value already there. After the
    // "Off" path's `setState` both are `null`. The reset is idempotent
    // besides, recomputing the same value from the same inputs, so running
    // it a second time on an exit that already called it changes nothing.
    try {
      final player = _player;
      if (player == null) {
        _resetPendingSubtitleSelection(generation);
        return;
      }

      if (selected == null) {
        // "Off" - disable subtitles
        await player.setSubtitleTrack(SubtitleTrack.no());
        if (!_canApplySubtitleSelection(generation)) {
          _resetPendingSubtitleSelection(generation);
          return;
        }
        setState(() => _selectedSubtitleTrack = null);
        debugPrint('[PlayerScreen] Subtitles turned off');
        return;
      }

      // Feedback while the extraction runs server-side: closing the sheet
      // and showing nothing further while that fetch is in flight is
      // exactly what let a viewer re-tap and reach the concurrency guard
      // [_canApplySubtitleSelection] exists to enforce. Shown for every
      // pick, existing or freshly downloaded -- both reach this same fetch.
      //
      // No await has run since the `mounted` check inside
      // `shouldStartSubtitleSelection` above, so this is still guaranteed
      // true -- but spelled out again directly in front of the `context`
      // use below anyway, which is what `use_build_context_synchronously`
      // requires to see it rather than trusting a call to a helper it
      // cannot look inside. Unreachable today, but routed through the same
      // reset as every other exit in this method rather than a bare
      // `return`, so it stays correct if that ever stops being true.
      if (!mounted) {
        _resetPendingSubtitleSelection(generation);
        return;
      }
      // The controller this specific call gets back is captured and closed
      // by itself below -- never `removeCurrentSnackBar()`/
      // `hideCurrentSnackBar()` after the await, which act on whatever
      // snackbar is current *at that later point*, not the one shown here.
      // A second pick (B) started while this one (A) is still in flight
      // passes `shouldStartSubtitleSelection` (different target) and shows
      // its own indicator on top of A's; when A's fetch then resolves,
      // `removeCurrentSnackBar()` would strip B's indicator while B is
      // still running, leaving the viewer mid-fetch with nothing on
      // screen -- precisely the blank-screen condition that invites the
      // re-tap `_canApplySubtitleSelection` exists to guard against.
      final loadingMessenger = ScaffoldMessenger.of(context);
      loadingMessenger.hideCurrentSnackBar();
      final loadingSnack = loadingMessenger.showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 30),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Loading subtitle...'),
            ],
          ),
        ),
      );

      final mkTrack = await _resolveMediaKitSubtitleTrack(selected);
      // `close()` is a no-op if this snackbar was already dismissed (its
      // own 30 second timeout, or a later pick's `hideCurrentSnackBar()`
      // above), so this is safe on every path.
      if (mounted) loadingSnack.close();

      // Superseded while the fetch was in flight (a re-tap, "Off", or the
      // screen/player went away): drop this result silently rather than
      // reporting a failure — or applying a success — for a choice the
      // viewer has already moved past.
      if (!_canApplySubtitleSelection(generation)) {
        _resetPendingSubtitleSelection(generation);
        return;
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
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not load that subtitle track. Try again.'),
          ),
        );
        return;
      }

      // Captured fresh here, not reused from `player` above: that capture
      // happened before the fetch's `await`, and `_restartLocalPlayback`
      // clears `_player` (without unmounting the screen) while a fetch can
      // still be in flight, so `player` could be stale by now.
      //
      // `_canApplySubtitleSelection` just confirmed `_player != null` and
      // nothing async has run since, so this cannot actually be null — but
      // `_player` is a mutable field, and Dart's flow analysis does not
      // promote non-null across a helper call the way it would a local
      // variable, so the null check still has to be spelled out here rather
      // than written as `_player!`.
      final currentPlayer = _player;
      if (currentPlayer == null) {
        _resetPendingSubtitleSelection(generation);
        return;
      }

      await currentPlayer.setSubtitleTrack(mkTrack);

      // Re-checked again, not only before this await: dispose() or
      // _restartLocalPlayback landing during *this specific* call is exactly
      // as possible as during the fetch above, and `setState` after unmount
      // throws just as surely as calling into a disposed `Player` does. This
      // is the check that was missing entirely before this fix — see the
      // dartdoc above.
      if (!_canApplySubtitleSelection(generation)) {
        _resetPendingSubtitleSelection(generation);
        return;
      }
      setState(() => _selectedSubtitleTrack = selected);
      debugPrint('[PlayerScreen] Set subtitle track: ${selected.displayName}');
    } finally {
      _resetPendingSubtitleSelection(generation);
    }
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
      appliedSelection: _selectedSubtitleTrack,
    );
  }

  /// Resolve the media_kit track for [track], fetching its body over
  /// GraphQL the first time a content-backed track is selected.
  ///
  /// Embedded tracks the media_kit player already sees in the container (in
  /// direct play) are already in [_mediaKitSubtitleTrackMap] once
  /// [_detectTracks] runs, at no fetch cost. Everything else — sidecar
  /// subtitles, and any track streaming delivers as text — has no body until
  /// this fetches one. That fetch happens here, at selection time, rather
  /// than eagerly in [_detectTracks] for every selectable track: most
  /// tracks a file offers are never selected in a given playback, and
  /// resolving `content` server-side runs an ffmpeg extraction per track.
  ///
  /// The result is cached in [_mediaKitSubtitleTrackMap] so re-selecting the
  /// same track later in the same session (or the sync in
  /// [_showSubtitleSelector] finding it already selected) does not refetch.
  Future<SubtitleTrack?> _resolveMediaKitSubtitleTrack(
    app_models.SubtitleTrack track,
  ) async {
    final cached = _mediaKitSubtitleTrackMap[track.id];
    if (cached != null) return cached;

    try {
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);
      final result = await graphqlClient.query(
        QueryOptions(
          document: documentNodeQuerySubtitleContent,
          variables: Variables$Query$SubtitleContent(
            mediaFileId: widget.fileId,
            trackId: track.id,
          ).toJson(),
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
        await player.setAudioTrack(mkTrack);
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

  /// Shows the quality picker and applies the choice by restarting the
  /// session at the current position.
  ///
  /// A rung change cannot be applied to a running session: its segments are
  /// already encoded at the old settings, and the playlist is live-style, so
  /// there is nothing to re-request. [_restartSessionAt] already handles the
  /// teardown correctly, including saving progress before the old session
  /// goes away, and guards against a concurrent restart leaking an FFmpeg
  /// process.
  Future<void> _showQualitySelector() async {
    // A restart already in flight owns the player this would act on, exactly
    // as in [seekToReal]. Dropping the request beats queueing one against a
    // session on its way out.
    if (_isRestartingSession) return;

    final previous = _selectedQuality;

    final selected = await showQualityPicker(
      context,
      _qualityLadder,
      _selectedQuality,
      originalSubtitle: _originalDeliverySubtitle,
      clampNote: _clampNote(),
    );

    // `_isRestartingSession` is re-checked, not just `mounted`: the modal
    // barrier stops taps, not the position stream. [_maybeAutoSkipSegment]
    // fires on every tick and reaches [_restartSessionAt] through
    // `seekToReal` whenever the segment end lies past what FFmpeg has
    // transcoded, so a restart can begin behind the open dialog. Applying a
    // rung on top of that would run a second teardown concurrently, leaving
    // the first session id overwritten and its FFmpeg process never ended —
    // the exact leak [trackRestartInFlight] exists to prevent.
    if (selected == null ||
        selected == _selectedQuality ||
        !mounted ||
        _isRestartingSession) {
      return;
    }

    // Read after the choice, not before it: playback carries on behind the
    // open dialog, so a position captured when the picker appeared would
    // rewind the viewer by however long they spent deciding.
    //
    // Real coordinates, not the player's: on a resumed session the player's
    // zero is [StreamTimeline.startOffset] into the media, and
    // [_restartSessionAt] takes a real target.
    final position = _timeline.toReal(_player?.state.position ?? Duration.zero);

    await applyQualityChoice(
      selected: selected,
      previous: previous,
      adopt: (rung) {
        // In memory, and only in memory. This is the channel the restart
        // below reads the rung from — [_resolveQualityForFile] carries
        // `_settledQuality` forward rather than re-reading storage.
        _settledQuality = rung;
        if (mounted) setState(() {});
      },
      remember: (rung) =>
          ref.read(settingsServiceProvider).setDefaultQuality(rung.storageKey),
      restart: (rung, {required bool isFallback}) => _restartSessionAt(
        position,
        loadingMessage: isFallback
            ? 'Returning to ${rung.label}...'
            : 'Switching to ${rung.label}...',
      ),
      stillActive: () => mounted,
      onGaveUp: (error) => setState(() {
        _error = error.toString();
        _isLoading = false;
      }),
    );
  }

  /// Explains a server-side limit when the applied rung is below the chosen
  /// one, or null when the viewer got what they picked.
  String? _clampNote() {
    final effective = _effectiveQuality;
    if (effective == null || effective == _selectedQuality) return null;
    return 'Limited to ${effective.label} by your connection';
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
        final currentPosition = _timeline.toReal(player.state.position);
        final newPosition = currentPosition - const Duration(seconds: 10);
        seekToReal(newPosition < Duration.zero ? Duration.zero : newPosition);
        _chromeVisibility.show();
        return KeyEventResult.handled;

      case ArrowIntent.seekForward:
        final currentPosition = _timeline.toReal(player.state.position);
        final duration = _timeline.resolveDuration(player.state.duration);
        final newPosition = currentPosition + const Duration(seconds: 10);
        seekToReal(newPosition > duration ? duration : newPosition);
        _chromeVisibility.show();
        return KeyEventResult.handled;

      case ArrowIntent.volumeUp:
        player.setVolume((player.state.volume + 10.0).clamp(0.0, 100.0));
        return KeyEventResult.handled;

      case ArrowIntent.volumeDown:
        player.setVolume((player.state.volume - 10.0).clamp(0.0, 100.0));
        return KeyEventResult.handled;

      case ArrowIntent.revealChrome:
        _chromeVisibility.show();
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

  /// Rebuilds so the chrome's fullscreen icon follows observed state. Cheap:
  /// the notifier only fires on a real transition.
  void _onFullscreenChanged() {
    if (mounted) setState(() {});
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
    // `detachPlayer`'s own dartdoc.
    _remoteTargetController.detachPlayer(this);

    // Order matters twice over. Stop listening *first*: in `systemUi` mode
    // `exit()` reports the transition synchronously, and the resulting
    // `setState` would assert — by the time `State.dispose` runs, the element
    // is already defunct (`StatefulElement.unmount` calls `super.unmount()`
    // before `state.dispose()`), and `markNeedsBuild` asserts on exactly that.
    // The `mounted` check in `_onFullscreenChanged` is not a guard here:
    // `_element` is nulled only after dispose returns, so it still reads true.
    // Then exit before `dispose()`, which disposes the notifier underneath it.
    _fullscreen.isFullscreen.removeListener(_onFullscreenChanged);
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

    // Restore portrait orientation on mobile devices
    if (PlatformFeatures.isMobile) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    // Save progress before disposing (fire and forget - can't await in
    // dispose), then invalidate: the second of the roughly two invalidations
    // per session. Chained, not independent fire-and-forget calls, so the
    // refetch it triggers can't race the save and pick up pre-save data.
    // `whenComplete` (not `then`) so a failing save still lets the
    // invalidation run instead of it being silently dropped.
    _saveProgress().whenComplete(_invalidateAfterPlayback);

    // Terminate HLS session on server to stop FFmpeg (fire and forget)
    _terminateHlsSession();

    // Unregister beforeunload handler on web
    if (kIsWeb) {
      web_lifecycle.unregisterBeforeUnload();
    }

    // Cancel stream subscriptions to prevent memory leaks
    _positionSubscription?.cancel();
    _tracksSubscription?.cancel();
    _errorSubscription?.cancel();

    // Cancel auto-play countdown
    _upNextCountdown?.dispose();
    _upNextPlayingSub?.cancel();
    _upNextPlayingSub = null;

    // Stop progress tracking
    _progressService?.stopSync();
    _progressService?.dispose();

    // Dispose player (VideoController is automatically disposed when player is disposed)
    _player?.dispose();
    _focusNode.dispose();
    _chromeVisibility.dispose();
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
  // it applies a track by id directly and skips their loading-snackbar and
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
        await player.setAudioTrack(mkTrack);
        if (mounted) setState(() => _selectedAudioTrack = track);

      case TrackKind.subtitle:
        if (id == null) {
          final player = _player;
          if (player == null) return;
          await player.setSubtitleTrack(SubtitleTrack.no());
          if (mounted) setState(() => _selectedSubtitleTrack = null);
          return;
        }
        final track = findTrackById(_subtitleTracks, id, idOf: (t) => t.id);
        if (track == null) return;
        final mkTrack = await _resolveMediaKitSubtitleTrack(track);
        if (mkTrack == null || !mounted) return;
        // Captured fresh here, after the fetch above, not before it: a
        // restart can swap `_player` out from under an in-flight fetch, the
        // same hazard `_showSubtitleSelector` documents at its own
        // `setSubtitleTrack` call.
        final player = _player;
        if (player == null) return;
        await player.setSubtitleTrack(mkTrack);
        if (mounted) setState(() => _selectedSubtitleTrack = track);
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
    // only there does back need to do that job first.
    //
    // Wrapped in a `ListenableBuilder` rather than reading the controller
    // once: `_chromeVisibility` changes from deep inside the chrome widget
    // tree (a timer, a tap, attaching or detaching), never through this
    // screen's own `setState`, so `canPop` has to be recomputed on every
    // notification or it goes stale and back either never exits or always
    // does.
    final frame = PlayerScreen.playerFrame(child: body);
    return ListenableBuilder(
      listenable: _chromeVisibility,
      builder: (context, _) => PopScope(
        canPop: !(InputCapabilities.directionalPrimary &&
            _chromeVisibility.blocksBack),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _chromeVisibility.hide();
        },
        child: frame,
      ),
    );
  }

  /// Tear the local player down and rebuild it from scratch.
  ///
  /// Used when casting stops: the media source the old [Player] was opened
  /// with no longer resolves, and media_kit gives no way to re-point it.
  Future<void> _restartLocalPlayback() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _tracksSubscription?.cancel();
    _tracksSubscription = null;
    await _errorSubscription?.cancel();
    _errorSubscription = null;
    _progressService?.stopSync();

    final player = _player;
    _player = null;
    if (mounted) {
      setState(() {
        _videoController = null;
        _isLoading = true;
        _error = null;
        _autoplayBlocked = false;
      });
    } else {
      _videoController = null;
    }

    await player?.dispose();

    if (!mounted) return;
    await _initializePlayer();
  }

  /// Keep the cast affordance reachable in every state.
  ///
  /// Casting is the natural remedy for a file the local player cannot decode,
  /// so hiding the button behind "local playback is ready" removes it exactly
  /// when it is most useful.
  Widget _withCastAffordance(Widget child) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: 8,
          right: 8,
          child: SafeArea(
            child: CastButton(onPressed: _showCastDevicePicker),
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
          // Hidden when the ladder collapsed to Original alone — a source
          // shorter than every rung, a local file, or a height the server
          // never reported — matching how subtitles and audio disable
          // themselves at zero tracks rather than opening a one-item menu.
          onQualityTap: _qualityLadder.length > 1 ? _showQualitySelector : null,
          // Null where no fullscreen route exists, which hides the button
          // rather than leaving a dead one — matching how `onQualityTap`
          // above hides itself at a single quality rung.
          onFullscreenTap: _fullscreen.available ? _fullscreen.toggle : null,
          onAlwaysOnTopTap: _toggleAlwaysOnTop,
          onPreviousEpisode: _hasPreviousEpisode ? _playPreviousEpisode : null,
          onNextEpisode: _hasNextEpisode ? _playNextEpisode : null,
          onActivity: () => _upNextCountdown?.noteInput(),
          isFullscreen: _fullscreen.isFullscreen.value,
          isAlwaysOnTop: _isAlwaysOnTop,
          audioTrackCount: _audioTracks.length,
          subtitleTrackCount: _subtitleTracks.length,
          selectedAudioLabel: _selectedAudioTrack?.displayName,
          selectedSubtitleLabel: _selectedSubtitleTrack?.displayName,
          selectedQualityLabel: (_effectiveQuality ?? _selectedQuality).label,
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Casting to ${device.name}'),
          duration: const Duration(seconds: 2),
        ));
      }
    } on CastBackendException catch (e) {
      if (!mounted) return;
      showCastErrorSnackBar(context, e, ref: ref);
    } catch (e) {
      // Anything that isn't a CastBackendException: the session manager
      // itself resolving (Hive, GraphQL client), or a non-typed failure from
      // _setLanAccess/_store.save inside startCast. Without this, those
      // failures would close the picker with no snackbar and no log.
      debugPrint('[PlayerScreen] Unexpected error starting cast: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to start casting: $e'),
        backgroundColor: Colors.red,
      ));
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

/// Whether [_PlayerScreenState.seekToReal] must restart the HLS session
/// rather than seek the live player in place.
///
/// Extracted as a free function so the seek boundary math can be
/// unit-tested without a widget tree or a live `Player` — constructing a
/// real (non-fake-backed) `Player` requires native mpv/FFI
/// (`NativePlayer`'s constructor calls `DynamicLibrary.open` synchronously),
/// which is not available under `flutter test`; every other test in this
/// suite that needs a `Player` injects a fake `platformPlayer` for exactly
/// this reason, and `PlayerScreen` itself does not offer a way to do that.
/// Same pattern as [shouldOfferResume] and [handleEpisodeNavKey].
///
/// [seekableEnd] must be the player's own **raw**, unresolved
/// `player.state.duration` — see `seekToReal`'s own comment at its call site
/// for why that is deliberate rather than a bug: it is exactly how much of
/// the stream has been transcoded and can currently be seeked into, which a
/// [StreamTimeline]-resolved duration would not tell you.
///
/// Overshooting [seekableEnd] by up to [kSeekRestartTolerance] does not
/// restart: `seekToReal` clamps those to the seekable end instead. See that
/// constant for why a small skip on a cold stream must not cost a restart.
@visibleForTesting
bool shouldRestartForSeek({
  required bool isDirectPlay,
  required Duration realTarget,
  required Duration localTarget,
  required Duration seekableEnd,
  required Duration startOffset,
}) {
  // Direct play and offline playback hold the whole file locally — there is
  // no HLS session to restart, and the player's own duration is already the
  // true one, so seeking is always local for them.
  if (isDirectPlay) return false;

  return localTarget > seekableEnd + kSeekRestartTolerance ||
      realTarget < startOffset;
}

/// Runs [restart], reporting in-flight state through [setInFlight] for the
/// restart's entire duration — set `true` before anything else, guaranteed
/// to be set back to `false` afterward even if [restart] throws.
///
/// Extracted from [_PlayerScreenState._restartSessionAt] so this exact
/// set-before-any-await / always-cleared bookkeeping — the property
/// [_PlayerScreenState.seekToReal]'s re-entrancy guard depends on — can be
/// exercised with a controllable fake body (including one that throws),
/// independent of `_restartSessionAt`'s own player/GraphQL machinery, which
/// cannot be constructed in this test suite (see [shouldRestartForSeek]'s
/// dartdoc). A restart that throws without clearing the flag would wedge
/// [seekToReal] shut for the rest of the session — this is what guards
/// against that.
@visibleForTesting
Future<void> trackRestartInFlight(
  void Function(bool inFlight) setInFlight,
  Future<void> Function() restart,
) async {
  setInFlight(true);
  try {
    await restart();
  } finally {
    setInFlight(false);
  }
}

/// Puts [selected] into effect, restoring [previous] if that fails.
///
/// Extracted from [_PlayerScreenState._showQualitySelector] for the same
/// reason as [trackRestartInFlight]: the widget path cannot be driven under
/// `flutter test`. `_waitForPlaylist` polls a real URL that `flutter_test`'s
/// `HttpOverrides` answers with 400 on every attempt, so the screen reaches
/// its error state before the chrome that owns the quality button is ever
/// built, and the picker can never be tapped. This is the riskiest decision
/// in the quality change and the one most worth pinning, so it lives where a
/// fake [restart] that throws can exercise it.
///
/// [adopt] puts a rung into effect in memory — the widget both requests and
/// displays it from there. [remember] writes it to storage for the *next*
/// playback and is allowed to fail. [restart] tears the session down and
/// brings it back at that rung, throwing if it cannot; [isFallback]
/// distinguishes the two attempts, which the viewer is told apart.
/// [stillActive] reports whether the caller can still act at all (its widget
/// is still mounted). [onGaveUp] receives the second failure.
///
/// The retry is deliberately single. If returning to the rung that was
/// already working also fails, the problem is not the quality choice, and
/// another teardown would only cost the viewer more time before showing them
/// the same error. [onGaveUp] is where they land on the error screen instead.
@visibleForTesting
Future<void> applyQualityChoice({
  required QualityRung selected,
  required QualityRung previous,
  required void Function(QualityRung rung) adopt,
  required Future<void> Function(QualityRung rung) remember,
  required Future<void> Function(QualityRung rung, {required bool isFallback})
      restart,
  required bool Function() stillActive,
  required void Function(Object error) onGaveUp,
}) async {
  await _adoptAndRemember(selected, adopt, remember);

  try {
    await restart(selected, isFallback: false);
  } catch (error) {
    // Fall back to the rung that was working rather than stranding the
    // viewer on a black screen at a rung this file or server cannot serve.
    debugPrint(
        '[PlayerScreen] Quality change to ${selected.label} failed: $error');
    if (!stillActive()) return;
    await _adoptAndRemember(previous, adopt, remember);

    try {
      await restart(previous, isFallback: true);
    } catch (fallbackError) {
      debugPrint('[PlayerScreen] Restoring ${previous.label} failed too: '
          '$fallbackError');
      if (!stillActive()) return;
      onGaveUp(fallbackError);
    }
  }
}

/// Puts [rung] into effect in memory, then tries to remember it for the next
/// playback.
///
/// Both the order and the swallow are load-bearing. [adopt] is the only
/// channel the restart reads the rung from, so it happens first and is
/// synchronous — nothing can fail between choosing a rung and the restart
/// seeing it. [remember] goes through secure storage, which needs a keyring
/// on Linux desktop and can genuinely be unavailable, so its failure costs
/// the preference for next time and nothing else. Before this split, the
/// choice reached the restart *through* storage, and a swallowed write
/// failure silently restarted the session at the rung the viewer had just
/// replaced.
Future<void> _adoptAndRemember(
  QualityRung rung,
  void Function(QualityRung rung) adopt,
  Future<void> Function(QualityRung rung) remember,
) async {
  adopt(rung);

  try {
    await remember(rung);
  } catch (e) {
    debugPrint('[PlayerScreen] Could not save default quality: $e');
  }
}

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
/// what turns that exception into a snackbar instead of a crash.
///
/// Extracted as a free function for the same reason as [applyQualityChoice]
/// and [trackRestartInFlight]: proving this ordering under `flutter test`
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
