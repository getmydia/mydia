import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/theme/depth_tokens.dart';
import 'control_button.dart';

/// Volume control for the panel's left group: a mute toggle and an
/// always-visible slider.
///
/// The slider is not hover-revealed. Hiding a control until the pointer finds
/// it costs discoverability for no real estate gain in a panel this size.
class VolumeSurface extends StatefulWidget {
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

  /// A previous revision trimmed this to 52 to "close" a 600px overflow —
  /// wrong on two counts: `VolumeSurface`'s own 112px need (40 mute button +
  /// 72 slider) was never the binding constraint at that width (
  /// `SecondaryCluster`'s 120px floor was, and stayed broken regardless of
  /// this value — see `chrome_panel_overflow_test.dart`), and once the panel
  /// width/padding levers actually closed 600px (`PanelMetrics.forWidth`'s
  /// tablet-branch factor and `horizontalPadding`), 72 fits there too
  /// (`40 + 72 == 112 <= 122`). Restored to the original 72; trimming it
  /// bought nothing but ~33% less slider travel.
  static const double sliderWidth = 72.0;

  /// Track height at rest. Matches `ProgressBarSurface`'s own resting track
  /// — this slider used to be a lone 3px hairline at 0.25 alpha, the exact
  /// geometry that was the original defect on the scrubber before it was
  /// fixed; sitting in the same row as that fixed scrubber made the
  /// mismatch obvious.
  static const double restTrackHeight = 6.0;

  /// Track height while hovered, mirroring `ProgressBarSurface`'s own
  /// hover growth.
  static const double activeTrackHeight = 8.0;

  /// Inactive (unfilled) track alpha, brought up from the original 0.25 to
  /// the scrubber's own secondary-layer alpha for the same legibility gain.
  static const double inactiveTrackAlpha = 0.40;

  @override
  State<VolumeSurface> createState() => _VolumeSurfaceState();
}

class _VolumeSurfaceState extends State<VolumeSurface> {
  bool _hovering = false;

  IconData get _glyph {
    if (widget.volume == 0) return Icons.volume_off_rounded;
    if (widget.volume < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ControlButton(
          key: VolumeSurface.muteKey,
          icon: _glyph,
          iconSize: 20,
          size: 40,
          tooltip: widget.volume == 0 ? 'Unmute' : 'Mute',
          onTap: widget.onToggleMute,
        ),
        MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: SizedBox(
            key: VolumeSurface.sliderKey,
            width: VolumeSurface.sliderWidth,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(
                end: _hovering
                    ? VolumeSurface.activeTrackHeight
                    : VolumeSurface.restTrackHeight,
              ),
              duration: DepthTokens.motionFast,
              curve: DepthTokens.curveStandard,
              builder: (context, trackHeight, _) {
                return SliderTheme(
                  data: SliderThemeData(
                    trackHeight: trackHeight,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(
                      alpha: VolumeSurface.inactiveTrackAlpha,
                    ),
                    thumbColor: Colors.white,
                    overlayColor: Colors.white.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    value: (widget.volume / 100.0).clamp(0.0, 1.0),
                    onChanged: (v) => widget.onVolumeChanged(v * 100.0),
                  ),
                );
              },
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

  /// Trimmed from 4 to 0 to close real overflows in `ChromePanel`'s
  /// equal-flex right slot. Still load-bearing after `PanelMetrics`'
  /// tablet-branch width factor and per-tier `horizontalPadding` closed the
  /// worse 600–689px shortfall: at 4px this cluster's 3 buttons cost 128px,
  /// which still doesn't fit the desktop breakpoint's own slot (900px was
  /// -6px short, 920px exactly 0px, at 4px gap) — 0 gaps is the narrowest
  /// this cluster can get without shrinking a button below its own 40px
  /// spec. See `chrome_panel_overflow_test.dart` for the full per-width
  /// budget with this value.
  static const double gap = 0.0;

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
