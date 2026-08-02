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
import '../../widgets/up_next_overlay.dart';
import '../../../domain/models/audio_track.dart' as app_models_audio;
import '../../../domain/models/subtitle_track.dart' as app_models;
import '../../../domain/models/cast_device.dart';
import '../../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../../graphql/queries/movie_detail.graphql.dart';
import '../../../graphql/queries/episode_detail.graphql.dart';
import '../../../graphql/queries/season_episodes.graphql.dart';
import '../../../graphql/mutations/start_streaming_session.graphql.dart';
import '../../../graphql/mutations/end_streaming_session.graphql.dart';
import '../../../graphql/queries/streaming_candidates.graphql.dart';
import '../../../graphql/schema.graphql.dart';
import '../../../core/p2p/local_proxy_service.dart';

/// Below this, resuming is not worth offering; start from the beginning.
const int kMinResumeThresholdSeconds = 30;

/// Within this distance of the end, the user has effectively finished.
const int kEndOfMediaThresholdSeconds = 60;

/// Matches ProgressService's server-side watched threshold.
const double kWatchedThreshold = 0.90;

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
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  Player? _player;
  VideoController? _videoController;
  ProgressService? _progressService;

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

  // Auto-play next episode state
  bool _showUpNext = false;
  int _autoPlayCountdown = 10;
  bool _autoPlayCancelled = false;
  Timer? _upNextTimer;
  static const _autoPlayCountdownDuration = 10;

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
  /// `castNotifier` is read once, up front: `castTargetProvider` is a
  /// keep-alive root provider, like `invalidatorProvider` (see
  /// [_invalidator]), so the notifier itself stays valid to call even if this
  /// widget is disposed while `startCast` is awaited. `ref.read` itself is
  /// not safe to call again at that point, which is why the notifier is
  /// captured before any `await` rather than re-read after one.
  Future<bool> _castToTargetIfSet() async {
    final target = ref.read(castTargetProvider);
    if (target == null) return false;

    final castNotifier = ref.read(castTargetProvider.notifier);

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
        ),
      );
      // The session now owns the device; currentCastDeviceProvider reports
      // it from here on. Leaving the target set would make every future
      // playback cast forever with no way to opt out.
      castNotifier.clear();
      return true;
    } catch (e) {
      // A dead screen is the one outcome worse than not casting: clear the
      // target and fall through so the user still gets their episode.
      debugPrint('[PlayerScreen] Cast target failed, playing locally: $e');
      castNotifier.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e is CastBackendException
              ? castErrorMessage(e, ref: ref)
              : 'Failed to start casting: $e'),
          backgroundColor: Colors.red,
        ));
      }
      return false;
    }
  }

  Future<void> _initializePlayer() async {
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

        if (await _castToTargetIfSet()) return;

        // Play downloaded content in offline mode. The whole file is already
        // on disk, so this is direct play in every sense `seekToReal` and
        // `_detectTracks` care about — no HLS session exists to restart, and
        // media_kit's own duration is already the true runtime.
        _isDirectPlay = true;
        await _initializeOfflinePlayback(offlinePath);
        return;
      }

      // In online mode, if content is downloaded locally, play it directly
      // without requiring network for streaming
      if (downloadedMedia != null && !kIsWeb) {
        final localPath =
            await _resolveDownloadedFilePath(downloadedMedia.filePath);
        if (localPath != null) {
          debugPrint('Playing from local file: $localPath');

          if (await _castToTargetIfSet()) return;

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

          // No candidates query runs on this branch — there is no server-side
          // stream to negotiate — so the runtime has to come from whatever
          // `_fetchProgressAndEpisodes` just loaded. `shouldOfferResume`
          // declines outright without one, which would silently cost this
          // path its resume prompt. Only `_totalDuration` is set, not
          // `_timeline`: the file is entirely local, so media_kit's own
          // duration is the authoritative one for everything else.
          _totalDuration = _resolveRealDuration(null);

          await _openPlayerAndStart(localPath, {}, promptResume: true);
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

      if (await _castToTargetIfSet()) return;

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

        // The resume decision must be made before the session starts: the
        // offset is an input to FFmpeg, not something that can be seeked to
        // once a live-style playlist is already running.
        //
        // Captured into locals rather than using `_savedPositionSeconds!`/
        // `_totalDuration!` below: Dart's flow analysis cannot promote a
        // field's nullability across the `shouldOfferResume(...)` call
        // boundary, only across a direct `!= null` check in the same
        // condition, so these null checks are what let the rest of this
        // block use non-nullable locals instead of the bang operator.
        //
        // `resumeOverride` (not `startPositionSeconds == 0`) is what gates
        // the dialog below: a seek-driven restart targeting real position 0
        // (dragging the scrubber back to the start, holding arrow-left to
        // the beginning, or any sub-second target — `Duration.inSeconds`
        // truncates) sets `_resumeOverrideSeconds` to exactly 0, which is
        // indistinguishable from "no override was set" if the check were on
        // the value instead of on presence. Gating on the nullable local
        // instead means a restart to position 0 never falls into the
        // dialog branch, never overwrites 0 with the stale
        // `_savedPositionSeconds`, and never sends the wrong `startPosition`
        // to the new session.
        final resumeOverride = _resumeOverrideSeconds;
        _resumeOverrideSeconds = null;
        var startPositionSeconds = resumeOverride ?? 0;
        final savedPosition = _savedPositionSeconds;
        final totalDuration = _totalDuration;
        // The literal `mounted &&` here (not just the one passed into
        // `shouldShowResumeDialog` below) is load-bearing for the analyzer:
        // `use_build_context_synchronously` only recognizes a `mounted`
        // check spelled directly in the guarding condition, not one hidden
        // behind a function call, before `context` is used past the earlier
        // `await`s in this method.
        if (mounted &&
            shouldShowResumeDialog(
              resumeOverride: resumeOverride,
              mounted: mounted,
            ) &&
            savedPosition != null &&
            totalDuration != null &&
            shouldOfferResume(
              savedPositionSeconds: savedPosition,
              realDuration: totalDuration,
            )) {
          final shouldResume = await showResumeDialog(
            context,
            savedPosition,
            totalDuration.inSeconds,
          );
          // The dialog is an unbounded wait on the user, and it now happens
          // before the session exists. If the route was replaced while it was
          // open (`context.go`, a deep link, app teardown) it completes with
          // null, `dispose()` has already run with `_hlsSessionId == null`,
          // and carrying on would start an HLS session, build a `Player` and
          // subscribe streams for a dead screen — with the FFmpeg process
          // surviving until the server's inactivity timeout.
          if (!mounted) return;
          if (shouldResume == true) {
            startPositionSeconds = savedPosition;
          }
        }

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
      // branch above has already asked about resuming and baked the answer
      // into the session's start offset, so asking again here would prompt
      // twice. The direct-play branch has no server-side offset to bake it
      // into and must resume with a plain seek.
      await _openPlayerAndStart(
        mediaSource,
        httpHeaders,
        promptResume: canDirect,
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
  /// [promptResume] separates them. The HLS branch passes false because it
  /// has already asked about resuming and baked the answer into the
  /// session's FFmpeg start offset — the only way to resume a live-style
  /// playlist. The other two pass true: they hold the entire file locally,
  /// have no server-side session to give an offset to, and seek correctly,
  /// so for them resuming is a plain [Player.seek] after the media opens.
  ///
  /// Both are needed. Prompting here for every path would double-prompt the
  /// HLS one; prompting only in the HLS branch (as this briefly did) silently
  /// removed the resume prompt from the preferred desktop and mobile path,
  /// where playback then always started at zero.
  Future<void> _openPlayerAndStart(
    String mediaSource,
    Map<String, String> httpHeaders, {
    required bool promptResume,
  }) async {
    if (mounted) {
      setState(() {
        _loadingMessage = null;
      });
    }

    // Asked before the player is built rather than after, matching the HLS
    // branch's ordering: `_totalDuration` is already resolved by now, so
    // there is nothing left to learn by opening the media first.
    //
    // Captured into locals for the same reason as the HLS branch: Dart's
    // flow analysis cannot promote a field's nullability across the
    // `shouldOfferResume(...)` call boundary.
    var resumeFrom = Duration.zero;
    final savedPosition = _savedPositionSeconds;
    final totalDuration = _totalDuration;
    if (promptResume &&
        mounted &&
        savedPosition != null &&
        totalDuration != null &&
        shouldOfferResume(
          savedPositionSeconds: savedPosition,
          realDuration: totalDuration,
        )) {
      final shouldResume = await showResumeDialog(
        context,
        savedPosition,
        totalDuration.inSeconds,
      );
      // Same unbounded-wait hazard as the HLS branch: the route can be
      // replaced while the dialog is open, in which case `dispose()` has
      // already run and building a `Player` here would leak it.
      if (!mounted) return;
      if (shouldResume == true) {
        resumeFrom = Duration(seconds: savedPosition);
      }
    }

    // Create media_kit player
    final player = Player();
    _player = player;
    _videoController = VideoController(player);

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
    if (resumeFrom > Duration.zero) {
      await player.seek(resumeFrom);
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

  /// Initialize player for offline playback (no network services required).
  Future<void> _initializeOfflinePlayback(String filePath) async {
    try {
      debugPrint('Initializing offline playback from: $filePath');

      // Create media_kit player
      _player = Player();
      _videoController = VideoController(_player!);

      // Open local file
      await _player!.open(
        Media(filePath),
        play: false,
      );

      // Wait for player to be ready
      await Future.delayed(const Duration(milliseconds: 500));

      // Start playback
      await _player!.play();

      // Listen for playback progress (but don't sync - we're offline)
      // Cancel any existing subscription before creating a new one
      await _positionSubscription?.cancel();
      _positionSubscription = _player!.stream.position.listen((_) {
        _onPlaybackProgress();
      });

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      debugPrint('Offline playback initialized successfully');
    } catch (e) {
      debugPrint('Error initializing offline playback: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to play downloaded content: $e';
          _isLoading = false;
        });
      }
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
    if (_player == null || _progressService == null) return;

    if (widget.mediaType == 'movie') {
      await _progressService!.saveMovieProgress(_player!, widget.mediaId);
    } else if (widget.mediaType == 'episode') {
      await _progressService!.saveEpisodeProgress(_player!, widget.mediaId);
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
    final castDevice = ref.watch(currentCastDeviceProvider);
    Widget body = isCasting && castDevice != null
        ? _buildCastPlaceholder(castDevice)
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: body,
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(castErrorMessage(e, ref: ref)),
        backgroundColor: Colors.red,
      ));
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
  Widget _buildCastPlaceholder(CastDevice device) {
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
                const Icon(Icons.cast_connected, size: 96, color: Colors.blue),
                const SizedBox(height: 24),
                Text(
                  'Playing on ${device.name}',
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

/// Whether to offer resuming, given a saved position and the real runtime.
///
/// Extracted as a free function so it can be unit-tested without a widget tree,
/// following the same pattern as [handleEpisodeNavKey].
///
/// A null [realDuration] declines deliberately. The alternative is computing a
/// percentage against media_kit's partial HLS playlist length, which is exactly
/// the bug that made every resume read as 100%.
bool shouldOfferResume({
  required int? savedPositionSeconds,
  required Duration? realDuration,
}) {
  if (savedPositionSeconds == null) return false;
  if (realDuration == null || realDuration <= Duration.zero) return false;
  if (savedPositionSeconds <= kMinResumeThresholdSeconds) return false;

  final total = realDuration.inSeconds;
  if (savedPositionSeconds >= total - kEndOfMediaThresholdSeconds) return false;
  if (savedPositionSeconds / total >= kWatchedThreshold) return false;

  return true;
}

/// Whether `_initializePlayer` may even consider showing the resume dialog,
/// given a possible seek-driven-restart override.
///
/// Deliberately gates on [resumeOverride]'s **presence** (`!= null`), not its
/// value (`!= 0`): a restart targeting real position 0 — dragging the
/// scrubber back to the start, holding arrow-left to the beginning, or any
/// sub-second target, since `Duration.inSeconds` truncates — sets
/// `_resumeOverrideSeconds` to exactly `0`, which a value-based check
/// (`resumeOverride != 0`) cannot tell apart from "no override was set at
/// all". Getting this wrong lets a restart to position 0 fall through to the
/// dialog, which then prompts about the unrelated, never-refreshed
/// `_savedPositionSeconds` from mount time and, if accepted, silently
/// overwrites the user's explicit seek-to-start with that stale saved
/// position.
///
/// Extracted as a free function, following the same pattern as
/// [shouldOfferResume] and [shouldRestartForSeek], so this exact presence-
/// vs-value distinction has its own name and test, independent of
/// `_initializePlayer`'s own network/session machinery.
@visibleForTesting
bool shouldShowResumeDialog({
  required int? resumeOverride,
  required bool mounted,
}) =>
    resumeOverride == null && mounted;

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
