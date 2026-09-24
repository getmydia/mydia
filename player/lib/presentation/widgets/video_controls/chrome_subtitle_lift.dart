import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/player/subtitle_position.dart';
import '../../../core/theme/depth_tokens.dart';
import 'playback_chrome.dart' show ChromeAnimation;

/// Moves the subtitles' bottom edge to [bottom] logical pixels above the
/// bottom of the video box, over [duration] where the renderer can animate.
abstract interface class SubtitleLift {
  void apply(double bottom, {required Duration duration});
}

/// Keeps subtitles above the control panel while it is shown.
///
/// media_kit's stock controls lift `SubtitleView` while their bar shows;
/// `PlaybackChrome` replaces those controls, so it has to do the same or the
/// panel covers the line the viewer paused to read.
///
/// Wrap the panel's `ChromeSlide` from outside, so the slide's translate
/// never reaches the measurement and the subtitle aims for where the panel
/// settles, not every frame of its arrival. Show and hide follow
/// [ChromeAnimation] the way `ChromeToastObstruction` does: the lift leaves
/// the moment a hide starts. With no [ChromeAnimation] above, the panel
/// counts as shown.
class ChromeSubtitleLift extends StatefulWidget {
  const ChromeSubtitleLift({
    super.key,
    required this.lift,
    required this.referenceBox,
    required this.child,
  });

  /// Null leaves subtitles alone entirely.
  final SubtitleLift? lift;

  /// The box subtitles are drawn in. Its bottom edge is what the lift is
  /// measured from.
  final RenderBox? Function() referenceBox;

  final Widget child;

  /// Space between the subtitle and the panel's top edge.
  static const double gap = 12;

  @override
  State<ChromeSubtitleLift> createState() => _ChromeSubtitleLiftState();
}

class _ChromeSubtitleLiftState extends State<ChromeSubtitleLift> {
  Animation<double>? _animation;
  Rect? _rect;
  double? _applied;
  bool _syncScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Always registered, lift or no lift: a null lift can still turn
    // non-null later (`didUpdateWidget`), and by then it is too late to
    // start depending on `ChromeAnimation` -- this build already happened.
    final animation = ChromeAnimation.maybeOf(context);
    if (!identical(animation, _animation)) {
      _animation?.removeStatusListener(_handleStatus);
      _animation = animation;
      _animation?.addStatusListener(_handleStatus);
    }
    _scheduleSync();
  }

  @override
  void didUpdateWidget(ChromeSubtitleLift oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lift != widget.lift) {
      final oldLift = oldWidget.lift;
      if (oldLift != null) _resetToRest(oldLift);
      _applied = null;
      _scheduleSync();
    }
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_handleStatus);
    final lift = widget.lift;
    if (lift != null) _resetToRest(lift);
    super.dispose();
  }

  /// Schedules [lift] back to rest after the frame, if the last value we
  /// applied to it was above rest. Shared by [dispose] (this widget is
  /// unmounting) and [didUpdateWidget] (this widget is switching to a
  /// different [SubtitleLift] and the departing one must not keep the
  /// subtitle lifted with nothing left to bring it back down).
  void _resetToRest(SubtitleLift lift) {
    final applied = _applied;
    if (applied == null || applied <= kSubtitleRestPadding) return;
    // The tree may be locked (dispose) or mid-rebuild (didUpdateWidget);
    // the frame's end is the first safe moment either way, since `apply`
    // calls `setState` on `SubtitleView`.
    WidgetsBinding.instance.addPostFrameCallback((_) => lift.apply(
          kSubtitleRestPadding,
          duration: DepthTokens.motionMedium,
        ));
  }

  void _handleStatus(AnimationStatus status) => _scheduleSync();

  void _handlePainted(Rect rect) {
    if (rect == _rect) return;
    _rect = rect;
    _scheduleSync();
  }

  bool get _shown => _animation?.status.isForwardOrCompleted ?? true;

  double _target() {
    final rect = _rect;
    final reference = widget.referenceBox();
    if (!_shown || rect == null || reference == null || !reference.hasSize) {
      return kSubtitleRestPadding;
    }
    return math.max(
      kSubtitleRestPadding,
      reference.size.height - rect.top + ChromeSubtitleLift.gap,
    );
  }

  /// Deferred to after the frame for the same reason as `ToastObstruction`:
  /// this runs from paint and from dependency changes, and the lift calls
  /// `setState` on `SubtitleView`.
  void _scheduleSync() {
    if (_syncScheduled || widget.lift == null) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      final lift = widget.lift;
      if (!mounted || lift == null) return;
      final target = _target();
      if (target == _applied) return;
      final rising = target > (_applied ?? kSubtitleRestPadding);
      _applied = target;
      lift.apply(
        target,
        duration: rising ? DepthTokens.motionFast : DepthTokens.motionMedium,
      );
    });
  }

  @override
  Widget build(BuildContext context) => _PaintedRectReporter(
        // Always wrapped, lift or no lift: swapping the element shape when
        // a lift arrives or leaves would remount `widget.child`'s subtree,
        // dropping its State. `_handlePainted` is harmless with no lift --
        // `_scheduleSync` no-ops on a null one.
        referenceBox: widget.referenceBox,
        onPainted: _handlePainted,
        child: widget.child,
      );
}

