import 'package:material_ui/material_ui.dart';

import '../../../core/layout/breakpoints.dart';
import 'chrome_title_block.dart';

/// Responsive sizing for the full-width playback bottom bar.
///
/// Carries the tier flags of the retired floating panel's metrics. The bar
/// spans the viewport, so there is no max width or bottom offset: only the
/// flags that decide which controls render and how they are spaced.
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
  /// [Breakpoints.mobile] up, 16 below, 12 when [compactTouch].
  final double horizontalPadding;

  /// A touch phone, in either orientation: touch input and a shortest side
  /// under [Breakpoints.mobile].
  ///
  /// A landscape phone is ~350 px tall, so the full bar (timecodes, scrubber
  /// and a control row) put lifted subtitles mid-screen. This tier draws
  /// [CompactChromeBottomBar] instead, a single scrubber row, and moves the
  /// track buttons to the top bar.
  final bool compactTouch;

  /// The ten-foot remote tier: directional input drives the chrome. Only
  /// sizes the title block; the bar's other flags are unaffected.
  final bool remote;

  const ChromeMetrics({
    required this.showVolume,
    required this.touchTargets,
    required this.compactTransport,
    required this.showQuality,
    required this.showAlwaysOnTop,
    required this.secondaryGap,
    required this.horizontalPadding,
    this.compactTouch = false,
    this.remote = false,
  });

  /// Whether a viewport of [size] with this input is [compactTouch]. Shared
  /// with the parts of the chrome that do not hold a [ChromeMetrics].
  static bool isCompactTouch(Size size, {required bool touchPrimary}) =>
      touchPrimary && size.shortestSide < Breakpoints.mobile;

  /// Right inset for a corner overlay. Constant across tiers.
  static const double cornerInsetRight = 24.0;

  /// Gap between the bar's top edge and a corner overlay's bottom edge.
  static const double cornerGap = 12.0;

  /// The bar's rendered height, derived from the bar's own layout constants.
  double get barHeight => ChromeBottomBar.heightFor(
    touchTargets: touchTargets,
    compactTouch: compactTouch,
    titleTier: titleTier,
  );

  /// The size tier of the title block above the timeline.
  ChromeTitleTier get titleTier => compactTouch
      ? ChromeTitleTier.compact
      : remote
      ? ChromeTitleTier.remote
      : ChromeTitleTier.pointer;

  /// The title block's height plus the gap under it: the part of
  /// [barHeight] the title takes, for the scrim to cover.
  double get titleBlockExtent =>
      ChromeTitleBlock.heightFor(titleTier) +
      ChromeTitleBlock.gapFor(titleTier);

  /// Bottom inset for a corner overlay so it always clears the bar.
  double get cornerInsetBottom => barHeight + cornerGap;

  /// Padding that puts a bottom-right corner overlay above the bar and clear
  /// of the safe-area insets.
  ///
  /// The bar sits inside a `SafeArea`, so it floats [barHeight] above the
  /// home indicator rather than above the screen edge; a corner overlay laid
  /// out against the full screen has to add the same inset back or it lands
  /// on the bar. Reads [MediaQuery.paddingOf], so inside an ancestor that
  /// already consumed the padding it adds nothing twice.
  EdgeInsets cornerPaddingOf(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    return EdgeInsets.only(
      right: cornerInsetRight + safe.right,
      bottom: cornerInsetBottom + safe.bottom,
    );
  }

  /// Resolve metrics for a [width] x [height] viewport and the viewer's input
  /// type, using the breakpoints in `core/layout/breakpoints.dart`
  /// (mobile < 600, tablet 600-899, desktop >= 900). Width picks the tier;
  /// the shortest side picks [compactTouch].
  factory ChromeMetrics.resolve({
    required double width,
    required double height,
    required bool touchPrimary,
    bool remote = false,
  }) {
    final compactTransport = width < Breakpoints.mobile;
    final touchTargets = touchPrimary || width < Breakpoints.mobile;
    final horizontalPadding = width >= Breakpoints.mobile ? 24.0 : 16.0;

    if (isCompactTouch(Size(width, height), touchPrimary: touchPrimary)) {
      return ChromeMetrics(
        showVolume: false,
        touchTargets: true,
        compactTransport: compactTransport,
        showQuality: true,
        showAlwaysOnTop: false,
        secondaryGap: 0,
        horizontalPadding: 12,
        compactTouch: true,
        remote: remote,
      );
    }
    if (width >= Breakpoints.tablet) {
      return ChromeMetrics(
        showVolume: true,
        touchTargets: touchTargets,
        compactTransport: compactTransport,
        showQuality: true,
        showAlwaysOnTop: true,
        secondaryGap: 8,
        horizontalPadding: horizontalPadding,
        remote: remote,
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
        remote: remote,
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
      remote: remote,
    );
  }

  /// Fine-pointer shorthand for [resolve], for assertions about width alone.
  @visibleForTesting
  factory ChromeMetrics.forWidth(double width) =>
      ChromeMetrics.resolve(width: width, height: 1080, touchPrimary: false);
}

