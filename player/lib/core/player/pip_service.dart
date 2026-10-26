import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'platform_features.dart';

/// Picture-in-Picture (PiP) service for mobile platforms
///
/// This is a stub implementation that provides the API structure
/// for future PiP integration. Actual implementation requires:
/// - Android: platform channels to use Android PiP API
/// - iOS: platform channels to use AVPictureInPictureController
/// - Or use a package like `pip_flutter` or `flutter_pip`
class PipService {
  bool _isPipEnabled = false;
  bool _isPipActive = false;

  /// Check if PiP is supported on this platform
  bool get isSupported => PlatformFeatures.supportsPiP;

  /// Check if PiP is currently enabled
  bool get isEnabled => _isPipEnabled;

  /// Check if video is currently in PiP mode
  bool get isActive => _isPipActive;

  /// Enable PiP mode
  ///
  /// Returns true if PiP was successfully enabled
  Future<bool> enable() async {
    if (!isSupported) {
      debugPrint('PiP is not supported on this platform');
      return false;
    }

    // TODO: Implement platform channel calls
    // For Android:
    // - Check Android version >= 8.0 (API 26)
    // - Call Activity.enterPictureInPictureMode()
    // For iOS:
    // - Check iOS version >= 14.0
    // - Use AVPictureInPictureController

    debugPrint('PiP enable requested (stub implementation)');
    _isPipEnabled = true;
    return true;
  }

  /// Disable PiP mode
  void disable() {
    debugPrint('PiP disabled');
    _isPipEnabled = false;
  }

  /// Enter PiP mode
  ///
  /// This should be called when the app goes to background during playback
  Future<bool> enterPipMode() async {
    if (!isSupported || !_isPipEnabled) {
      return false;
    }

    // TODO: Implement platform channel call to enter PiP
    debugPrint('Entering PiP mode (stub implementation)');
    _isPipActive = true;
    return true;
  }

  /// Exit PiP mode
  Future<void> exitPipMode() async {
    if (!_isPipActive) {
      return;
    }

    // TODO: Implement platform channel call to exit PiP
    debugPrint('Exiting PiP mode (stub implementation)');
    _isPipActive = false;
  }

  /// Handle app lifecycle changes to auto-enable PiP when backgrounded
  void handleAppLifecycleChange(AppLifecycleState state, bool isPlaying) {
    if (!isSupported || !_isPipEnabled || !isPlaying) {
      return;
    }

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App is going to background, enter PiP
        enterPipMode();
      case AppLifecycleState.resumed:
        // App is back in foreground, exit PiP
        exitPipMode();
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // No action needed
        break;
    }
  }

  /// Dispose resources
  void dispose() {
    exitPipMode();
  }
}

/// Widget to show PiP toggle button in player controls
class PipToggleButton extends StatelessWidget {
  final PipService pipService;
  final VoidCallback? onToggle;

  const PipToggleButton({
    super.key,
    required this.pipService,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (!pipService.isSupported) {
      return const SizedBox.shrink();
    }

    return IconButton(
      icon: Icon(
        pipService.isEnabled
            ? Icons.picture_in_picture
            : Icons.picture_in_picture_alt,
        color: Colors.white,
      ),
      onPressed: () {
        if (pipService.isEnabled) {
          pipService.disable();
        } else {
          pipService.enable();
        }
        onToggle?.call();
      },
      tooltip: pipService.isEnabled
          ? context.l10n.pipDisable
          : context.l10n.pipEnable,
    );
  }
}
