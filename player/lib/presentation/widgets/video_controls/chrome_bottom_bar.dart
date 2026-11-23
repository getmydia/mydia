import 'package:material_ui/material_ui.dart';

import '../../../core/layout/breakpoints.dart';
import '../glass_surface.dart';

/// Responsive sizing for the full-width playback bottom bar.
///
/// Carries the tier flags that used to live on `PanelMetrics`. The bar spans
/// the viewport, so there is no max width or bottom offset: only the flags
/// that decide which controls render and how they are spaced.
@immutable
class ChromeMetrics {
  /// Whether to show the volume cluster. Phones have hardware volume buttons,
  /// so the cluster is dropped there to buy space.
  final bool showVolume;

  /// Whether controls should use enlarged touch hit areas (finger size, not
  /// window size).
  final bool touchTargets;

  /// Whether the in-bar transport collapses to play/pause only. About
  /// horizontal room, unlike [touchTargets], which is about finger size.
  final bool compactTransport;

  /// Whether `SecondaryCluster`'s quality button renders. True at every tier;
  /// kept as a per-tier lever for a future fifth control.
  final bool showQuality;

  /// Whether `SecondaryCluster`'s always-on-top button renders. Desktop tier
  /// only: a fifth button overflows the tablet and mobile budgets.
  final bool showAlwaysOnTop;

  /// Horizontal gap between `SecondaryCluster`'s buttons.
  final double secondaryGap;

  /// Horizontal padding on both sides of the bar: 24 from
  /// [Breakpoints.mobile] up, 16 below.
  final double horizontalPadding;

  const ChromeMetrics({
    required this.showVolume,
    required this.touchTargets,
    required this.compactTransport,
    required this.showQuality,
    required this.showAlwaysOnTop,
    required this.secondaryGap,
    required this.horizontalPadding,
  });

  /// Right inset for a corner overlay. Constant across tiers.
  static const double cornerInsetRight = 24.0;

  /// Gap between the bar's top edge and a corner overlay's bottom edge.
  static const double cornerGap = 12.0;

  /// The bar's rendered height, derived from the bar's own layout constants.
  double get barHeight => ChromeBottomBar.heightFor(touchTargets: touchTargets);

  /// Bottom inset for a corner overlay so it always clears the bar.
  double get cornerInsetBottom => barHeight + cornerGap;

  /// Resolve metrics for a viewport [width] and the viewer's input type,
  /// using the breakpoints in `core/layout/breakpoints.dart`
  /// (mobile < 600, tablet 600-899, desktop >= 900).
  factory ChromeMetrics.resolve({
    required double width,
    required bool touchPrimary,
  }) {
    final compactTransport = width < Breakpoints.mobile;
    final touchTargets = touchPrimary || width < Breakpoints.mobile;
    final horizontalPadding = width >= Breakpoints.mobile ? 24.0 : 16.0;

    if (width >= Breakpoints.tablet) {
      return ChromeMetrics(
        showVolume: true,
        touchTargets: touchTargets,
        compactTransport: compactTransport,
        showQuality: true,
        showAlwaysOnTop: true,
        secondaryGap: 8,
        horizontalPadding: horizontalPadding,
      );
    }
    if (width >= Breakpoints.mobile) {
      return ChromeMetrics(
        showVolume: true,
        touchTargets: touchTargets,
        compactTransport: compactTransport,
        showQuality: true,
        showAlwaysOnTop: false,
        secondaryGap: 6,
        horizontalPadding: horizontalPadding,
      );
    }
    return ChromeMetrics(
      showVolume: false,
      touchTargets: touchTargets,
      compactTransport: compactTransport,
      showQuality: true,
      showAlwaysOnTop: false,
      secondaryGap: 0,
      horizontalPadding: horizontalPadding,
    );
  }

