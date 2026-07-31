import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/player/stream_timeline.dart';

/// Gesture controls for mobile playback
///
/// Features:
/// - Swipe up/down on left side: brightness control
/// - Swipe up/down on right side: volume control
/// - Double-tap left side: seek backward 10 seconds
/// - Double-tap right side: seek forward 10 seconds
///
/// Uses [HitTestBehavior.translucent] to wrap the child so that both this
/// widget's gesture recognizers and the child's (e.g. tap-to-show controls)
/// participate in the gesture arena.
class GestureControls extends StatefulWidget {
  final Player player;

  /// The mapping from the player's stream-local positions onto real media
  /// positions. [StreamTimeline.zero] is correct for direct play and offline
  /// files.
  final StreamTimeline timeline;

  final Widget child;

  const GestureControls({
    super.key,
    required this.player,
    required this.timeline,
    required this.child,
  });

  @override
  State<GestureControls> createState() => _GestureControlsState();
}

class _GestureControlsState extends State<GestureControls> {
  static const double _seekSeconds = 10.0;
  static const Duration _indicatorDuration = Duration(milliseconds: 500);

  bool _showSeekIndicator = false;
  bool _isSeekForward = true;
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  double _volume = 1.0;
  double _brightness = 1.0;

  Offset? _lastDoubleTapPosition;

  @override
  void initState() {
    super.initState();
    _volume = widget.player.state.volume / 100.0; // media_kit uses 0-100 scale
  }

  void _handleDoubleTap() {
    final screenWidth = context.size?.width ?? 0;
    final isRight = (_lastDoubleTapPosition?.dx ?? 0) > screenWidth / 2;
    if (isRight) {
      _seekForward();
    } else {
      _seekBackward();
    }
  }

  void _seekBackward() {
    final timeline = widget.timeline;
    final currentPosition = timeline.toReal(widget.player.state.position);
    final newPosition = currentPosition - const Duration(seconds: 10);
    final targetPosition =
        newPosition < Duration.zero ? Duration.zero : newPosition;

    widget.player.seek(timeline.toPlayer(targetPosition));
    _showSeekFeedback(forward: false);
  }

  void _seekForward() {
    final timeline = widget.timeline;
    final currentPosition = timeline.toReal(widget.player.state.position);
    final duration = timeline.resolveDuration(widget.player.state.duration);
    final newPosition = currentPosition + const Duration(seconds: 10);
    final targetPosition = newPosition > duration ? duration : newPosition;

    widget.player.seek(timeline.toPlayer(targetPosition));
    _showSeekFeedback(forward: true);
  }

  void _showSeekFeedback({required bool forward}) {
    setState(() {
      _isSeekForward = forward;
      _showSeekIndicator = true;
    });

    Future.delayed(_indicatorDuration, () {
      if (mounted) {
        setState(() {
          _showSeekIndicator = false;
        });
      }
    });
  }

  void _handleVerticalDragLeft(double delta) {
    // Left side controls brightness
    setState(() {
      _brightness = (_brightness - delta * 0.01).clamp(0.0, 1.0);
      _showBrightnessIndicator = true;
    });

    // TODO: Implement actual brightness control using platform channels
    // For now, this is a visual-only feature

    Future.delayed(_indicatorDuration, () {
      if (mounted) {
        setState(() {
          _showBrightnessIndicator = false;
        });
      }
    });
  }

  void _handleVerticalDragRight(double delta) {
    // Right side controls volume
    final newVolume = (_volume - delta * 0.01).clamp(0.0, 1.0);

    setState(() {
      _volume = newVolume;
      _showVolumeIndicator = true;
    });

    // Convert 0.0-1.0 to 0-100 for media_kit
    widget.player.setVolume(newVolume * 100.0);

    Future.delayed(_indicatorDuration, () {
      if (mounted) {
        setState(() {
          _showVolumeIndicator = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Wrap child with gesture detection using translucent behavior.
        // This ensures the child's own gesture detectors (e.g. tap-to-show
        // video controls) are also hit-tested and participate in the arena.
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTapDown: (details) {
            _lastDoubleTapPosition = details.localPosition;
          },
          onDoubleTap: _handleDoubleTap,
          onVerticalDragUpdate: (details) {
            final screenWidth = context.size?.width ?? 0;
            final isRight = details.localPosition.dx > screenWidth / 2;
            if (isRight) {
              _handleVerticalDragRight(details.delta.dy);
            } else {
              _handleVerticalDragLeft(details.delta.dy);
            }
          },
          child: widget.child,
        ),
        // Seek indicator
        if (_showSeekIndicator)
          IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isSeekForward
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_seekSeconds.toInt()} sec',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Volume indicator (right side)
        if (_showVolumeIndicator)
          Positioned(
            right: 16,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 48,
                  height: 200,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        _volume > 0.5
                            ? Icons.volume_up_rounded
                            : _volume > 0
                                ? Icons.volume_down_rounded
                                : Icons.volume_off_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: -1,
                          child: LinearProgressIndicator(
                            value: _volume,
                            backgroundColor: Colors.grey[700],
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${(_volume * 100).toInt()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // Brightness indicator (left side)
        if (_showBrightnessIndicator)
          Positioned(
            left: 16,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 48,
                  height: 200,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        _brightness > 0.5
                            ? Icons.brightness_high_rounded
                            : Icons.brightness_low_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: -1,
                          child: LinearProgressIndicator(
                            value: _brightness,
                            backgroundColor: Colors.grey[700],
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${(_brightness * 100).toInt()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
