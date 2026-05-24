import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import '../../domain/models/cast_device.dart';

/// Service for managing Chromecast device discovery and playback.
///
/// Integrates with flutter_chrome_cast package to provide:
/// - Device discovery on local network
/// - Session management (connect/disconnect)
/// - Media loading and playback control
/// - Real-time status updates
class CastService {
  final _devicesController = StreamController<List<CastDevice>>.broadcast();
  final _sessionController = StreamController<CastSession?>.broadcast();

  StreamSubscription<List<GoogleCastDevice>>? _deviceSubscription;
  StreamSubscription<GoogleCastSession?>? _sessionSubscription;
  StreamSubscription<GoggleCastMediaStatus?>? _mediaStatusSubscription;

  CastSession? _currentSession;

  /// Stream of available Chromecast devices.
  Stream<List<CastDevice>> get devicesStream => _devicesController.stream;

  /// Stream of the current casting session.
  Stream<CastSession?> get sessionStream => _sessionController.stream;

  /// Current casting session, if any.
  CastSession? get currentSession => _currentSession;

  /// Whether there is an active casting session.
  bool get isCasting => _currentSession != null;

  /// Start discovering Chromecast devices on the network.
  ///
  /// Note: Cast discovery is not supported on web platform, so this is a no-op on web.
  Future<void> startDiscovery() async {
    // Cast discovery is not supported on web (uses dart:io Platform internally)
    if (kIsWeb) {
      debugPrint('CastService: Skipping discovery on web platform');
      _devicesController.add([]);
      return;
    }

    debugPrint('CastService: Starting device discovery');

    // Listen to device discovery stream
    _deviceSubscription?.cancel();
    _deviceSubscription =
        GoogleCastDiscoveryManager.instance.devicesStream.listen(
      (googleCastDevices) {
        debugPrint(
            'CastService: Discovered ${googleCastDevices.length} devices');

        // Convert GoogleCastDevice to our CastDevice model
        final devices = googleCastDevices.map((device) {
          return CastDevice(
            id: device.deviceID,
            name: device.friendlyName,
            model: device.modelName,
          );
        }).toList();

        _devicesController.add(devices);
      },
      onError: (error) {
        debugPrint('CastService: Discovery error: $error');
        _devicesController.add([]);
      },
    );

    // Listen to session state changes
    _sessionSubscription?.cancel();
    _sessionSubscription =
        GoogleCastSessionManager.instance.currentSessionStream.listen(
      (session) {
        debugPrint('CastService: Session state changed: ${session != null}');

        if (session == null && _currentSession != null) {
          // Session ended
          _handleSessionEnded();
        }
      },
      onError: (error) {
        debugPrint('CastService: Session error: $error');
      },
    );

    // Start actual device discovery
    await GoogleCastDiscoveryManager.instance.startDiscovery();
  }

  /// Stop discovering devices.
  Future<void> stopDiscovery() async {
    // Cast discovery is not supported on web
    if (kIsWeb) {
      return;
    }

    debugPrint('CastService: Stopping device discovery');

    await GoogleCastDiscoveryManager.instance.stopDiscovery();
    _deviceSubscription?.cancel();
    _devicesController.add([]);
  }

  /// Connect to a Chromecast device and start a session.
  Future<void> connect(CastDevice device) async {
    debugPrint('CastService: Connecting to device ${device.name}');

    try {
      // Find the GoogleCastDevice that matches our CastDevice
      final devices =
          await GoogleCastDiscoveryManager.instance.devicesStream.first;
      final googleDevice = devices.firstWhere(
        (d) => d.deviceID == device.id,
        orElse: () => throw Exception('Device not found: ${device.name}'),
      );

      // Start session with the device
      await GoogleCastSessionManager.instance
          .startSessionWithDevice(googleDevice);

      // Create session object
      _currentSession = CastSession(
        device: device,
        playbackState: CastPlaybackState.idle,
      );

      _sessionController.add(_currentSession);

      // Listen to media status updates
      _listenToMediaStatus();

      debugPrint('CastService: Connected to ${device.name}');
    } catch (e) {
      debugPrint('CastService: Connection error: $e');
      rethrow;
    }
  }

  /// Listen to media status updates from the cast device.
  void _listenToMediaStatus() {
    _mediaStatusSubscription?.cancel();
    _mediaStatusSubscription =
        GoogleCastRemoteMediaClient.instance.mediaStatusStream.listen(
      (mediaStatus) {
        if (mediaStatus == null || _currentSession == null) return;

        debugPrint('CastService: Media status update');

        // Update session with current media info
        final mediaInfo = mediaStatus.mediaInformation;
        if (mediaInfo != null) {
          // Get duration from mediaInfo (property name is 'duration')
          final duration = mediaInfo.duration ?? Duration.zero;
          // Get position from the remote media client's playerPosition
          final position = GoogleCastRemoteMediaClient.instance.playerPosition;

          // Get title from contentId as fallback
          final title = mediaInfo.contentId;

          // Try to get image URL from metadata
          String? imageUrl;
          final images = mediaInfo.metadata?.images;
          if (images != null && images.isNotEmpty) {
            imageUrl = images.first.toString();
          }

          _currentSession = _currentSession!.copyWith(
            mediaInfo: CastMediaInfo(
              title: title,
              subtitle: null,
              imageUrl: imageUrl,
              duration: duration,
              position: position,
            ),
            playbackState: _mapPlayerState(mediaStatus.playerState),
          );

          _sessionController.add(_currentSession);
        }
      },
      onError: (error) {
        debugPrint('CastService: Media status error: $error');
      },
    );
  }