  /// Fine-pointer shorthand for [resolve], for assertions about width alone.
  @visibleForTesting
  factory ChromeMetrics.forWidth(double width) =>
      ChromeMetrics.resolve(width: width, touchPrimary: false);
}

/// The full-width playback bottom bar.
///
/// A timecode row, the scrubber, then a control row: volume on the left, the
/// transport centred, the secondary cluster in a pill on the right. Slot-based
/// so it can be tested without a media_kit `Player`.
class ChromeBottomBar extends StatelessWidget {
  /// Timecode row above the scrubber.
  final Widget timecodes;

  /// Scrubber row.
  final Widget scrubber;

  /// Right group of the control row, wrapped in a pill by the bar.
  final Widget secondary;

  /// Centre group of the control row.
  final Widget? transport;

  /// Left group of the control row.
  ///
  /// Pass this **unconditionally** rather than gating construction on
  /// [ChromeMetrics.showVolume]: the bar hides it with a [Visibility] that
  /// keeps it mounted, so its `State` (e.g. the pre-mute volume) survives a
  /// breakpoint crossing. Pass `null` only when there is no volume control.
  final Widget? volume;

  final ChromeMetrics metrics;

  const ChromeBottomBar({
    super.key,
    required this.metrics,
    required this.timecodes,
    required this.scrubber,
    required this.secondary,
    this.transport,
    this.volume,
  });

  /// Vertical padding above the timecodes and below the control row.
  static const double verticalPadding = 12;

  /// Height of the timecode row. Remote timecodes (18 px) fit.
  static const double timecodeHeight = 24;

  /// Gap between the timecode row and the scrubber.
  static const double timecodeGap = 4;

  /// Gap between the scrubber and the control row.
  static const double rowGap = 8;

  /// Height of the control row.
  static const double controlRowHeight = 44;

  /// Scrubber row height with an enlarged touch target, matching
  /// `ProgressBarSurface`.
  static const double _scrubberTouchHeight = 44;

  /// Scrubber row height with a fine pointer, matching `ProgressBarSurface`.
  static const double _scrubberFineHeight = 32;

  /// Horizontal inset between the secondary cluster and its pill edge.
  static const double _pillInset = 4;

  /// Key on the pill wrapping [secondary].
  static const Key secondaryPillKey = Key('osd-secondary-pill');

  /// The bar's rendered height: the sum of the layout constants above.
  static double heightFor({required bool touchTargets}) =>
      verticalPadding * 2 +
      timecodeHeight +
      timecodeGap +
      (touchTargets ? _scrubberTouchHeight : _scrubberFineHeight) +
      rowGap +
      controlRowHeight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.horizontalPadding,
        vertical: verticalPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: timecodeHeight, child: timecodes),
          const SizedBox(height: timecodeGap),
          SizedBox(
            height: metrics.touchTargets
                ? _scrubberTouchHeight
                : _scrubberFineHeight,
            child: scrubber,
          ),
          const SizedBox(height: rowGap),
          SizedBox(
            height: controlRowHeight,
            child: Row(
              children: [
                // Equal flex on both sides, always, so the transport's centre
                // lands on the bar's centre whether or not the sides have
                // content. Special-casing an empty side to flex 0 once pinned
                // the transport up to ~187 px off-centre on mobile widths.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _volumeSlot(),
                  ),
                ),
                transport ?? const SizedBox.shrink(),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: GlassSurface.osdPill(
                      key: secondaryPillKey,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _pillInset,
                        ),
                        child: secondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Renders [volume], keeping it mounted across a [ChromeMetrics.showVolume]
  /// flip. `maintainSize: false` keeps it zero-size when hidden;
  /// `maintainAnimation: false` still preserves `State` (the point of this
  /// [Visibility]) while leaving hidden tickers disabled.
  Widget _volumeSlot() {
    final child = volume;
    if (child == null) return const SizedBox.shrink();
    return Visibility(
      visible: metrics.showVolume,
      maintainState: true,
      child: child,
    );
  }
}
