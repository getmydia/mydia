/// Where the stats panel sits, and how dense it is, for a viewport.
///
/// Shaped after `PanelMetrics.resolve`, and deliberately reading
/// `PanelMetrics`' own `cornerInsetBottom` rather than repeating its
/// arithmetic: when a tier's control panel changes height, the stats panel
/// follows without being touched.
library;

import 'dart:ui' show Size;

import '../../../presentation/widgets/video_controls/chrome_panel.dart';
import '../../../presentation/widgets/video_controls/chrome_top_bar.dart';

enum StatsDensity { full, compact, tv }

class StatsMetrics {
  const StatsMetrics({
    required this.density,
    required this.width,
    required this.gutter,
    required this.maxHeight,
    required this.labelSize,
    required this.valueSize,
    required this.rowGap,
    required this.showSparkline,
    required this.showButtons,
  });

  /// Which tier [resolve] picked for this viewport.
  final StatsDensity density;

  /// Panel width in logical pixels. See the per-tier comments in [resolve]
  /// for where each value comes from.
  final double width;

  /// Distance from the left edge of the safe area.
  final double gutter;

  /// Room between [top] and the control panel's corner inset. The panel
  /// renders no taller than this.
  final double maxHeight;

  /// Row label font size. See the per-tier comments in [resolve].
  final double labelSize;

  /// Row value font size. See the per-tier comments in [resolve].
  final double valueSize;

  /// Vertical gap between rows. See the per-tier comments in [resolve].
  final double rowGap;

  /// Whether the sparkline renders. False only on the compact tier, which
  /// has no room for it once the fixed rows are laid out.
  final bool showSparkline;

  /// Whether the copy and close buttons render. False whenever the input
  /// is D-pad primary, regardless of which density tier was resolved: a
  /// focusable button in the panel would join traversal and fight the
  /// OSD's own focus scope.
  final bool showButtons;

  /// The chrome's top pill row sits at `Positioned(top: 16)` inside a
  /// SafeArea and is [GlassPill.defaultHeight] tall. 12px of air below it
  /// puts the panel clear of the back, title and cast pills, which is the
  /// whole reason the panel can stay on screen while the chrome fades.
  ///
  /// The panel is mounted inside the same SafeArea as the chrome, so this
  /// arithmetic stays true on a notched phone without repeating the inset.
  static const double topInset = 16.0 + GlassPill.defaultHeight + 12.0;

  /// Distance from the top of the safe area.
  double get top => topInset;

  /// Rendered height of each variant, pinned by
  /// `stats_panel_test.dart`, which pumps the real panel and reads its
  /// RenderBox rather than recomputing this arithmetic. Same contract as
  /// `PanelMetrics._panelHeight`.
  static const double fullHeight = 344.0;
  static const double compactHeight = 164.0;
  static const double tvHeight = 470.0;

  /// A wider margin on a television, for a viewer sitting across a room.
  /// Not a safe-area claim: neither this app nor its chrome implements
  /// overscan insets, and if one is added later both inherit it through
  /// SafeArea.
  static const double tvGutter = 48.0;

  /// The gutter everywhere else, matching `PanelMetrics.cornerInsetRight`
  /// so the panel and a corner overlay share one margin.
  static const double pointerGutter = PanelMetrics.cornerInsetRight;

  /// Null when even the compact panel cannot clear the control panel.
  /// Drawing it anyway would put numbers over the scrubber, which is worse
  /// than not drawing it: the copy payload is unaffected either way.
  static StatsMetrics? resolve({
    required Size viewport,
    required bool directionalPrimary,
  }) {
    // `PanelMetrics.forWidth` is the fine-pointer shorthand for `resolve`,
    // but it is `@visibleForTesting`, so production code calls `resolve`
    // directly. `touchPrimary` is hardcoded to false rather than threaded
    // through as a parameter here because `cornerInsetBottom`, the only
    // field this reads, is set per width tier in every branch of
    // `PanelMetrics.resolve` and never varies with `touchPrimary`. If a
    // future change needs a field that does vary with it instead
    // (`touchTargets`, `maxWidth`, `compactTransport`), thread the real
    // `touchPrimary` through `StatsMetrics.resolve` rather than assuming
    // false here.
    final available = viewport.height -
        topInset -
        PanelMetrics.resolve(width: viewport.width, touchPrimary: false)
            .cornerInsetBottom;

    // A focusable copy/close button in the panel would join D-pad
    // traversal and fight the OSD's own focus scope. That hazard is about
    // the remote, not the density: even when the viewport is too short
    // for the tv tier below and falls through to full or compact, buttons
    // stay off whenever the input is D-pad primary.
    final showButtons = !directionalPrimary;

    if (directionalPrimary && available >= tvHeight) {
      // Scaled for 10-foot viewing. The width is set so the longest value
      // string the panel can show, the Why row's "remembered decode
      // failure", does not wrap at 15px.
      return StatsMetrics(
        density: StatsDensity.tv,
        width: 462,
        gutter: tvGutter,
        maxHeight: available,
        labelSize: 15,
        valueSize: 15,
        rowGap: 9,
        showSparkline: true,
        showButtons: showButtons,
      );
    }
    if (available >= fullHeight) {
      // Width and reading sizes from the approved design mockup, for a
      // pointer at desk distance. The 90px label column in a later task's
      // panel widget is sized against this.
      return StatsMetrics(
        density: StatsDensity.full,
        width: 352,
        gutter: pointerGutter,
        maxHeight: available,
        labelSize: 11.5,
        valueSize: 12,
        rowGap: 7,
        showSparkline: true,
        showButtons: showButtons,
      );
    }
    if (available >= compactHeight) {
      // Not a design choice, a fit constraint: a phone in landscape
      // leaves about 168px between `topInset` and the control panel's
      // corner inset, and seven rows plus a header only fit that at this
      // density. This is why `compactHeight` is 164 and not rounder.
      return StatsMetrics(
        density: StatsDensity.compact,
        width: 292,
        gutter: pointerGutter,
        maxHeight: available,
        labelSize: 10.5,
        valueSize: 11,
        rowGap: 4,
        showSparkline: false,
        showButtons: showButtons,
      );
    }
    return null;
  }
}
