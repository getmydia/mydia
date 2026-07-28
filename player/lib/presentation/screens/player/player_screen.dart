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
import '../../../core/player/progress_service.dart';
import '../../../core/utils/file_utils.dart' as file_utils;
import '../../../core/utils/web_lifecycle.dart' as web_lifecycle;
import '../../../core/player/platform_features.dart';
import '../../../core/player/duration_override.dart';
import '../../../core/cast/cast_backend.dart';
import '../../../core/cast/cast_providers.dart';
import '../../../core/cast/cast_session_manager.dart';
import '../../../core/downloads/download_providers.dart';
import '../../widgets/resume_dialog.dart';
import '../../widgets/subtitle_track_selector.dart';
import '../../widgets/audio_track_selector.dart';
import '../../widgets/hls_quality_selector.dart';
import '../../widgets/gesture_controls.dart';
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
  /// Minimum position (in seconds) to show the resume dialog.
  /// If playback position is less than this, start from beginning.
  static const _minResumeThresholdSeconds = 30;

  Player? _player;
  VideoController? _videoController;
  ProgressService? _progressService;
  StreamSubscription<Duration>? _positionSubscription;
  bool _isLoading = true;
  String? _error;
  String? _loadingMessage;
  int? _savedPositionSeconds;
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

  // Desktop feature state
  final FocusNode _focusNode = FocusNode();
  DateTime? _lastClickTime;

  // Fullscreen state
  bool _isFullscreen = false;

  // Controls overlay visibility (synced with video controls)
  bool _controlsVisible = true;

  // Auto-play next episode state
  bool _showUpNext = false;
  int _autoPlayCountdown = 10;
  bool _autoPlayCancelled = false;
  Timer? _upNextTimer;
  static const _autoPlayCountdownDuration = 10;

  @override
  void initState() {
    super.initState();
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

        // Play downloaded content in offline mode
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

          await _openPlayerAndStart(localPath, {});
          return;
        }
        debugPrint('Downloaded file not found, falling back to streaming');
      }

      // Online mode - initialize network services
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);

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

      // Set total duration from candidates metadata
      if (candidatesResult != null) {
        final duration = candidatesResult.metadata.duration;
        if (duration != null) {
          _totalDuration = Duration(
            milliseconds: (duration * 1000).round(),
          );
          DurationOverride.value = _totalDuration;
          debugPrint(
              '[PlayerScreen] Total duration from candidates: $_totalDuration');
        }
      }

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

        // Start HLS session via GraphQL mutation (works for both modes)
        final result = await graphqlClient.mutate(
          MutationOptions(
            document: documentNodeMutationStartStreamingSession,
            variables: Variables$Mutation$StartStreamingSession(
              fileId: widget.fileId,
              strategy: hlsStrategy,
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

        // Set total duration from session if not already set from candidates
        if (_totalDuration == null && sessionResult.duration != null) {
          _totalDuration = Duration(
            milliseconds: (sessionResult.duration! * 1000).round(),
          );
          DurationOverride.value = _totalDuration;
          debugPrint(
              '[PlayerScreen] Total duration from session: $_totalDuration');
        }

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

      await _openPlayerAndStart(mediaSource, httpHeaders);
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

  /// Shared tail of _initializePlayer: create player, resume dialog, start playback.
  Future<void> _openPlayerAndStart(
    String mediaSource,
    Map<String, String> httpHeaders,
  ) async {
    if (mounted) {
      setState(() {
        _loadingMessage = null;
      });
    }

    // Create media_kit player
    _player = Player();
    _videoController = VideoController(_player!);

    // Open media
    await _player!.open(
      Media(mediaSource, httpHeaders: httpHeaders),
      play: false,
    );

    // Wait for player to be ready
    await Future.delayed(const Duration(milliseconds: 500));

    // Detect available tracks from media_kit
    _detectTracks();

    // Check if we should show resume dialog
    final duration = _player!.state.duration.inSeconds;
    final savedPosition = _savedPositionSeconds;
    if (mounted &&
        savedPosition != null &&
        savedPosition > _minResumeThresholdSeconds &&
        duration > 0) {
      final shouldResume = await showResumeDialog(
        context,
        savedPosition,
        duration,
      );

      if (shouldResume == true) {
        await _player!.seek(Duration(seconds: savedPosition));
      }
    }

    // Start playback
    await _player!.play();

    // Start progress tracking
    if (_progressService != null) {
      if (widget.mediaType == 'movie') {
        _progressService!.startMovieSync(_player!, widget.mediaId);
      } else if (widget.mediaType == 'episode') {
        _progressService!.startEpisodeSync(_player!, widget.mediaId);
      }
    }

    // Listen for playback completion
    await _positionSubscription?.cancel();
    _positionSubscription = _player!.stream.position.listen((_) {
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

  /// Terminate the HLS session on the server and clean up P2P resources.
  /// This stops FFmpeg and cleans up server-side resources.
  Future<void> _terminateHlsSession() async {
    // Stop local proxy if P2P mode
    final connectionState = ref.read(conn.connectionProvider);
    if (connectionState.isP2PMode) {
      try {
        final localProxyService = ref.read(localProxyServiceProvider);
        await localProxyService.stop();
        debugPrint('[PlayerScreen] Local proxy stopped');
      } catch (e) {
        debugPrint('[PlayerScreen] Error stopping local proxy: $e');
      }
    }

    // End HLS session via GraphQL (works for both modes)
    final sessionId = _hlsSessionId;
    if (sessionId != null) {
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
        final currentPosition = player.state.position;
        final newPosition = currentPosition - const Duration(seconds: 10);
        final targetPosition =
            newPosition < Duration.zero ? Duration.zero : newPosition;
        player.seek(targetPosition);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        // Seek forward 10 seconds
        final currentPosition = player.state.position;
        final duration = player.state.duration;
        final newPosition = currentPosition + const Duration(seconds: 10);
        final targetPosition = newPosition > duration ? duration : newPosition;
        player.seek(targetPosition);
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

  /// Handle double-click for fullscreen toggle (desktop only)
  void _handleTap() {
    if (!PlatformFeatures.isDesktop) return;

    final now = DateTime.now();
    if (_lastClickTime != null &&
        now.difference(_lastClickTime!) < const Duration(milliseconds: 300)) {
      _lastClickTime = null;
      _toggleFullscreen();
    } else {
      _lastClickTime = now;
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

    // Save progress before disposing (fire and forget - can't await in dispose)
    _saveProgress();

    // Terminate HLS session on server to stop FFmpeg (fire and forget)
    _terminateHlsSession();

    // Clear duration override
    DurationOverride.clear();

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
    final isCasting = ref.watch(isCastingProvider);
    Widget body = isCasting ? _buildCastRemoteControlUI() : _buildBody();

    // Wrap with keyboard listener for desktop
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

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
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
      );
    }

    if (_error != null) {
      return _buildError();
    }

    if (_videoController == null) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.red,
        ),
      );
    }

    // Video widget fills available space with black background
    // Using SizedBox.expand ensures proper sizing on all platforms
    Widget videoPlayer = SizedBox.expand(
      child: Video(
        controller: _videoController!,
        controls: customVideoControlsBuilderWithCallback(
          onVisibilityChanged: (visible) {
            if (mounted) {
              setState(() => _controlsVisible = visible);
            }
          },
          onAudioTap: _showAudioSelector,
          onSubtitleTap: _showSubtitleSelector,
          onQualityTap: PlatformFeatures.isWeb ? _showQualitySelector : null,
          onFullscreenTap: _toggleFullscreen,
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
        child: videoPlayer,
      );
    }

    // Add double-click handler for desktop
    if (PlatformFeatures.isDesktop) {
      videoPlayer = GestureDetector(
        onTap: _handleTap,
        child: videoPlayer,
      );
    }

    return Stack(
      children: [
        videoPlayer,
        // Top bar + overlays - synced with video controls visibility
        AnimatedOpacity(
          opacity: _controlsVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !_controlsVisible,
            child: Stack(
              children: [
                // Top bar
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: _buildTopBar(),
                ),
                // Episode navigation buttons
                if (_seasonEpisodes != null && _currentEpisodeIndex != null)
                  _buildEpisodeNavigation(),
              ],
            ),
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

  Widget _buildTopBar() {
    return Row(
      children: [
        // Back button
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(
                Icons.chevron_left_rounded,
                color: Colors.white,
                size: 28,
                shadows: [
                  Shadow(
                    color: Color(0x60000000),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
        ),
        // Title
        if (widget.title != null)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                widget.title!,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 6,
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
        else
          const Spacer(),
      ],
    );
  }

  Widget _buildEpisodeNavigation() {
    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return const SizedBox.shrink();
    }

    final hasPrevious = _currentEpisodeIndex! > 0;
    final hasNext = _currentEpisodeIndex! < _seasonEpisodes!.length - 1;

    return Positioned(
      bottom: 80,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (hasPrevious)
            IconButton(
              icon: const Icon(Icons.skip_previous,
                  color: Colors.white,
                  size: 32,
                  shadows: [
                    Shadow(
                      color: Color(0x60000000),
                      blurRadius: 8,
                    ),
                  ]),
              onPressed: () {
                final prevEpisode = _seasonEpisodes![_currentEpisodeIndex! - 1];
                final files = prevEpisode.files;
                if (files != null && files.isNotEmpty) {
                  final firstFile = files.first;
                  if (firstFile != null) {
                    final title =
                        'S${prevEpisode.seasonNumber}E${prevEpisode.episodeNumber}${prevEpisode.title != null ? ' - ${prevEpisode.title}' : ''}';
                    _navigateToEpisode(prevEpisode.id, firstFile.id, title);
                  }
                }
              },
              style: IconButton.styleFrom(
                padding: const EdgeInsets.all(12),
              ),
              tooltip: 'Previous Episode',
            ),
          if (hasPrevious && hasNext) const SizedBox(width: 32),
          if (hasNext)
            IconButton(
              icon: const Icon(Icons.skip_next,
                  color: Colors.white,
                  size: 32,
                  shadows: [
                    Shadow(
                      color: Color(0x60000000),
                      blurRadius: 8,
                    ),
                  ]),
              onPressed: () {
                final nextEpisode = _seasonEpisodes![_currentEpisodeIndex! + 1];
                final files = nextEpisode.files;
                if (files != null && files.isNotEmpty) {
                  final firstFile = files.first;
                  if (firstFile != null) {
                    final title =
                        'S${nextEpisode.seasonNumber}E${nextEpisode.episodeNumber}${nextEpisode.title != null ? ' - ${nextEpisode.title}' : ''}';
                    _navigateToEpisode(nextEpisode.id, firstFile.id, title);
                  }
                }
              },
              style: IconButton.styleFrom(
                padding: const EdgeInsets.all(12),
              ),
              tooltip: 'Next Episode',
            ),
        ],
      ),
    );
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

  // TODO: Re-enable cast button in top bar once casting is working
  /// Build the cast button that opens device picker.
  // ignore: unused_element
  Widget _buildCastButton() {
    if (!ref.watch(castCapabilitiesProvider).any)
      return const SizedBox.shrink();

    final isCasting = ref.watch(isCastingProvider);
    final castDevice = ref.watch(currentCastDeviceProvider);

    return IconButton(
      icon: Icon(
        isCasting ? Icons.cast_connected : Icons.cast,
        color: isCasting ? Colors.blue : Colors.white,
      ),
      onPressed: _showCastDevicePicker,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
      ),
      tooltip: isCasting && castDevice != null
          ? 'Casting to ${castDevice.name}'
          : 'Cast to device',
    );
  }

  /// Show the cast device picker dialog, then hand the selected device to
  /// [CastSessionManager] to resolve a route and start playback.
  Future<void> _showCastDevicePicker() async {
    final device = await showCastDevicePicker(context);
    if (device == null || !mounted) return;

    final manager = await ref.read(castSessionManagerProvider.future);

    try {
      await manager.startCast(
        device: device,
        request: CastLaunchRequest(
          fileId: widget.fileId,
          mediaId: widget.mediaId,
          mediaType: widget.mediaType,
          title: widget.title ?? 'Untitled',
          subtitleLabel: widget.mediaType == 'episode' ? 'Episode' : 'Movie',
          startPosition: _player?.state.position,
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
        content: Text(_castErrorMessage(e)),
        backgroundColor: Colors.red,
      ));
    }
  }

  /// Turn a cast failure into something the user can act on. A bare
  /// "cast failed" leaves a firewall or codec problem undiagnosable, so the
  /// unreachable case names the actual port that needs to be open.
  String _castErrorMessage(CastBackendException e) {
    final proxy = ref.read(localProxyServiceProvider);

    switch (e.kind) {
      case CastFailureKind.unreachable:
        final port = proxy.isLanAccessible ? proxy.port : null;
        final portHint =
            port == null ? '' : ' Allow incoming connections on port $port.';
        return 'The device could not reach your media. Check that both are on '
            'the same network and that your firewall is not blocking '
            'Mydia.$portHint';
      case CastFailureKind.mediaLoadFailed:
        return 'The device could not play this file. It may not support the '
            'video or audio format.';
      case CastFailureKind.connectionLost:
        return 'Lost the connection to the device.';
      case CastFailureKind.discoveryDenied:
        return 'Mydia needs local network permission to find cast devices.';
      case CastFailureKind.unknown:
        return 'Casting failed: ${e.message}';
    }
  }

  /// Build the remote control UI when casting.
  Widget _buildCastRemoteControlUI() {
    final session = ref.watch(castSessionProvider).value;
    if (session != null && session.isStale) {
      return Center(
        key: const Key('cast-session-stale'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cast_outlined, size: 48, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              'Lost connection to ${session.device.name}',
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _showCastDevicePicker,
              child: const Text('Reconnect'),
            ),
          ],
        ),
      );
    }

    final mediaInfo = ref.watch(castMediaInfoProvider);
    final playbackState = ref.watch(castPlaybackStateProvider);
    final castDevice = ref.watch(currentCastDeviceProvider);
    final manager = ref.watch(castSessionManagerProvider).value;

    if (mediaInfo == null || castDevice == null || manager == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.red),
      );
    }

    final isPlaying = playbackState == CastPlaybackState.playing;
    final isBuffering = playbackState == CastPlaybackState.buffering;
    final progress = mediaInfo.duration.inSeconds > 0
        ? mediaInfo.position.inSeconds / mediaInfo.duration.inSeconds
        : 0.0;

    return Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Cast icon
                const Icon(
                  Icons.cast_connected,
                  size: 120,
                  color: Colors.blue,
                ),
                const SizedBox(height: 32),
                // Device name
                Text(
                  'Casting to',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.grey[400],
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  castDevice.name,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 48),
                // Media title
                Text(
                  mediaInfo.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                      ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (mediaInfo.subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    mediaInfo.subtitle!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[400],
                        ),
                  ),
                ],
                const SizedBox(height: 48),
                // Progress bar
                Column(
                  children: [
                    Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChanged: (value) async {
                        final newPosition = Duration(
                          seconds:
                              (value * mediaInfo.duration.inSeconds).round(),
                        );
                        await manager.seek(newPosition);
                      },
                      activeColor: Colors.red,
                      inactiveColor: Colors.grey[800],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(mediaInfo.position),
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.grey[400],
                                    ),
                          ),
                          Text(
                            _formatDuration(mediaInfo.duration),
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.grey[400],
                                    ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // Playback controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Rewind 10s
                    IconButton(
                      icon: const Icon(Icons.replay_10, color: Colors.white),
                      iconSize: 40,
                      onPressed: () async {
                        final newPosition =
                            mediaInfo.position - const Duration(seconds: 10);
                        await manager.seek(
                          newPosition.isNegative ? Duration.zero : newPosition,
                        );
                      },
                    ),
                    const SizedBox(width: 24),
                    // Play/Pause
                    if (isBuffering)
                      const SizedBox(
                        width: 64,
                        height: 64,
                        child: CircularProgressIndicator(
                          color: Colors.red,
                          strokeWidth: 4,
                        ),
                      )
                    else
                      IconButton(
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                        ),
                        iconSize: 64,
                        onPressed: () async {
                          if (isPlaying) {
                            await manager.pause();
                          } else {
                            await manager.play();
                          }
                        },
                      ),
                    const SizedBox(width: 24),
                    // Forward 10s
                    IconButton(
                      icon: const Icon(Icons.forward_10, color: Colors.white),
                      iconSize: 40,
                      onPressed: () async {
                        final newPosition =
                            mediaInfo.position + const Duration(seconds: 10);
                        final maxPosition = mediaInfo.duration;
                        await manager.seek(
                          newPosition > maxPosition ? maxPosition : newPosition,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // Stop casting button
                OutlinedButton.icon(
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Casting'),
                  onPressed: () async {
                    await manager.stopCast();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Back button
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

  /// Format duration as HH:MM:SS or MM:SS.
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }
}