  /// Map CastMediaPlayerState to our CastPlaybackState.
  CastPlaybackState _mapPlayerState(CastMediaPlayerState? state) {
    if (state == null) return CastPlaybackState.idle;

    switch (state) {
      case CastMediaPlayerState.idle:
        return CastPlaybackState.idle;
      case CastMediaPlayerState.buffering:
        return CastPlaybackState.buffering;
      case CastMediaPlayerState.playing:
        return CastPlaybackState.playing;
      case CastMediaPlayerState.paused:
        return CastPlaybackState.paused;
      case CastMediaPlayerState.loading:
        return CastPlaybackState.buffering;
      default:
        return CastPlaybackState.idle;
    }
  }

  /// Handle session ended event.
  void _handleSessionEnded() {
    debugPrint('CastService: Session ended');

    _mediaStatusSubscription?.cancel();
    _currentSession = null;
    _sessionController.add(null);
  }

  /// Disconnect from the current casting session.
  Future<void> disconnect() async {
    debugPrint('CastService: Disconnecting from cast session');

    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
      _handleSessionEnded();
    } catch (e) {
      debugPrint('CastService: Disconnect error: $e');
      // Still clean up local state
      _handleSessionEnded();
    }
  }

  /// Load media into the cast session.
  Future<void> loadMedia({
    required String mediaUrl,
    required String title,
    String? subtitle,
    String? imageUrl,
    Duration? startPosition,
  }) async {
    if (_currentSession == null) {
      throw Exception('No active cast session');
    }

    debugPrint('CastService: Loading media');
    debugPrint('  URL: $mediaUrl');
    debugPrint('  Title: $title');

    try {
      // Create metadata (images field expects GoogleCastImage, not Uri)
      final metadata = GoogleCastGenericMediaMetadata(
        title: title,
        subtitle: subtitle,
      );

      // Create media info
      final mediaInfo = GoogleCastMediaInformation(
        contentId: mediaUrl,
        streamType: CastMediaStreamType.buffered,
        contentUrl: Uri.parse(mediaUrl),
        contentType: 'video/mp4', // Default to mp4, could be made configurable
        metadata: metadata,
      );

      // Load the media (autoplay is handled by default)
      await GoogleCastRemoteMediaClient.instance.loadMedia(
        mediaInfo,
        playPosition: startPosition ?? Duration.zero,
      );

      debugPrint('CastService: Media loaded successfully');

      // Update session state to buffering (actual state will come from media status updates)
      _currentSession = _currentSession!.copyWith(
        playbackState: CastPlaybackState.buffering,
      );
      _sessionController.add(_currentSession);
    } catch (e) {
      debugPrint('CastService: Load media error: $e');
      rethrow;
    }
  }

  /// Start or resume playback.
  Future<void> play() async {
    if (_currentSession == null || _currentSession!.mediaInfo == null) {
      throw Exception('No media loaded in cast session');
    }

    debugPrint('CastService: Playing');

    try {
      await GoogleCastRemoteMediaClient.instance.play();
    } catch (e) {
      debugPrint('CastService: Play error: $e');
      rethrow;
    }
  }

  /// Pause playback.
  Future<void> pause() async {
    if (_currentSession == null || _currentSession!.mediaInfo == null) {
      throw Exception('No media loaded in cast session');
    }

    debugPrint('CastService: Pausing');

    try {
      await GoogleCastRemoteMediaClient.instance.pause();
    } catch (e) {
      debugPrint('CastService: Pause error: $e');
      rethrow;
    }
  }

  /// Seek to a specific position.
  Future<void> seek(Duration position) async {
    if (_currentSession == null || _currentSession!.mediaInfo == null) {
      throw Exception('No media loaded in cast session');
    }

    debugPrint('CastService: Seeking to ${position.inSeconds}s');

    try {
      await GoogleCastRemoteMediaClient.instance.seek(
        GoogleCastMediaSeekOption(position: position),
      );
    } catch (e) {
      debugPrint('CastService: Seek error: $e');
      rethrow;
    }
  }

  /// Stop playback and clear media.
  Future<void> stop() async {
    if (_currentSession == null) {
      throw Exception('No active cast session');
    }

    debugPrint('CastService: Stopping playback');

    try {
      await GoogleCastRemoteMediaClient.instance.stop();

      _currentSession = _currentSession!.copyWith(
        mediaInfo: null,
        playbackState: CastPlaybackState.idle,
      );

      _sessionController.add(_currentSession);
    } catch (e) {
      debugPrint('CastService: Stop error: $e');
      rethrow;
    }
  }

  /// Clean up resources.
  void dispose() {
    debugPrint('CastService: Disposing');

    _deviceSubscription?.cancel();
    _sessionSubscription?.cancel();
    _mediaStatusSubscription?.cancel();
    _devicesController.close();
    _sessionController.close();
  }
}