/// The full-width playback bottom bar.
///
/// A timeline row (elapsed, the scrubber, remaining), then a control row:
/// volume on the left, the transport centred, the secondary cluster on the
/// right. With [controlsFirst] the control row moves to the top. Every group
/// sits straight on `ChromeScrim`'s plateau, which is the OSD pill fill, so
/// none carries a pill of its own. Slot-based so it can be tested without a
/// media_kit `Player`.
class ChromeBottomBar extends StatelessWidget {
  /// Elapsed timecode, left of the scrubber.
  final Widget elapsed;

  /// Remaining timecode, right of the scrubber.
  final Widget remaining;

  /// Scrubber, taking the width between the timecodes.
  final Widget scrubber;

  /// Right group of the control row.
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

  /// The title block, drawn first, above the timeline and control row.
  ///
  /// The bar reserves the block's height and gap whether or not this is
  /// passed, so the bar never changes size when a title arrives.
  final Widget? title;

  final ChromeMetrics metrics;

  /// Whether the control row sits above the timecodes and scrubber instead
  /// of below them.
  ///
  /// Set on the remote tier, where focus order is spatial: UP from the
  /// scrubber has to reach the control the viewer left, so the controls must
  /// be above it. The height is the same either way.
  final bool controlsFirst;

  const ChromeBottomBar({
    super.key,
    required this.metrics,
    required this.elapsed,
    required this.remaining,
    required this.scrubber,
    required this.secondary,
    this.transport,
    this.volume,
    this.title,
    this.controlsFirst = false,
  });

  /// Vertical padding above the first row and below the last.
  static const double verticalPadding = 12;

  /// Gap between a timecode and the scrubber.
  static const double timecodeGap = 12;

  /// Gap between the scrubber and the control row, whichever comes first.
  static const double rowGap = 8;

  /// Height of the control row.
  static const double controlRowHeight = 44;

  /// Scrubber row height with an enlarged touch target, matching
  /// `ProgressBarSurface`.
  static const double _scrubberTouchHeight = 44;

  /// Scrubber row height with a fine pointer, matching `ProgressBarSurface`.
  static const double _scrubberFineHeight = 32;

  /// The bar's rendered height: the sum of the layout constants above, or
  /// with [compactTouch] [CompactChromeBottomBar]'s single row.
  static double heightFor({
    required bool touchTargets,
    bool compactTouch = false,
    ChromeTitleTier titleTier = ChromeTitleTier.pointer,
  }) => compactTouch
      ? CompactChromeBottomBar.height
      : verticalPadding * 2 +
            ChromeTitleBlock.heightFor(titleTier) +
            ChromeTitleBlock.gapFor(titleTier) +
            (touchTargets ? _scrubberTouchHeight : _scrubberFineHeight) +
            rowGap +
            controlRowHeight;

