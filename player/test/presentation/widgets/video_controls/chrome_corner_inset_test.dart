import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';

void main() {
  /// The widths that matter: the mobile floor, either side of each
  /// breakpoint, and a wide desktop window.
  const widths = <double>[360, 599, 600, 899, 900, 1440];

  group('PanelMetrics.cornerInsetBottom', () {
    test('clears the panel at every tier', () {
      for (final width in widths) {
        final metrics = PanelMetrics.forWidth(width);
        expect(
          metrics.cornerInsetBottom,
          greaterThan(metrics.bottomOffset),
          reason: 'a corner overlay at ${width}px would sit inside the panel',
        );
      }
    });

    test('leaves at least a 12px gap above the panel', () {
      for (final width in widths) {
        final metrics = PanelMetrics.forWidth(width);
        expect(
          metrics.cornerInsetBottom - metrics.bottomOffset,
          greaterThanOrEqualTo(_panelHeight + 12),
          reason: 'insufficient clearance at ${width}px',
        );
      }
    });

    test('rises with the panel offset across tiers', () {
      // Desktop sits the panel highest, so its corner inset is highest too.
      expect(
        PanelMetrics.forWidth(1440).cornerInsetBottom,
        greaterThan(PanelMetrics.forWidth(360).cornerInsetBottom),
      );
    });
  });
}

/// The panel's rendered height: two rows plus padding.
///
/// Row 1 is a 44px control, row 2 is the 20px scrubber, separated by
/// [ChromePanel.rowGap] and wrapped in [ChromePanel.verticalPadding] on both
/// sides.
const double _panelHeight =
    44 + ChromePanel.rowGap + 20 + (ChromePanel.verticalPadding * 2);
