import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/player/input_capabilities.dart';
import '../../../core/theme/palette.dart';
import '../../../core/theme/surface_roles.dart';
import '../../../core/ui/reduced_motion.dart';
import '../focus_emphasis.dart';
import 'press_scale.dart';

/// One choice of an [AppSegmented].
@immutable
class AppSegment<T> {
  const AppSegment({
    required this.value,
    required this.label,
    this.semanticLabel,
  });

  final T value;

  /// The text drawn in the segment. Keep it short: segments share one row.
  final String label;

  /// What a screen reader announces instead of [label], for a label that is
  /// an abbreviation (the subtitle row's S, M, L, XL).
  final String? semanticLabel;
}

/// A row of two to four fixed choices with a sliding thumb on the selected
/// one.
///
/// The whole control is one focus stop. Left and Right move the selection
/// directly and stop at the ends without wrapping. At an end a held arrow is
/// consumed so it cannot overshoot out of the control, while a fresh press
/// moves focus on as usual. Up and Down traverse as usual. Select does nothing extra. Sizes itself to its widest label
/// times the segment count; give it a tight width to fill a column instead.
class AppSegmented<T> extends StatefulWidget {
  const AppSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
  }) : assert(
         segments.length >= 2 && segments.length <= 4,
         'AppSegmented holds two to four segments',
       );

  final List<AppSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Names the group for a screen reader.
  final String? semanticLabel;

  static const trackKey = ValueKey('app-segmented-track');
  static const thumbKey = ValueKey('app-segmented-thumb');

  /// Finder handle for segment [index]'s hit area.
  static ValueKey<String> segmentKey(int index) =>
      ValueKey('app-segmented-segment-$index');

  static const double trackRadius = 11;
  static const double trackPadding = 3;
  static const double thumbRadius = trackRadius - trackPadding;
  static const double segmentMinHeight = 30;
  static const double segmentMinWidth = 44;
  static const double hitHeight = 44;
  static const Duration slide = Duration(milliseconds: 160);

  @override
  State<AppSegmented<T>> createState() => _AppSegmentedState<T>();
}

/// Space above and below the track inside the 44 high hit area.
const double _trackMargin =
    (AppSegmented.hitHeight -
        AppSegmented.segmentMinHeight -
        2 * AppSegmented.trackPadding) /
    2;

class _AppSegmentedState<T> extends State<AppSegmented<T>> {
  bool _focusHighlight = false;

  int get _selectedIndex =>
      widget.segments.indexWhere((s) => s.value == widget.selected);

  void _select(int index) {
    if (index == _selectedIndex) return;
    widget.onChanged(widget.segments[index].value);
  }

  /// Left and Right move the selection. At an end a held arrow (a key
  /// repeat) is consumed, so it cannot overshoot out of the control, but a
  /// fresh press passes on to ordinary traversal: in a settings row that is
  /// how Left still reaches the rail.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final int visualDelta;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      visualDelta = -1;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      visualDelta = 1;
    } else {
      return KeyEventResult.ignored;
    }
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final delta = rtl ? -visualDelta : visualDelta;
    final current = _selectedIndex;
    final next = current < 0
        ? (delta > 0 ? 0 : widget.segments.length - 1)
        : current + delta;
    if (next < 0 || next >= widget.segments.length) {
      // No wrap.
      return event is KeyRepeatEvent
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    _select(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final roles = context.surfaceRoles;
    final duration = ReducedMotion.duration(context, AppSegmented.slide);
    final selectedIndex = _selectedIndex;
    final count = widget.segments.length;
    // On the television tier FocusEmphasis draws the ring; elsewhere the
    // control draws its own, outside layout like AppSwitch's.
    final ownRing = _focusHighlight && !InputCapabilities.directionalPrimary;

    final thumb = selectedIndex < 0
        ? const SizedBox.shrink()
        : AnimatedAlign(
            duration: duration,
            curve: Curves.easeOut,
            // Directional: in RTL the Row lays segment 0 out on the right.
            alignment: AlignmentDirectional(
              -1 + 2 * selectedIndex / (count - 1),
              0,
            ),
            child: FractionallySizedBox(
              widthFactor: 1 / count,
              heightFactor: 1,
              child: DecoratedBox(
                key: AppSegmented.thumbKey,
                decoration: BoxDecoration(
                  color: palette.surfaceBright,
                  borderRadius: BorderRadius.circular(AppSegmented.thumbRadius),
                  border: Border.all(color: roles.rim),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 1,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          );

    final track = Container(
      key: AppSegmented.trackKey,
      decoration: BoxDecoration(
        color: palette.surfaceLow,
        borderRadius: BorderRadius.circular(AppSegmented.trackRadius),
        border: Border.all(color: roles.hairlineStrong),
      ),
      foregroundDecoration: ownRing
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(AppSegmented.trackRadius),
              border: Border.all(color: Colors.white, width: 1.5),
            )
          : null,
    );

    // Each segment's hit area is the full 44 high box around the shorter
    // track, with the label inside it, so a near miss above or below still
    // selects. The track and thumb are painted behind, inset to match.
    final segments = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSegmented.trackPadding,
      ),
      child: Row(
        children: [
          for (var i = 0; i < count; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == selectedIndex,
                inMutuallyExclusiveGroup: true,
                label:
                    widget.segments[i].semanticLabel ??
                    widget.segments[i].label,
                onTap: () => _select(i),
                child: ExcludeSemantics(
                  child: GestureDetector(
                    key: AppSegmented.segmentKey(i),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _select(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: _trackMargin + AppSegmented.trackPadding,
                      ),
                      child: _SegmentLabel(
                        label: widget.segments[i].label,
                        selected: i == selectedIndex,
                        duration: duration,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final control = IntrinsicWidth(
      child: Stack(
        children: [
          Positioned.fill(
            top: _trackMargin,
            bottom: _trackMargin,
            child: track,
          ),
          Positioned.fill(
            top: _trackMargin + AppSegmented.trackPadding,
            bottom: _trackMargin + AppSegmented.trackPadding,
            left: AppSegmented.trackPadding,
            right: AppSegmented.trackPadding,
            child: thumb,
          ),
          segments,
        ],
      ),
    );

    return FocusEmphasis(
      borderRadius: BorderRadius.circular(AppSegmented.trackRadius),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: widget.semanticLabel,
        // Sees the arrows as they bubble up from the detector's node, before
        // the app's directional traversal shortcuts do. Adds no focus stop.
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: FocusableActionDetector(
            onShowFocusHighlight: (v) => setState(() => _focusHighlight = v),
            shortcuts: const {
              // Selection already follows Left and Right, so activation has
              // nothing to do. Stopping the key here keeps it from reaching an
              // ancestor that would treat it as activating something else.
              SingleActivator(LogicalKeyboardKey.select):
                  DoNothingAndStopPropagationIntent(),
              SingleActivator(LogicalKeyboardKey.enter):
                  DoNothingAndStopPropagationIntent(),
              SingleActivator(LogicalKeyboardKey.space):
                  DoNothingAndStopPropagationIntent(),
              SingleActivator(LogicalKeyboardKey.gameButtonA):
                  DoNothingAndStopPropagationIntent(),
            },
            // Inside the detector, so PressScale's focus node is below the
            // focused one and only pointer presses scale the control.
            child: PressScale(child: control),
          ),
        ),
      ),
    );
  }
}

class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({
    required this.label,
    required this.selected,
    required this.duration,
  });

  final String label;
  final bool selected;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: AppSegmented.segmentMinHeight,
        minWidth: AppSegmented.segmentMinWidth,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: duration,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? palette.textPrimary : palette.textSecondary,
            ),
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