  @override
  Widget build(BuildContext context) {
    final timeline = SizedBox(
      height: metrics.touchTargets ? _scrubberTouchHeight : _scrubberFineHeight,
      child: Row(
        children: [
          elapsed,
          const SizedBox(width: timecodeGap),
          Expanded(child: scrubber),
          const SizedBox(width: timecodeGap),
          remaining,
        ],
      ),
    );
    final controlRow = SizedBox(
      height: controlRowHeight,
      child: Row(
        children: [
          // Equal flex on both sides, always, so the transport's centre
          // lands on the bar's centre whether or not the sides have
          // content. Special-casing an empty side to flex 0 once pinned
          // the transport up to ~187 px off-centre on mobile widths.
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: _volumeSlot()),
          ),
          transport ?? const SizedBox.shrink(),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              // scaleDown is a no-op wherever the cluster fits its slot
              // and only shrinks it where it cannot (320 px with all
              // four buttons), so equal-flex centring is never traded
              // for an overflow.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: secondary,
              ),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.horizontalPadding,
        vertical: verticalPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleSlot(title: title, tier: metrics.titleTier),
          ...controlsFirst
              ? [controlRow, const SizedBox(height: rowGap), timeline]
              : [timeline, const SizedBox(height: rowGap), controlRow],
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

/// The bottom bar on a touch phone ([ChromeMetrics.compactTouch]): one row,
/// elapsed, the scrubber, then remaining.
///
/// No control row: a phone has hardware volume, its transport floats in the
/// centre, and `PlaybackChrome` hands the track buttons to the top bar. That
/// takes the bar from ~148 px to [height], so lifted subtitles sit near the
/// bottom of a landscape phone rather than mid-screen.
class CompactChromeBottomBar extends StatelessWidget {
  final ChromeMetrics metrics;

  /// Elapsed timecode, left of the scrubber.
  final Widget elapsed;

  /// Remaining timecode, right of the scrubber.
  final Widget remaining;

  /// Scrubber, taking the width between the timecodes.
  final Widget scrubber;

  /// Volume control, kept mounted but never shown.
  ///
  /// A phone has no volume control on screen, but a split-screen resize can
  /// cross into this bar and back. Pass the same keyed widget that
  /// [ChromeBottomBar.volume] gets, so its `State` (the pre-mute volume)
  /// moves here and back instead of being rebuilt.
  final Widget? volume;

  /// The title block, drawn above the row.
  final Widget? title;

  const CompactChromeBottomBar({
    super.key,
    required this.metrics,
    required this.elapsed,
    required this.remaining,
    required this.scrubber,
    this.volume,
    this.title,
  });

  /// Vertical padding above and below the row.
  static const double verticalPadding = 6;

  /// The row's height: the touch scrubber's hit area.
  static const double rowHeight = 44;

  /// Gap between a timecode and the scrubber.
  static const double timecodeGap = 12;

  /// The bar's rendered height.
  static final double height =
      verticalPadding * 2 +
      ChromeTitleBlock.heightFor(ChromeTitleTier.compact) +
      ChromeTitleBlock.gapFor(ChromeTitleTier.compact) +
      rowHeight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: metrics.horizontalPadding,
      vertical: verticalPadding,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TitleSlot(title: title, tier: ChromeTitleTier.compact),
        SizedBox(
          height: rowHeight,
          child: Row(
            children: [
              elapsed,
              const SizedBox(width: timecodeGap),
              Expanded(child: scrubber),
              const SizedBox(width: timecodeGap),
              remaining,
              if (volume case final volume?)
                Visibility(visible: false, maintainState: true, child: volume),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The title block's slot at the top of a bar: the block's height plus the gap
/// below it, held even when there is no title.
class _TitleSlot extends StatelessWidget {
  const _TitleSlot({required this.title, required this.tier});

  final Widget? title;
  final ChromeTitleTier tier;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: ChromeTitleBlock.heightFor(tier) + ChromeTitleBlock.gapFor(tier),
    child: Align(
      alignment: AlignmentDirectional.topStart,
      child: SizedBox(height: ChromeTitleBlock.heightFor(tier), child: title),
    ),
  );
}
