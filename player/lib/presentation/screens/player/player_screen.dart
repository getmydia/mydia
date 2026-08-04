import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../../../core/player/progress_service.dart';
import '../../../core/playback/playback_progress_providers.dart';
import '../../../core/playback/playback_progress_store.dart';
import '../../../core/utils/file_utils.dart' as file_utils;
import '../../../core/utils/web_lifecycle.dart' as web_lifecycle;
import '../../../core/player/platform_features.dart';
import '../../../core/player/stream_timeline.dart';
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
import '../../widgets/video_controls/custom_video_controls.dart';
import '../../widgets/video_controls/skip_segment_button.dart';
import '../../widgets/up_next_overlay.dart';
import '../../../domain/models/audio_track.dart' as app_models_audio;
import '../../../domain/models/media_segment.dart';
import '../../../domain/models/subtitle_track.dart' as app_models;
import '../../../domain/models/cast_device.dart';
import '../../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../../graphql/queries/movie_detail.graphql.dart';
import '../../../graphql/queries/episode_detail.graphql.dart';
import '../../../graphql/queries/media_segments.graphql.dart';
import '../../../graphql/queries/season_episodes.graphql.dart';
import '../../../graphql/mutations/start_streaming_session.graphql.dart';
import '../../../graphql/mutations/end_streaming_session.graphql.dart';
import '../../../graphql/queries/streaming_candidates.graphql.dart';
import '../../../graphql/schema.graphql.dart';
import '../../../core/p2p/local_proxy_service.dart';
import '../../../core/window/desktop_window.dart';
import '../../../core/window/player_window_sizer.dart';
import '../../../core/player/resume_plan.dart';
import '../settings/settings_controller.dart';

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

class PlayerScreen extends ConsumerStatefulWidget {
  final String mediaId;
  final String mediaType;
  final String fileId;
  final String? title;
  final String? showId;
  final int? seasonNumber;

