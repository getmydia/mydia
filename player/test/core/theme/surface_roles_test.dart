import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/surface_roles.dart';
import 'package:player/core/theme/theme_preset.dart';

void main() {
  test('fromPalette matches the spec tokens', () {
    final r = SurfaceRoles.fromPalette(Palettes.projectionBooth);
    expect(r.hairline, const Color(0x14FFFFFF));
    expect(r.hairlineStrong, const Color(0x24FFFFFF));
    expect(r.rim, const Color(0x0FFFFFFF));
    expect(r.hoverOverlay, const Color(0x0AFFFFFF));
    expect(r.pressOverlay, const Color(0x1F000000));
    expect(r.scrim, const Color(0x9E060607));
    expect(r.radiusControl, 10);
    expect(r.radiusMenu, 14);
    expect(r.radiusModal, 20);
  });

  test('every preset theme carries SurfaceRoles', () {
    for (final preset in ThemePreset.values) {
      final p = preset.palette();
      for (final liquid in [false, true]) {
        expect(
          AppTheme.build(p, liquid: liquid).extension<SurfaceRoles>(),
          isNotNull,
          reason: '${preset.name} liquid=$liquid',
        );
      }
    }
  });

  test('lerp interpolates colors and radii', () {
    final a = SurfaceRoles.fromPalette(Palettes.projectionBooth);
    final b = a.copyWith(radiusControl: 20, hairline: const Color(0x00000000));
    final mid = a.lerp(b, 0.5);
    expect(mid.radiusControl, 15);
    expect(mid.hairline, Color.lerp(a.hairline, b.hairline, 0.5));
    expect(a.lerp(null, 0.5), a);
  });

  testWidgets('context.surfaceRoles falls back without the extension', (
    tester,
  ) async {
    late SurfaceRoles roles;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            roles = context.surfaceRoles;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(roles.radiusModal, 20);
  });
}
