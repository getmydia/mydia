import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

import 'palette.dart';

/// Edge, overlay, scrim and radius tokens shared by the Frosted surfaces.
///
/// Every preset carries one, built from its [MydiaPalette] in
/// `AppTheme.build`. Read it with `context.surfaceRoles`.
@immutable
class SurfaceRoles extends ThemeExtension<SurfaceRoles> {
  const SurfaceRoles({
    required this.hairline,
    required this.hairlineStrong,
    required this.rim,
    required this.hoverOverlay,
    required this.pressOverlay,
    required this.scrim,
    required this.radiusControl,
    required this.radiusMenu,
    required this.radiusModal,
  });

  /// Every value is constant today; the palette parameter lets a preset
  /// override a role later without changing callers.
  factory SurfaceRoles.fromPalette(MydiaPalette p) => const SurfaceRoles(
    hairline: Color(0x14FFFFFF),
    hairlineStrong: Color(0x24FFFFFF),
    rim: Color(0x0FFFFFFF),
    hoverOverlay: Color(0x0AFFFFFF),
    pressOverlay: Color(0x1F000000),
    scrim: Color(0x9E060607),
    radiusControl: 10,
    radiusMenu: 14,
    radiusModal: 20,
  );

  /// Resting edge of cards, menus, sheets, dialogs, chips and inputs.
  final Color hairline;

  /// Interactive edge: secondary buttons, segmented track, select.
  final Color hairlineStrong;

  /// Top highlight on raised surfaces.
  final Color rim;

  /// Hover on any control.
  final Color hoverOverlay;

  /// Press dim on any control.
  final Color pressOverlay;

  /// Behind dialogs.
  final Color scrim;

  /// Buttons, inputs, select, segmented track.
  final double radiusControl;

  /// Menus, popovers, cards in settings.
  final double radiusMenu;

  /// Dialogs and sheets.
  final double radiusModal;

  @override
  SurfaceRoles copyWith({
    Color? hairline,
    Color? hairlineStrong,
    Color? rim,
    Color? hoverOverlay,
    Color? pressOverlay,
    Color? scrim,
    double? radiusControl,
    double? radiusMenu,
    double? radiusModal,
  }) => SurfaceRoles(
    hairline: hairline ?? this.hairline,
    hairlineStrong: hairlineStrong ?? this.hairlineStrong,
    rim: rim ?? this.rim,
    hoverOverlay: hoverOverlay ?? this.hoverOverlay,
    pressOverlay: pressOverlay ?? this.pressOverlay,
    scrim: scrim ?? this.scrim,
    radiusControl: radiusControl ?? this.radiusControl,
    radiusMenu: radiusMenu ?? this.radiusMenu,
    radiusModal: radiusModal ?? this.radiusModal,
  );

  @override
  SurfaceRoles lerp(covariant SurfaceRoles? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t) ?? b;
    double d(double a, double b) => lerpDouble(a, b, t) ?? b;
    return SurfaceRoles(
      hairline: c(hairline, other.hairline),
      hairlineStrong: c(hairlineStrong, other.hairlineStrong),
      rim: c(rim, other.rim),
      hoverOverlay: c(hoverOverlay, other.hoverOverlay),
      pressOverlay: c(pressOverlay, other.pressOverlay),
      scrim: c(scrim, other.scrim),
      radiusControl: d(radiusControl, other.radiusControl),
      radiusMenu: d(radiusMenu, other.radiusMenu),
      radiusModal: d(radiusModal, other.radiusModal),
    );
  }
}

extension SurfaceRolesContext on BuildContext {
  /// The theme's [SurfaceRoles], or the Projection Booth defaults in a bare
  /// test theme that carries none.
  SurfaceRoles get surfaceRoles =>
      Theme.of(this).extension<SurfaceRoles>() ??
      SurfaceRoles.fromPalette(Palettes.projectionBooth);
}
