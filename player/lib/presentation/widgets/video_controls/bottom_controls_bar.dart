import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/player/duration_override.dart';
import '../../../core/player/platform_features.dart';

/// Bottom controls bar with time display, volume control, and fullscreen toggle.
///
/// Adapts to platform:
/// - Mobile: mute toggle button for volume
/// - Desktop/Web: volume slider on hover
class BottomControlsBar extends StatefulWidget {
  /// The media_kit player instance.
  final Player player;

  /// Triggered when audio track selection is requested.
  final VoidCallback? onAudioTap;

  /// Triggered when subtitle selection is requested.
  final VoidCallback? onSubtitleTap;

  /// Triggered when quality selection is requested (web only).
  final VoidCallback? onQualityTap;

  /// Number of available audio tracks.
  final int audioTrackCount;

  /// Number of available subtitle tracks.
  final int subtitleTrackCount;

  /// Current audio track label, if available.
  final String? selectedAudioLabel;

  /// Current subtitle track label, if available.
  final String? selectedSubtitleLabel;

  /// Current quality label, if available.
  final String? selectedQualityLabel;

  /// Callback for toggling fullscreen.
  final VoidCallback? onFullscreenTap;

  /// Whether the player is currently in fullscreen mode.
  final bool isFullscreen;

  const BottomControlsBar({
    super.key,
    required this.player,
    this.onAudioTap,
    this.onSubtitleTap,
    this.onQualityTap,
    this.audioTrackCount = 0,
    this.subtitleTrackCount = 0,
    this.selectedAudioLabel,
    this.selectedSubtitleLabel,
    this.selectedQualityLabel,
    this.onFullscreenTap,
    this.isFullscreen = false,
  });

  @override
  State<BottomControlsBar> createState() => _BottomControlsBarState();
}

class _BottomControlsBarState extends State<BottomControlsBar> {
  bool _showVolumeSlider = false;
  double _lastVolume = 100.0;

  @override
  void initState() {
    super.initState();
    _lastVolume = widget.player.state.volume;
    if (_lastVolume == 0) {
      _lastVolume = 100.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final canShowQuality = widget.onQualityTap != null;
    final subtitleEnabled = widget.subtitleTrackCount > 0;
    final audioEnabled = widget.audioTrackCount > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          _buildPositionText(),
          const Spacer(),
          _buildActionButton(
            icon: Icons.subtitles_rounded,
            tooltip: subtitleEnabled
                ? 'Subtitles: ${widget.selectedSubtitleLabel ?? 'Off'}'
                : 'No subtitles',
            onTap: subtitleEnabled ? widget.onSubtitleTap : null,
            enabled: subtitleEnabled,
          ),
          const SizedBox(width: 6),
          _buildActionButton(
            icon: Icons.audiotrack_rounded,
            tooltip: audioEnabled
                ? 'Audio: ${widget.selectedAudioLabel ?? 'Default'}'
                : 'No audio tracks',
            onTap: audioEnabled ? widget.onAudioTap : null,
            enabled: audioEnabled,
          ),
          if (canShowQuality) ...[
            const SizedBox(width: 6),
            _buildActionButton(
              icon: Icons.hd_rounded,
              tooltip: 'Quality: ${widget.selectedQualityLabel ?? 'Auto'}',
              onTap: widget.onQualityTap,
              enabled: true,
            ),
          ],
          const SizedBox(width: 8),
          _buildVolumeControl(),
          const SizedBox(width: 8),
          _buildFullscreenButton(),
          const Spacer(),
          _buildRemainingTimeText(),
        ],
      ),
    );
  }

  Widget _buildPositionText() {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, positionSnapshot) {
        final position = positionSnapshot.data ?? Duration.zero;

        return Text(
          _formatDuration(position),
          // No per-glyph shadow: the token glass control bar backs the text
          // (R10). See U5.
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }

  Widget _buildRemainingTimeText() {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: widget.player.stream.duration,
          initialData: widget.player.state.duration,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final playerDuration = durationSnapshot.data ?? Duration.zero;
            final duration = DurationOverride.getDuration(playerDuration);
            final remaining = duration - position;
            final clampedRemaining =
                remaining.isNegative ? Duration.zero : remaining;

            return Text(
              '-${_formatDuration(clampedRemaining)}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildVolumeControl() {
    return StreamBuilder<double>(
      stream: widget.player.stream.volume,
      initialData: widget.player.state.volume,
      builder: (context, snapshot) {
        final volume = snapshot.data ?? 100.0;
        final isMuted = volume == 0;

        // On mobile, show just a mute toggle
        if (PlatformFeatures.isMobile) {
          return _buildMuteButton(isMuted);
        }

        // On desktop/web, show volume slider on hover
        return MouseRegion(
          onEnter: (_) => setState(() => _showVolumeSlider = true),
          onExit: (_) => setState(() => _showVolumeSlider = false),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMuteButton(isMuted),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _showVolumeSlider ? 80 : 0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _showVolumeSlider ? 1.0 : 0.0,
                  child: _showVolumeSlider
                      ? SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                            activeTrackColor: Colors.white,
                            inactiveTrackColor:
                                Colors.white.withValues(alpha: 0.3),
                            thumbColor: Colors.white,
                            overlayColor: Colors.white.withValues(alpha: 0.2),
                          ),
                          child: Slider(
                            value: volume / 100.0,
                            onChanged: (value) {
                              widget.player.setVolume(value * 100.0);
                              if (value > 0) {
                                _lastVolume = value * 100.0;
                              }
                            },
                          ),
                        )
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMuteButton(bool isMuted) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (isMuted) {
            widget.player.setVolume(_lastVolume);
          } else {
            _lastVolume = widget.player.state.volume;
            widget.player.setVolume(0);
          }
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            _getVolumeIcon(isMuted ? 0 : widget.player.state.volume),
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onFullscreenTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            widget.isFullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    required bool enabled,
  }) {
    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            color:
                enabled ? Colors.white : Colors.white.withValues(alpha: 0.35),
            size: 20,
          ),
        ),
      ),
    );

    return Tooltip(
      message: tooltip,
      child: button,
    );
  }

  IconData _getVolumeIcon(double volume) {
    if (volume == 0) {
      return Icons.volume_off_rounded;
    } else if (volume < 50) {
      return Icons.volume_down_rounded;
    } else {
      return Icons.volume_up_rounded;
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
  }
}
