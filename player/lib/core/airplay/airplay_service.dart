import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../domain/models/airplay_device.dart';

/// Service for managing AirPlay device discovery and playback on iOS.
///
/// This service uses a platform channel to communicate with native iOS code
/// that integrates AVRoutePickerView for AirPlay device selection.
class AirPlayService {
  static const MethodChannel _channel =
      MethodChannel('com.mydia.player/airplay');

  final _devicesController = StreamController<List<AirPlayDevice>>.broadcast();
  final _sessionController = StreamController<AirPlaySession?>.broadcast();

  AirPlaySession? _currentSession;
  Timer? _progressTimer;

  /// Stream of available AirPlay devices.
  Stream<List<AirPlayDevice>> get devicesStream => _devicesController.stream;

  /// Stream of the current AirPlay session.
  Stream<AirPlaySession?> get sessionStream => _sessionController.stream;

  /// Current AirPlay session, if any.
  AirPlaySession? get currentSession => _currentSession;

  /// Whether there is an active AirPlay session.
  bool get isAirPlaying => _currentSession != null;

  AirPlayService() {
    _setupMethodCallHandler();
  }

  /// Setup handler for method calls from native iOS code.
  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRouteChanged':
          final String? routeName = call.arguments['routeName'];
          _handleRouteChanged(routeName);
          break;
        case 'onPlaybackStateChanged':
          final String state = call.arguments['state'];
          _handlePlaybackStateChanged(state);
          break;
        default:
          debugPrint('Unknown method from platform: ${call.method}');
      }
    });
  }

  /// Handle route change events from native code.
  void _handleRouteChanged(String? routeName) {
    if (routeName == null || routeName.isEmpty) {
      // Disconnected
      _currentSession = null;
      _sessionController.add(null);
      _progressTimer?.cancel();
      _progressTimer = null;
    } else {
      // Connected to a device
      final device = AirPlayDevice(
        id: routeName,
        name: routeName,
      );

      _currentSession = AirPlaySession(
        device: device,
        playbackState: AirPlayPlaybackState.idle,
      );

      _sessionController.add(_currentSession);
    }
  }

  /// Handle playback state change events from native code.
  void _handlePlaybackStateChanged(String state) {
    if (_currentSession == null) return;

    AirPlayPlaybackState playbackState;
    switch (state) {
      case 'playing':
        playbackState = AirPlayPlaybackState.playing;
        _startProgressTimer();
        break;
      case 'paused':
        playbackState = AirPlayPlaybackState.paused;
        _progressTimer?.cancel();
        _progressTimer = null;
        break;
      case 'buffering':
        playbackState = AirPlayPlaybackState.buffering;
        break;
      default:
        playbackState = AirPlayPlaybackState.idle;
        _progressTimer?.cancel();
        _progressTimer = null;
    }

    _currentSession = _currentSession!.copyWith(
      playbackState: playbackState,
    );

    _sessionController.add(_currentSession);
  }

  /// Check if AirPlay is available on this device (iOS only).
  Future<bool> isAvailable() async {
    try {
      final bool? available = await _channel.invokeMethod('isAvailable');
      return available ?? false;
    } catch (e) {
      debugPrint('Error checking AirPlay availability: $e');
      return false;
    }
  }

  /// Show the native AirPlay route picker.
  Future<void> showRoutePicker() async {
    try {
      await _channel.invokeMethod('showRoutePicker');
    } catch (e) {
      debugPrint('Error showing AirPlay route picker: $e');
    }
  }

  /// Start discovering AirPlay devices.
  ///
  /// Note: On iOS, device discovery is handled automatically by the system.
  /// This method exists for API consistency with CastService.
  Future<void> startDiscovery() async {
    debugPrint('AirPlayService: Discovery managed by iOS system');
    // Emit empty list initially - actual devices are shown via native picker
    _devicesController.add([]);
  }

  /// Stop discovering devices.
  Future<void> stopDiscovery() async {
    debugPrint('AirPlayService: Stopping discovery');
    _devicesController.add([]);
  }

  /// Load media into the AirPlay session.
  ///
  /// Note: For AirPlay, the video player's AVPlayer automatically handles
  /// routing to AirPlay devices. This method tracks the session state.
  Future<void> loadMedia({
    required String mediaUrl,
    required String title,
    String? subtitle,
    String? imageUrl,
    Duration? startPosition,
  }) async {
    if (_currentSession == null) {
      throw Exception('No active AirPlay session');
    }

    debugPrint('AirPlayService: Loading media');
    debugPrint('  URL: $mediaUrl');
    debugPrint('  Title: $title');

    // Update session with media info
    _currentSession = _currentSession!.copyWith(
      mediaInfo: AirPlayMediaInfo(
        title: title,
        subtitle: subtitle,
        imageUrl: imageUrl,
        duration: const Duration(minutes: 90), // Will be updated by player
        position: startPosition ?? Duration.zero,
      ),
      playbackState: AirPlayPlaybackState.buffering,
    );

    _sessionController.add(_currentSession);
  }

  /// Start or resume playback.
  Future<void> play() async {
    if (_currentSession == null || _currentSession!.mediaInfo == null) {
      throw Exception('No media loaded in AirPlay session');
    }

    debugPrint('AirPlayService: Playing');

    _currentSession = _currentSession!.copyWith(
      playbackState: AirPlayPlaybackState.playing,
    );

    _sessionController.add(_currentSession);
    _startProgressTimer();
  }

  /// Pause playback.
  Future<void> pause() async {
    if (_currentSession == null || _currentSession!.mediaInfo == null) {
      throw Exception('No media loaded in AirPlay session');
    }

    debugPrint('AirPlayService: Pausing');

    _progressTimer?.cancel();
    _progressTimer = null;

    _currentSession = _currentSession!.copyWith(
      playbackState: AirPlayPlaybackState.paused,
    );

    _sessionController.add(_currentSession);
  }

  /// Seek to a specific position.
  Future<void> seek(Duration position) async {
    if (_currentSession == null || _currentSession!.mediaInfo == null) {
      throw Exception('No media loaded in AirPlay session');
    }

    debugPrint('AirPlayService: Seeking to ${position.inSeconds}s');

    final mediaInfo = _currentSession!.mediaInfo!;
    _currentSession = _currentSession!.copyWith(
      mediaInfo: mediaInfo.copyWith(position: position),
    );

    _sessionController.add(_currentSession);
  }

  /// Stop playback and clear media.
  Future<void> stop() async {
    if (_currentSession == null) {
      throw Exception('No active AirPlay session');
    }

    debugPrint('AirPlayService: Stopping playback');

    _progressTimer?.cancel();
    _progressTimer = null;

    _currentSession = _currentSession!.copyWith(
      mediaInfo: null,
      playbackState: AirPlayPlaybackState.idle,
    );

    _sessionController.add(_currentSession);
  }

  /// Disconnect from the current AirPlay session.
  Future<void> disconnect() async {
    debugPrint('AirPlayService: Disconnecting from AirPlay session');

    _progressTimer?.cancel();
    _progressTimer = null;

    _currentSession = null;
    _sessionController.add(null);

    // Tell native code to disconnect
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      debugPrint('Error disconnecting from AirPlay: $e');
    }
  }

  /// Start a timer to simulate progress updates during playback.
  void _startProgressTimer() {
    _progressTimer?.cancel();

    _progressTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_currentSession == null ||
          _currentSession!.mediaInfo == null ||
          _currentSession!.playbackState != AirPlayPlaybackState.playing) {
        timer.cancel();
        return;
      }

      final mediaInfo = _currentSession!.mediaInfo!;
      final newPosition = mediaInfo.position + const Duration(seconds: 1);

      // Don't exceed duration
      if (newPosition <= mediaInfo.duration) {
        _currentSession = _currentSession!.copyWith(
          mediaInfo: mediaInfo.copyWith(position: newPosition),
        );

        _sessionController.add(_currentSession);
      } else {
        // Reached end of media
        timer.cancel();
        _currentSession = _currentSession!.copyWith(
          playbackState: AirPlayPlaybackState.idle,
        );
        _sessionController.add(_currentSession);
      }
    });
  }

  /// Clean up resources.
  void dispose() {
    _progressTimer?.cancel();
    _devicesController.close();
    _sessionController.close();
  }
}
