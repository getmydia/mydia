/// Control sizes and corner radii from the iOS 27 kit, read only when
/// `GlassStyle.liquid` is on.
abstract final class LiquidGeometry {
  static const double buttonSmall = 28; // kit Buttons / Small
  static const double buttonMedium = 34; // kit Buttons / Medium and Regular
  static const double buttonLarge = 50; // kit Buttons / Large
  static const double toolbarButton = 44; // kit Toolbars / Buttons
  static const double minHitTarget = 44;
  static const double tabBarHeight = 62; // kit Tab Bars / iPhone
  static const double tabSelectionHeight = 54;
  static const double tabSelectionInset = 4;
  static const double dialogRadius = 34; // kit Alerts
  static const double sheetRadius = 34; // kit Sheets / iPhone
  static const double menuRadius = 32; // kit Menus
  static const double sliderKnobWidth = 37; // kit Sliders / Knob
  static const double sliderKnobHeight = 24;
}