  const PlayerScreen({
    super.key,
    required this.mediaId,
    required this.mediaType,
    required this.fileId,
    this.title,
    this.showId,
    this.seasonNumber,
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
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  Player? _player;
  VideoController? _videoController;
  ProgressService? _progressService;

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

  /// `localProxyServiceProvider` is a plain (non-autoDispose) provider, so it
  /// is effectively keep-alive for this container's lifetime — the same
  /// instance `ref.read` would return at any later point. Safe to capture
  /// once here, exactly like [_invalidator], and used by
  /// [_terminateHlsSession] instead of a `dispose()`-time `ref.read`.
  late final LocalProxyService _localProxyService;

  /// The current P2P connection mode, kept in sync via `ref.listenManual`
  /// (set up in [initState]) rather than read in `dispose()`:
  /// `ref.read`/`ref.watch` are unsafe there — `BuildContext.mounted` is
  /// already `false` throughout `State.dispose()`, a core Flutter
  /// invariant, not a Riverpod-specific one. [_terminateHlsSession] needs
  /// the *current* mode at termination time, and the user can switch modes
  /// mid-session, so a one-time capture (at [initState] or anywhere else)
  /// would risk going stale; the listener keeps it live for the whole
  /// widget lifetime instead, matching what a fresh `ref.read` would have
  /// returned at any given moment.
  ///
  /// The `ref.listenManual` subscription itself is set up in [initState] but
  /// not stored: `ConsumerStatefulElement` already keeps its own reference
  /// (to close automatically at unmount) whether or not the caller keeps
  /// one too, and this widget never needs to cancel it early.
  bool _isP2PMode = false;

  /// The most recently resolved GraphQL client, kept in sync via
  /// `ref.listenManual` for the same reason as [_isP2PMode]: a long
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
  bool _isLoading = true;
  String? _error;
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

  // Track selection state
  List<app_models.SubtitleTrack> _subtitleTracks = [];
  app_models.SubtitleTrack? _selectedSubtitleTrack;
  List<app_models_audio.AudioTrack> _audioTracks = [];
  app_models_audio.AudioTrack? _selectedAudioTrack;

  // Mapping from app model track IDs to media_kit track objects
  Map<String, AudioTrack> _mediaKitAudioTrackMap = {};
  Map<String, SubtitleTrack> _mediaKitSubtitleTrackMap = {};

  // Whether current playback is direct play (vs HLS)
  bool _isDirectPlay = false;

  // HLS quality selection (web only)
  HlsQualityLevel _selectedQuality = HlsQualityLevel.auto;

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

  // Fullscreen state
  bool _isFullscreen = false;

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
  int _autoPlayCountdown = 10;
  bool _autoPlayCancelled = false;
  Timer? _upNextTimer;
  static const _autoPlayCountdownDuration = 10;

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
    _localProxyService = ref.read(localProxyServiceProvider);

    // Set up before `_initializePlayer` so both are live for the whole
    // widget lifetime, regardless of which playback branch runs (offline,
    // already-downloaded, or streaming) — `_terminateHlsSession` is called
    // unconditionally from `dispose()` no matter which branch was taken.
    ref.listenManual<conn.ConnectionState>(
      conn.connectionProvider,
      (previous, next) => _isP2PMode = next.isP2PMode,
      fireImmediately: true,
    );
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
    _initializePlayer();

    // Force landscape orientation on mobile devices
    if (PlatformFeatures.isMobile) {
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
  Future<bool> _castToTargetIfSet(ResumePlan plan) async {
    final target = ref.read(castTargetProvider);
    if (target == null) return false;

    // Downloaded media lives only on this device; the route resolver has no
    // server-side file to hand the receiver. Playing locally is the useful
    // outcome, but silently ignoring the chosen device is not, so say why.
    if (widget.fileId == 'offline') {
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
          fileId: widget.fileId,
          mediaId: widget.mediaId,
          mediaType: widget.mediaType,
          title: widget.title ?? 'Untitled',
          duration: _knownCastDuration(),
          startPosition: plan.position,
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

    try {
      setState(() {
        _isLoading = true;
        _error = null;
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
          resumeOverride: null,
          mounted: mounted,
          ask: (saved, total) async {
            if (!mounted) return null;
            return showResumeDialog(context, saved, total);
          },
        );
        if (plan == null) return;

        if (await _castToTargetIfSet(plan)) return;

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
            resumeOverride: null,
            mounted: mounted,
            ask: (saved, total) async {
              if (!mounted) return null;
              return showResumeDialog(context, saved, total);
            },
          );
          if (plan == null) return;

          if (await _castToTargetIfSet(plan)) return;

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

        final proxy = ref.read(localProxyServiceProvider);
        await proxy.start(
          targetPeer: serverNodeAddr,
          authToken: token,
        );
        debugPrint('[PlayerScreen] Local proxy started on port ${proxy.port}');
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

      final contentType = widget.mediaType == 'movie' ? 'movie' : 'episode';
      final candidatesResult = await _fetchStreamingCandidates(
        graphqlClient,
        contentType,
        widget.mediaId,
      );

      // Determine if direct play is possible
      final canDirect = !kIsWeb &&
          candidatesResult != null &&
          _canDirectPlay(candidatesResult.candidates);

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
      final resumeOverride = _resumeOverrideSeconds;
      _resumeOverrideSeconds = null;
      final plan = await resolveResumePlan(
        savedPositionSeconds: _savedPositionSeconds,
        realDuration: _totalDuration,
        resumeOverride: resumeOverride,
        mounted: mounted,
        ask: (saved, total) async {
          if (!mounted) return null;
          return showResumeDialog(context, saved, total);
        },
      );
      if (plan == null) return;

      if (await _castToTargetIfSet(plan)) return;

      String mediaSource;
      Map<String, String> httpHeaders = {};

      if (canDirect) {
        // Direct play path (native only)
        final fileId = candidatesResult.fileId;
        debugPrint('[PlayerScreen] Direct play for file_id=$fileId');

        if (isP2PMode) {
          mediaSource =
              ref.read(localProxyServiceProvider).buildDirectStreamUrl(fileId);
        } else {
          // Get media token for URL (if available)
          final mediaTokenService =
              await ref.read(asyncMediaTokenServiceProvider.future);
          await mediaTokenService.ensureValidToken();
          final mediaToken = await mediaTokenService.getToken();

          mediaSource =
              '$serverUrl/api/v1/stream/file/$fileId?strategy=DIRECT_PLAY';
          if (mediaToken != null) {
            mediaSource += '&token=$mediaToken';
          } else {
            httpHeaders = {'Authorization': 'Bearer $token'};
          }
        }
      } else {
        // HLS path (both web and native fallback)
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
        final result = await graphqlClient.mutate(
          MutationOptions(
            document: documentNodeMutationStartStreamingSession,
            variables: Variables$Mutation$StartStreamingSession(
              fileId: widget.fileId,
              strategy: hlsStrategy,
              startPosition:
                  startPositionSeconds > 0 ? startPositionSeconds : null,
            ).toJson(),
          ),
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
              ref.read(localProxyServiceProvider).buildHlsUrl(_hlsSessionId!);
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
  /// Prefers HLS_COPY (no transcoding) if available, falls back to TRANSCODE.
  Enum$StreamingStrategy _pickHlsStrategy(
    List<Query$StreamingCandidates$streamingCandidates$candidates>? candidates,
  ) {
    if (candidates != null) {
      for (final c in candidates) {
        if (c.strategy == Enum$StreamingCandidateStrategy.HLS_COPY) {
          return Enum$StreamingStrategy.HLS_COPY;
        }
      }
    }
    return Enum$StreamingStrategy.TRANSCODE;
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

    // Re-bound whenever `_initializePlayer` runs again for this screen: a
    // source switch, a session restart, or a fresh `PlayerScreen` state for
    // a new queue item. It is *not* re-bound by navigating to the next
    // episode of a season -- that reuses this same `PlayerScreen` state
    // (go_router keys the page by route pattern, not the resolved path), so
    // `initState` and this call do not run again then. The sizer cancels
    // the previous subscription itself.
    _windowSizer?.bindVideoParams(player.stream.videoParams);

    // Open media
    await player.open(
      Media(mediaSource, httpHeaders: httpHeaders),
      play: false,
    );

    // Wait for player to be ready
    await Future.delayed(const Duration(milliseconds: 500));

    // Detect available tracks from media_kit
    _detectTracks();

    // A plain seek, not a `seekToReal`: these paths hold the whole file, so
    // the player's own coordinates already are the real ones and there is no
    // session that could need restarting.
    if (plan.resumes) {
      await player.seek(plan.position);
    }

    // Start playback
    await player.play();

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
  /// On native desktop, FFmpeg handles virtually all codecs/containers,
  /// so DIRECT_PLAY, REMUX, and HLS_COPY are all direct-playable.
  bool _canDirectPlay(
    List<Query$StreamingCandidates$streamingCandidates$candidates> candidates,
  ) {
    if (candidates.isEmpty) return false;

    final first = candidates.first;
    // On native desktop, FFmpeg can handle any format directly
    return first.strategy == Enum$StreamingCandidateStrategy.DIRECT_PLAY ||
        first.strategy == Enum$StreamingCandidateStrategy.REMUX ||
        first.strategy == Enum$StreamingCandidateStrategy.HLS_COPY;
  }

  /// Fetch streaming candidates from the server via GraphQL.
  Future<Query$StreamingCandidates$streamingCandidates?>
      _fetchStreamingCandidates(
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
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Failed to fetch candidates: ${result.exception}');
        return null;
      }

      final data = Query$StreamingCandidates.fromJson(result.data!);
      return data.streamingCandidates;
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching streaming candidates: $e');
      return null;
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

    // Find the file matching the current fileId
    for (final file in files) {
      if (file == null) continue;
      if (file.id == widget.fileId) {
        final subtitles = file.subtitles;
        if (subtitles != null) {
          _subtitleTracks = subtitles
              .whereType<Fragment$MediaFileFragment$subtitles>()
              .map((sub) => app_models.SubtitleTrack.fromGraphQL(sub))
              .toList();
          debugPrint(
              'Extracted ${_subtitleTracks.length} subtitle tracks from GraphQL');
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

  /// Detect available audio and subtitle tracks from the media_kit player
  /// and build mappings between app model tracks and media_kit track objects.
  void _detectTracks() {
    final player = _player;
    if (player == null) return;

    // --- Audio tracks ---
    final mkAudioTracks = player.state.tracks.audio;
    final audioTracks = <app_models_audio.AudioTrack>[];
    final audioMap = <String, AudioTrack>{};

    for (final mkTrack in mkAudioTracks) {
      // Skip the "auto" and "no" sentinel tracks
      if (mkTrack == AudioTrack.auto() || mkTrack == AudioTrack.no()) continue;

      final appTrack = app_models_audio.AudioTrack(
        id: mkTrack.id,
        language: mkTrack.language ?? 'und',
        title: mkTrack.title,
      );
      audioTracks.add(appTrack);
      audioMap[appTrack.id] = mkTrack;
    }

    // Mark first track as default if available
    if (audioTracks.isNotEmpty) {
      final firstTrack = audioTracks.first;
      audioTracks[0] = app_models_audio.AudioTrack(
        id: firstTrack.id,
        language: firstTrack.language,
        title: firstTrack.title,
        isDefault: true,
      );
    }

    // --- Subtitle tracks ---
    final mkSubtitleTracks = player.state.tracks.subtitle;
    final subtitleMap = <String, SubtitleTrack>{};

    if (_isDirectPlay) {
      // For direct play, merge embedded subs from media_kit with external subs from GraphQL
      final embeddedSubs = <app_models.SubtitleTrack>[];
      for (final mkTrack in mkSubtitleTracks) {
        if (mkTrack == SubtitleTrack.auto() || mkTrack == SubtitleTrack.no()) {
          continue;
        }

        final appTrack = app_models.SubtitleTrack(
          id: 'mk_${mkTrack.id}',
          language: mkTrack.language ?? 'und',
          title: mkTrack.title,
          embedded: true,
        );
        embeddedSubs.add(appTrack);
        subtitleMap[appTrack.id] = mkTrack;
      }

      // Add external subs from GraphQL (non-embedded ones with URLs)
      final externalSubs =
          _subtitleTracks.where((s) => !s.embedded && s.url != null).toList();

      // Build URI-based media_kit tracks for external subs
      for (final extSub in externalSubs) {
        final fullUrl = _buildSubtitleUrl(extSub.url!);
        final mkTrack = SubtitleTrack.uri(
          fullUrl,
          title: extSub.title,
          language: extSub.language,
        );
        subtitleMap[extSub.id] = mkTrack;
      }

      // Combine: embedded first, then external
      _subtitleTracks = [...embeddedSubs, ...externalSubs];
    } else {
      // For HLS mode: use only GraphQL subtitle tracks loaded via URI
      for (final sub in _subtitleTracks) {
        if (sub.url != null) {
          final fullUrl = _buildSubtitleUrl(sub.url!);
          final mkTrack = SubtitleTrack.uri(
            fullUrl,
            title: sub.title,
            language: sub.language,
          );
          subtitleMap[sub.id] = mkTrack;
        }
      }
    }

    _audioTracks = audioTracks;
    _mediaKitAudioTrackMap = audioMap;
    _mediaKitSubtitleTrackMap = subtitleMap;

    // Auto-select the current audio track
    final currentMkAudio = player.state.track.audio;
    if (currentMkAudio != AudioTrack.auto() &&
        currentMkAudio != AudioTrack.no()) {
      for (final appTrack in _audioTracks) {
        if (_mediaKitAudioTrackMap[appTrack.id]?.id == currentMkAudio.id) {
          _selectedAudioTrack = appTrack;
          break;
        }
      }
    }

    debugPrint('[PlayerScreen] Detected ${_audioTracks.length} audio tracks, '
        '${_subtitleTracks.length} subtitle tracks '
        '(directPlay=$_isDirectPlay)');
  }

  /// Build a full subtitle URL from a relative URL path.
  String _buildSubtitleUrl(String relativeUrl) {
    // If already absolute, return as-is
    if (relativeUrl.startsWith('http://') ||
        relativeUrl.startsWith('https://')) {
      return relativeUrl;
    }

    // Check if using P2P proxy
    final connectionState = ref.read(conn.connectionProvider);
    if (connectionState.isP2PMode) {
      final proxy = ref.read(localProxyServiceProvider);
      return 'http://127.0.0.1:${proxy.port}$relativeUrl';
    }

    // Direct server mode
    final serverUrl =
        ref.read(serverUrlProvider).whenOrNull(data: (url) => url);
    if (serverUrl != null) {
      return '$serverUrl$relativeUrl';
    }

    return relativeUrl;
  }

  Future<void> _fetchSeasonEpisodes(GraphQLClient client) async {
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

  void _onPlaybackProgress() {
    final player = _player;
    if (player == null || !mounted) return;

    _maybeAutoSkipSegment(player);

    // Check if video is near completion (90%)
    final isWatched = _progressService?.isWatched(player) == true;
    if (isWatched) {
      debugPrint('Content is considered watched (90% complete)');
      // Trigger "Up Next" overlay for episodes with a next episode available
      _maybeShowUpNext();

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

  /// Seek past a detected segment the viewer opted into skipping.
  ///
  /// Runs on every position tick, so the once-per-session bookkeeping lives
  /// inside [SegmentSkipTracker.takeAutoSkip] rather than here: a segment is
  /// consumed by the same call that reports it, and seeking back into one that
  /// has already been skipped does nothing.
  void _maybeAutoSkipSegment(Player player) {
    if (!_autoSkipSegments || _segments.isEmpty) return;

    final position = _timeline.toReal(player.state.position);
    final target = _skipTracker.takeAutoSkip(_segments, position);
    if (target == null) return;

    debugPrint('[PlayerScreen] Auto-skipping to ${target.end}');
    unawaited(seekToReal(target.end));
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

    final hasNext = _currentEpisodeIndex! < _seasonEpisodes!.length - 1;
    if (!hasNext) {
      return;
    }

    // Show the overlay and start countdown
    setState(() {
      _showUpNext = true;
      _autoPlayCountdown = _autoPlayCountdownDuration;
    });

    _startAutoPlayCountdown();
  }

  /// Start the auto-play countdown timer.
  void _startAutoPlayCountdown() {
    _upNextTimer?.cancel();
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      // Check if player is paused - pause the countdown
      if (_player != null && !_player!.state.playing) {
        return;
      }

      setState(() {
        _autoPlayCountdown--;
      });

      if (_autoPlayCountdown <= 0) {
        timer.cancel();
        _playNextEpisode();
      }
    });
  }

  /// Cancel the auto-play overlay and countdown.
  void _cancelAutoPlay() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
    if (mounted) {
      setState(() {
        _showUpNext = false;
        _autoPlayCancelled = true;
      });
    }
  }

  /// Play the next episode immediately.
  void _playNextEpisode() {
    _upNextTimer?.cancel();
    _upNextTimer = null;

    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return;
    }

    final nextIndex = _currentEpisodeIndex! + 1;
    if (nextIndex >= _seasonEpisodes!.length) {
      return;
    }

    final nextEpisode = _seasonEpisodes![nextIndex];
    final files = nextEpisode.files;
    if (files == null || files.isEmpty) {
      return;
    }

    final firstFile = files.first;
    if (firstFile == null) {
      return;
    }

    final title =
        'S${nextEpisode.seasonNumber}E${nextEpisode.episodeNumber}${nextEpisode.title != null ? ' - ${nextEpisode.title}' : ''}';
    _navigateToEpisode(nextEpisode.id, firstFile.id, title);
  }

  /// Play the previous episode immediately.
  void _playPreviousEpisode() {
    _upNextTimer?.cancel();
    _upNextTimer = null;

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
    _navigateToEpisode(previousEpisode.id, firstFile.id, title);
  }

  /// Get the title for the next episode (for display in Up Next overlay).
  String? _getNextEpisodeTitle() {
    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return null;
    }

    final nextIndex = _currentEpisodeIndex! + 1;
    if (nextIndex >= _seasonEpisodes!.length) {
      return null;
    }

    final nextEpisode = _seasonEpisodes![nextIndex];
    return 'S${nextEpisode.seasonNumber}E${nextEpisode.episodeNumber}${nextEpisode.title != null ? ' - ${nextEpisode.title}' : ''}';
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
      String episodeId, String fileId, String title) async {
    // Save current progress before navigating
    await _saveProgress();

    if (!mounted) return;

    // Navigate to new episode
    context.go(
      '/player/episode/$episodeId?fileId=$fileId&title=${Uri.encodeComponent(title)}&showId=${widget.showId}&seasonNumber=${widget.seasonNumber}',
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
  Future<void> _restartSessionAt(Duration target) async {
    await trackRestartInFlight(
      (inFlight) => _isRestartingSession = inFlight,
      () async {
        if (mounted) {
          setState(() {
            _loadingMessage = 'Seeking...';
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
  /// Reads only the fields captured in [initState] ([_isP2PMode],
  /// [_localProxyService], [_graphqlClient]) — never `ref` directly. This
  /// runs from `dispose()` (as well as the web beforeunload handler), and
  /// `ref.read`/`ref.watch` unconditionally throw once `dispose()` has
  /// started: `BuildContext.mounted` is already `false` throughout it, a
  /// core Flutter invariant. Before this, every call from `dispose()` threw
  /// on its very first line, before doing any of the cleanup below.
  Future<void> _terminateHlsSession() async {
    // Stop local proxy if P2P mode
    if (_isP2PMode) {
      try {
        await _localProxyService.stop();
        debugPrint('[PlayerScreen] Local proxy stopped');
      } catch (e) {
        debugPrint('[PlayerScreen] Error stopping local proxy: $e');
      }
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
  Future<void> _showSubtitleSelector() async {
    final selected = await showSubtitleTrackSelector(
      context,
      _subtitleTracks,
      _selectedSubtitleTrack,
    );

    if (selected != _selectedSubtitleTrack && mounted) {
      setState(() {
        _selectedSubtitleTrack = selected;
      });

      final player = _player;
      if (player == null) return;

      if (selected == null) {
        // "Off" - disable subtitles
        await player.setSubtitleTrack(SubtitleTrack.no());
        debugPrint('[PlayerScreen] Subtitles turned off');
      } else {
        // Look up the corresponding media_kit track
        final mkTrack = _mediaKitSubtitleTrackMap[selected.id];
        if (mkTrack != null) {
          await player.setSubtitleTrack(mkTrack);
          debugPrint(
              '[PlayerScreen] Set subtitle track: ${selected.displayName}');
        } else {
          debugPrint(
              '[PlayerScreen] No media_kit track found for: ${selected.id}');
        }
      }
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
    }
  }

  /// Show HLS quality selector (web only)
  Future<void> _showQualitySelector() async {
    final selected = await showHlsQualitySelector(
      context,
      _selectedQuality,
    );

    if (selected != null && selected != _selectedQuality && mounted) {
      setState(() {
        _selectedQuality = selected;
      });

      debugPrint('Selected quality: ${selected.label}');

      // Note: media_kit on web with hls.js handles quality selection automatically
      // The HLS.js library manages adaptive bitrate switching based on network conditions
      // For manual quality selection, we would need to access the hls.js instance
      // which is not directly exposed by media_kit's web implementation
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Quality preference set to ${selected.label}. '
            'Note: HLS adaptive streaming is handled automatically by the player.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
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

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        // Play/Pause
        player.playOrPause();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowLeft:
        // Seek backward 10 seconds
        final currentPosition = _timeline.toReal(player.state.position);
        final newPosition = currentPosition - const Duration(seconds: 10);
        final targetPosition =
            newPosition < Duration.zero ? Duration.zero : newPosition;
        seekToReal(targetPosition);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        // Seek forward 10 seconds
        final currentPosition = _timeline.toReal(player.state.position);
        final duration = _timeline.resolveDuration(player.state.duration);
        final newPosition = currentPosition + const Duration(seconds: 10);
        final targetPosition = newPosition > duration ? duration : newPosition;
        seekToReal(targetPosition);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        // Volume up
        final currentVolume = player.state.volume;
        final newVolume = (currentVolume + 10.0).clamp(0.0, 100.0);
        player.setVolume(newVolume);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        // Volume down
        final currentVolume = player.state.volume;
        final newVolume = (currentVolume - 10.0).clamp(0.0, 100.0);
        player.setVolume(newVolume);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
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
        if (_isFullscreen) {
          _toggleFullscreen();
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

  /// Toggle fullscreen mode across all platforms.
  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    if (_isFullscreen) {
      defaultEnterNativeFullscreen();
    } else {
      defaultExitNativeFullscreen();
    }
  }

  @override
  void dispose() {
    // Exit fullscreen if active
    if (_isFullscreen) {
      defaultExitNativeFullscreen();
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

    // Cancel stream subscription to prevent memory leak
    _positionSubscription?.cancel();

    // Cancel auto-play timer
    _upNextTimer?.cancel();

    // Stop progress tracking
    _progressService?.stopSync();
    _progressService?.dispose();

    // Dispose player (VideoController is automatically disposed when player is disposed)
    _player?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

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

    final isCasting = ref.watch(isCastingProvider);
    final castSession = ref.watch(castSessionProvider).value;
    Widget body = isCasting && castSession != null
        ? _buildCastPlaceholder(castSession)
        : _buildBody();

    // Wrap with keyboard listener wherever a physical keyboard exists
    // (native desktop or web — see supportsKeyboardShortcuts' own dartdoc).
    if (PlatformFeatures.supportsKeyboardShortcuts && !isCasting) {
      body = Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: body,
      );
    }

    return PlayerScreen.playerFrame(child: body);
  }

  /// Tear the local player down and rebuild it from scratch.
  ///
  /// Used when casting stops: the media source the old [Player] was opened
  /// with no longer resolves, and media_kit gives no way to re-point it.
  Future<void> _restartLocalPlayback() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _progressService?.stopSync();

    final player = _player;
    _player = null;
    if (mounted) {
      setState(() {
        _videoController = null;
        _isLoading = true;
        _error = null;
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
          onBack: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
          onAudioTap: _showAudioSelector,
          onSubtitleTap: _showSubtitleSelector,
          onQualityTap: PlatformFeatures.isWeb ? _showQualitySelector : null,
          onFullscreenTap: _toggleFullscreen,
          onPreviousEpisode: _hasPreviousEpisode ? _playPreviousEpisode : null,
          onNextEpisode: _hasNextEpisode ? _playNextEpisode : null,
          isFullscreen: _isFullscreen,
          audioTrackCount: _audioTracks.length,
          subtitleTrackCount: _subtitleTracks.length,
          selectedAudioLabel: _selectedAudioTrack?.displayName,
          selectedSubtitleLabel: _selectedSubtitleTrack?.displayName,
          selectedQualityLabel: _selectedQuality.label,
        ),
        fill: Colors.black,
      ),
    );

    // Wrap with gesture controls for mobile
    final player = _player;
    if (PlatformFeatures.supportsGestureControls && player != null) {
      videoPlayer = GestureControls(
        player: player,
        timeline: _timeline,
        onSeekToReal: seekToReal,
        child: videoPlayer,
      );
    }

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
                );
              },
            ),
          ),
        // Up Next overlay for auto-play (always interactive, not tied to controls)
        if (_showUpNext && _getNextEpisodeTitle() != null)
          UpNextOverlay(
            nextEpisodeTitle: _getNextEpisodeTitle()!,
            countdownSeconds: _autoPlayCountdown,
            onPlayNow: _playNextEpisode,
            onCancel: _cancelAutoPlay,
          ),
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

      await manager.startCast(
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
          // from the candidates metadata), falling back to whatever the local
          // player managed to work out.
          duration: _knownCastDuration(),
          subtitles: _subtitleTracks
              .where((track) => track.url != null)
              .map((track) => CastSubtitleTrack(
                    url: track.url!,
                    label: track.displayName,
                    language: track.language,
                  ))
              .toList(),
        ),
      );

      await _player?.pause();

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
