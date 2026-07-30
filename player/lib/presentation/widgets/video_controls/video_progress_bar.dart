import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/player/duration_override.dart';
import '../../../core/theme/depth_tokens.dart';

/// The scrubber's painting and gesture surface, free of any [Player]
/// dependency so it can be widget-tested directly.
///
/// [VideoProgressBar] is the thin `StreamBuilder` wrapper that feeds this.
class ProgressBarSurface extends StatefulWidget {
  /// Played fraction, 0..1. Values outside the range are clamped.
  final double progress;

  /// Buffered fraction, 0..1. Values outside the range are clamped.
  final double buffered;

  /// Called with the target fraction when the user taps or finishes a drag.
  final ValueChanged<double>? onSeekTo;

  /// Called with the live fraction during a drag.
  final ValueChanged<double>? onSeekUpdate;

  /// Called when a drag begins.
  final VoidCallback? onSeekStart;

  /// Called when a drag ends.
  final VoidCallback? onSeekEnd;

  /// Whether to use the 44px touch hit area instead of the 32px pointer one.
  final bool touchTarget;

  const ProgressBarSurface({
    super.key,
    required this.progress,
    required this.buffered,
    this.onSeekTo,
    this.onSeekUpdate,
    this.onSeekStart,
    this.onSeekEnd,
    this.touchTarget = false,
  });

  static const Key trackKey = Key('progress-track');
  static const Key bufferedKey = Key('progress-buffered');
  static const Key playedKey = Key('progress-played');
  static const Key thumbKey = Key('progress-thumb');

  @override
  State<ProgressBarSurface> createState() => _ProgressBarSurfaceState();
}

class _ProgressBarSurfaceState extends State<ProgressBarSurface> {
  bool _hovering = false;
  bool _seeking = false;
  double _seekFraction = 0;

  /// Whether a seek can actually be committed. Without [onSeekTo] a tap or
  /// drag has nowhere to land, so the surface offers no interaction at all
  /// rather than an affordance that goes nowhere: the gesture handlers and
  /// the hover tracking are both dropped in [build], and [_active] stays
  /// false even if the widget is updated out of seekability mid-hover.
  bool get _seekable => widget.onSeekTo != null;

  bool get _active => _seekable && (_hovering || _seeking);

  double get _trackHeight => _active ? 8.0 : 6.0;

  double get _thumbSize => _active
      ? VideoProgressBar.activeThumbSize
      : VideoProgressBar.restingThumbSize;

  double get _displayed =>
      (_seeking ? _seekFraction : widget.progress).clamp(0.0, 1.0);

