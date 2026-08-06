import 'dart:math' as math;

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

  /// When null the quality button is omitted entirely, which is how the
  /// player screen hides it for a source that has only one rung to offer.
  /// Not a platform signal: it was web-only while `player_screen.dart` gated
  /// the callback on `PlatformFeatures.isWeb`, and that gate is gone.
  final VoidCallback? onQualityTap;
  final VoidCallback? onFullscreenTap;
  final VoidCallback? onAlwaysOnTopTap;

  final int audioTrackCount;
  final int subtitleTrackCount;
  final String? selectedAudioLabel;
  final String? selectedSubtitleLabel;
  final String? selectedQualityLabel;
  final bool isFullscreen;
  final bool isAlwaysOnTop;

  const SecondaryCluster({
    super.key,
    this.onSubtitleTap,
    this.onAudioTap,
    this.onQualityTap,
    this.onFullscreenTap,
    this.onAlwaysOnTopTap,
    this.audioTrackCount = 0,
    this.subtitleTrackCount = 0,
    this.selectedAudioLabel,
    this.selectedSubtitleLabel,
    this.selectedQualityLabel,
    this.isFullscreen = false,
    this.isAlwaysOnTop = false,
    this.gap = 0.0,
  });

  static const Key subtitlesKey = Key('secondary-subtitles');
  static const Key audioKey = Key('secondary-audio');
  static const Key qualityKey = Key('secondary-quality');
  static const Key fullscreenKey = Key('secondary-fullscreen');
  static const Key alwaysOnTopKey = Key('secondary-always-on-top');

  /// Horizontal gap between this cluster's buttons.
  ///
  /// Tier-dependent, supplied by the caller from `PanelMetrics`: 8 on
  /// desktop, 6 on tablet, 0 on mobile. This used to be a hard `0.0`
  /// constant, which was the narrowest the cluster could go and was needed
  /// to squeeze a 4th 40px button into the desktop tier at all. Compacting
  /// the transport cluster (see `transport_cluster.dart`) freed enough width
  /// that desktop and tablet can afford real separation again, while mobile
  /// still runs at the floor.
  final double gap;

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
          iconSize: 18,
          size: 32,
          enabled: subtitlesEnabled,
          tooltip: subtitlesEnabled
              ? 'Subtitles: ${selectedSubtitleLabel ?? 'Off'}'
              : 'No subtitles',
          onTap: subtitlesEnabled ? onSubtitleTap : null,
        ),
        SizedBox(width: gap),
        ControlButton(
          key: audioKey,
          icon: Icons.audiotrack_rounded,
          iconSize: 18,
          size: 32,
          enabled: audioEnabled,
          tooltip: audioEnabled
              ? 'Audio: ${selectedAudioLabel ?? 'Default'}'
              : 'No audio tracks',
          onTap: audioEnabled ? onAudioTap : null,
        ),
        if (onQualityTap != null) ...[
          SizedBox(width: gap),
          ControlButton(
            key: qualityKey,
            icon: Icons.hd_rounded,
            iconSize: 18,
            size: 32,
            // No invented default. This used to read "Auto", describing
            // adaptive streaming the server has never done — it emits a
            // single rendition per session. A caller that cannot name the
            // current rung gets the bare noun rather than a fiction.
            tooltip: selectedQualityLabel == null
                ? 'Quality'
                : 'Quality: $selectedQualityLabel',
            onTap: onQualityTap,
          ),
        ],
        SizedBox(width: gap),
        ControlButton(
          key: fullscreenKey,
          icon: isFullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          iconSize: 18,
          size: 32,
          tooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
          onTap: onFullscreenTap,
        ),
        if (onAlwaysOnTopTap != null) ...[
          SizedBox(width: gap),
          Transform.rotate(
            // Same icon glyph either way (no dedicated "unpin" glyph exists in
            // the rounded family — see icon_family_test.dart's _rounded-only
            // rule). Tilted = not pinned, upright = pinned — the same
            // convention as Windows/browser "pin tab" toggles.
            angle: isAlwaysOnTop ? 0 : -math.pi / 4,
            child: ControlButton(
              key: alwaysOnTopKey,
              icon: Icons.push_pin_rounded,
              iconSize: 18,
              size: 32,
              tooltip: isAlwaysOnTop ? 'Exit always on top' : 'Always on top',
              onTap: onAlwaysOnTopTap,
            ),
          ),
        ],
      ],
    );
  }
}
