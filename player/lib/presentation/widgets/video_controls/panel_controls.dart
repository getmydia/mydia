import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'control_button.dart';

/// Volume control for the panel's left group: a mute toggle and an
/// always-visible slider.
///
/// The slider is not hover-revealed. Hiding a control until the pointer finds
/// it costs discoverability for no real estate gain in a panel this size.
class VolumeSurface extends StatelessWidget {
  /// Current volume, 0..100 (media_kit's scale).
  final double volume;

  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;

  const VolumeSurface({
    super.key,
    required this.volume,
    required this.onVolumeChanged,
    required this.onToggleMute,
  });

  static const Key muteKey = Key('volume-mute');
  static const Key sliderKey = Key('volume-slider');

  static const double sliderWidth = 72.0;

  IconData get _glyph {
    if (volume == 0) return Icons.volume_off_rounded;
    if (volume < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ControlButton(
          key: muteKey,
          icon: _glyph,
          iconSize: 20,
          size: 40,
          tooltip: volume == 0 ? 'Unmute' : 'Mute',
          onTap: onToggleMute,
        ),
        SizedBox(
          key: sliderKey,
          width: sliderWidth,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.25),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: (volume / 100.0).clamp(0.0, 1.0),
              onChanged: (v) => onVolumeChanged(v * 100.0),
            ),
          ),
        ),
      ],
    );
  }
}

/// [VolumeSurface] bound to a media_kit [Player]'s volume stream.
///
/// Remembers the pre-mute volume so unmuting restores it rather than jumping
/// to full. If the user drags the slider itself down to zero, that also
/// counts as "muted" from the toggle's perspective, but the last non-zero
/// value dragged to is still what gets restored (or 100 if the player started
/// at zero and was never moved above it).
class VolumeCluster extends StatefulWidget {
  final Player player;

  const VolumeCluster({super.key, required this.player});

  @override
  State<VolumeCluster> createState() => _VolumeClusterState();
}

class _VolumeClusterState extends State<VolumeCluster> {
  double _lastVolume = 100.0;

  @override
  void initState() {
    super.initState();
    final current = widget.player.state.volume;
    _lastVolume = current == 0 ? 100.0 : current;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: widget.player.stream.volume,
      initialData: widget.player.state.volume,
      builder: (context, snapshot) {
        final volume = snapshot.data ?? 100.0;
        return VolumeSurface(
          volume: volume,
          onVolumeChanged: (v) {
            widget.player.setVolume(v);
            if (v > 0) _lastVolume = v;
          },
          onToggleMute: () {
            if (volume == 0) {
              widget.player.setVolume(_lastVolume);
            } else {
              _lastVolume = volume;
              widget.player.setVolume(0);
            }
          },
        );
      },
    );
  }
}

/// The panel's right group: subtitles, audio, quality, fullscreen.
class SecondaryCluster extends StatelessWidget {
  final VoidCallback? onSubtitleTap;
  final VoidCallback? onAudioTap;

  /// Web-only. When null the quality button is omitted entirely.
  final VoidCallback? onQualityTap;
  final VoidCallback? onFullscreenTap;

  final int audioTrackCount;
  final int subtitleTrackCount;
  final String? selectedAudioLabel;
  final String? selectedSubtitleLabel;
  final String? selectedQualityLabel;
  final bool isFullscreen;

  const SecondaryCluster({
    super.key,
    this.onSubtitleTap,
    this.onAudioTap,
    this.onQualityTap,
    this.onFullscreenTap,
    this.audioTrackCount = 0,
    this.subtitleTrackCount = 0,
    this.selectedAudioLabel,
    this.selectedSubtitleLabel,
    this.selectedQualityLabel,
    this.isFullscreen = false,
  });

  static const Key subtitlesKey = Key('secondary-subtitles');
  static const Key audioKey = Key('secondary-audio');
  static const Key qualityKey = Key('secondary-quality');
  static const Key fullscreenKey = Key('secondary-fullscreen');

  static const double gap = 4.0;

  @override
  Widget build(BuildContext context) {
    final subtitlesEnabled = subtitleTrackCount > 0;
    final audioEnabled = audioTrackCount > 0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ControlButton(
          key: subtitlesKey,
          icon: Icons.subtitles_rounded,
          iconSize: 20,
          size: 40,
          enabled: subtitlesEnabled,
          tooltip: subtitlesEnabled
              ? 'Subtitles: ${selectedSubtitleLabel ?? 'Off'}'
              : 'No subtitles',
          onTap: subtitlesEnabled ? onSubtitleTap : null,
        ),
        const SizedBox(width: gap),
        ControlButton(
          key: audioKey,
          icon: Icons.audiotrack_rounded,
          iconSize: 20,
          size: 40,
          enabled: audioEnabled,
          tooltip: audioEnabled
              ? 'Audio: ${selectedAudioLabel ?? 'Default'}'
              : 'No audio tracks',
          onTap: audioEnabled ? onAudioTap : null,
        ),
        if (onQualityTap != null) ...[
          const SizedBox(width: gap),
          ControlButton(
            key: qualityKey,
            icon: Icons.hd_rounded,
            iconSize: 20,
            size: 40,
            tooltip: 'Quality: ${selectedQualityLabel ?? 'Auto'}',
            onTap: onQualityTap,
          ),
        ],
        const SizedBox(width: gap),
        ControlButton(
          key: fullscreenKey,
          icon: isFullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          iconSize: 20,
          size: 40,
          tooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
          onTap: onFullscreenTap,
        ),
      ],
    );
  }
}