  void _emit(double dx, double width, {required bool commit}) {
    final fraction = width > 0 ? (dx / width).clamp(0.0, 1.0) : 0.0;
    setState(() => _seekFraction = fraction);
    if (commit) {
      widget.onSeekTo?.call(fraction);
    } else {
      widget.onSeekUpdate?.call(fraction);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final bar = _bar(width);

        // Read-only usage (no `onSeekTo`) gets the bar and nothing else: no
        // gesture handlers to enter the seeking state a caller cannot
        // commit, and no hover tracking to light up the active affordance.
        if (!_seekable) return bar;

        return MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _emit(d.localPosition.dx, width, commit: true),
            onHorizontalDragStart: (d) {
              setState(() => _seeking = true);
              widget.onSeekStart?.call();
              _emit(d.localPosition.dx, width, commit: false);
            },
            onHorizontalDragUpdate: (d) =>
                _emit(d.localPosition.dx, width, commit: false),
            onHorizontalDragEnd: (_) {
              widget.onSeekTo?.call(_seekFraction);
              setState(() => _seeking = false);
              widget.onSeekEnd?.call();
            },
            child: bar,
          ),
        );
      },
    );
  }

  /// The painted bar: base track, buffered fill, played fill, and thumb.
  /// Identical whether or not the surface is seekable — only the wrappers
  /// [build] puts around it differ.
  Widget _bar(double width) {
    final buffered = widget.buffered.clamp(0.0, 1.0);

    return SizedBox(
      width: double.infinity,
      height: widget.touchTarget ? 44 : 32,
      child: Center(
        child: SizedBox(
          height: VideoProgressBar.activeThumbSize,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              // Base track
              Center(
                child: AnimatedContainer(
                  key: ProgressBarSurface.trackKey,
                  duration: DepthTokens.motionFast,
                  curve: DepthTokens.curveStandard,
                  height: _trackHeight,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(_trackHeight / 2),
                  ),
                ),
              ),
              // Buffered — a direct (non-`Center`-wrapped) Stack child so the
              // Stack's own `alignment: centerLeft` left-anchors it. A
              // `Center` wrapper here is a bug: `FractionallySizedBox` shrinks
              // itself to the fraction
              // (`RenderFractionallySizedOverflowBox.size =
              // constraints.constrain(child.size)`), so by the time its own
              // `alignment: centerLeft` would apply, its size already equals
              // its child's — the alignment becomes a no-op, and the
              // surrounding `Center` then centers the shrunken bar in the
              // middle of the track instead of anchoring it to the left edge.
              FractionallySizedBox(
                key: ProgressBarSurface.bufferedKey,
                alignment: Alignment.centerLeft,
                widthFactor: buffered,
                child: AnimatedContainer(
                  duration: DepthTokens.motionFast,
                  curve: DepthTokens.curveStandard,
                  height: _trackHeight,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.40),
                    borderRadius: BorderRadius.circular(_trackHeight / 2),
                  ),
                ),
              ),
              // Played — see the buffered layer's comment above; same
              // reasoning applies here.
              FractionallySizedBox(
                key: ProgressBarSurface.playedKey,
                alignment: Alignment.centerLeft,
                widthFactor: _displayed,
                child: AnimatedContainer(
                  duration: DepthTokens.motionFast,
                  curve: DepthTokens.curveStandard,
                  height: _trackHeight,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(_trackHeight / 2),
                  ),
                ),
              ),
              // Thumb — always present, unlike the previous hover-only
              // implementation. Centered exactly on the progress fraction: at
              // the 0.0/1.0 extremes it bleeds half its own width past the
              // track ends, which is the conventional scrubber look and is
              // accounted for by the glass bar's own padding in the caller.
              //
              // Tweens its own size directly, rather than pairing an
              // `AnimatedContainer` with a `Positioned.left` computed from the
              // synchronous (already-updated) `_thumbSize`. That pairing let
              // `left` jump to its new value instantly while `width`/`height`
              // animated toward it over 150ms, producing a ~2px lateral wobble
              // as the implied centre (`left + width / 2`) briefly disagreed
              // with the target. Deriving `left` from the same interpolated
              // value on every animation frame keeps the centre fixed
              // throughout the transition.
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: _thumbSize),
                duration: DepthTokens.motionFast,
                curve: DepthTokens.curveStandard,
                builder: (context, size, _) {
                  return Positioned(
                    left: (width * _displayed) - (size / 2),
                    child: Container(
                      key: ProgressBarSurface.thumbKey,
                      width: size,
                      height: size,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x40000000), // black @ 0.25
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A seekable progress bar for video playback.
///
/// Thin `StreamBuilder` wrapper that feeds player position, duration, and
/// buffer into [ProgressBarSurface], which does the painting and gestures.
class VideoProgressBar extends StatelessWidget {
  /// The media_kit player instance.
  final Player player;

  /// Called when seeking starts.
  final VoidCallback? onSeekStart;

  /// Called when seeking ends.
  final VoidCallback? onSeekEnd;

  /// Called during seeking with the current seek position.
  final ValueChanged<Duration>? onSeekUpdate;

  /// Whether to use the 44px touch hit area.
  final bool touchTarget;

  const VideoProgressBar({
    super.key,
    required this.player,
    this.onSeekStart,
    this.onSeekEnd,
    this.onSeekUpdate,
    this.touchTarget = false,
  });

  /// Thumb diameter at rest.
  static const double restingThumbSize = 12.0;

  /// Thumb diameter while hovered or scrubbing.
  static const double activeThumbSize = 16.0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: player.stream.duration,
          initialData: player.state.duration,
          builder: (context, durationSnapshot) {
            return StreamBuilder<Duration>(
              stream: player.stream.buffer,
              initialData: player.state.buffer,
              builder: (context, bufferSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = DurationOverride.getDuration(
                  durationSnapshot.data ?? Duration.zero,
                );
                final buffer = bufferSnapshot.data ?? Duration.zero;
                final totalMs = duration.inMilliseconds.toDouble();

                double fraction(Duration d) => totalMs > 0
                    ? (d.inMilliseconds / totalMs).clamp(0.0, 1.0)
                    : 0.0;

                Duration at(double f) =>
                    Duration(milliseconds: (totalMs * f).round());

                return ProgressBarSurface(
                  progress: fraction(position),
                  buffered: fraction(buffer),
                  touchTarget: touchTarget,
                  onSeekStart: onSeekStart,
                  onSeekEnd: onSeekEnd,
                  onSeekUpdate: (f) => onSeekUpdate?.call(at(f)),
                  onSeekTo: (f) => player.seek(at(f)),
                );
              },
            );
          },
        );
      },
    );
  }
}