class _PaintedRectReporter extends SingleChildRenderObjectWidget {
  const _PaintedRectReporter({
    required this.referenceBox,
    required this.onPainted,
    super.child,
  });

  final RenderBox? Function() referenceBox;
  final ValueChanged<Rect> onPainted;

  @override
  _RenderPaintedRectReporter createRenderObject(BuildContext context) =>
      _RenderPaintedRectReporter(referenceBox, onPainted);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPaintedRectReporter renderObject,
  ) {
    renderObject
      ..referenceBox = referenceBox
      ..onPainted = onPainted;
  }
}

/// Reports this box's rect in the reference box's coordinates each time it
/// paints. A hidden chrome fades to opacity 0 and stops painting, which
/// keeps the last settled rect for the next show.
class _RenderPaintedRectReporter extends RenderProxyBox {
  _RenderPaintedRectReporter(this.referenceBox, this.onPainted);

  RenderBox? Function() referenceBox;
  ValueChanged<Rect> onPainted;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final reference = referenceBox();
    if (reference == null || !reference.attached || !reference.hasSize) {
      return;
    }
    onPainted(localToGlobal(Offset.zero, ancestor: reference) & size);
  }
}

/// Applies a lift to both subtitle renderers of a media_kit `Video`.
///
/// Text goes through `SubtitleView`'s padding, which animates. Bitmap
/// tracks go to mpv as `sub-pos`, which jumps. Both are written every time:
/// whichever renderer is idle ignores its value, so this never needs to
/// know which one `subtitle_render.dart` has active.
class VideoStateSubtitleLift implements SubtitleLift {
  VideoStateSubtitleLift(this.state);

  final VideoState state;

  // `PlaybackChrome` builds a fresh `VideoStateSubtitleLift(state)` on every
  // rebuild. Value equality on the underlying `state` lets
  // `ChromeSubtitleLift.didUpdateWidget` recognise that as "the same lift",
  // not a swap, so an unchanged target is not re-applied every rebuild.
  @override
  bool operator ==(Object other) =>
      other is VideoStateSubtitleLift && identical(other.state, state);

  @override
  int get hashCode => identityHashCode(state);

  @override
  void apply(double bottom, {required Duration duration}) {
    if (!state.mounted) return;
    state.setSubtitleViewPadding(
      EdgeInsets.fromLTRB(16, 0, 16, bottom),
      duration: duration,
    );

    final box = state.context.size;
    if (box == null) return;
    final player = state.widget.controller.player;
    unawaited(applySubtitlePosition(
      player,
      subPosForLift(
        lift: bottom,
        box: box,
        videoWidth: player.state.width,
        videoHeight: player.state.height,
      ),
    ));
  }
}
