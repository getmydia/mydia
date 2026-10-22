import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/liquid_glass/liquid_geometry.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/cast_bar/cast_bar_parts.dart';
import 'package:player/presentation/widgets/cast_bar/cast_pill.dart';
import 'package:player/presentation/widgets/glass/glass_dialog.dart';
import 'package:player/presentation/widgets/glass/glass_popover.dart';
import 'package:player/presentation/widgets/glass/glass_sheet.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/toast/toast_models.dart';
import 'package:player/presentation/widgets/toast/toast_pill.dart';

Widget _host(Widget child, {required bool liquid}) => MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
      home: Scaffold(body: Center(child: child)),
    );

BorderRadius _radiusOf(WidgetTester tester) =>
    tester.widget<GlassSurface>(find.byType(GlassSurface)).borderRadius;

const _toast = ToastEntry(
  id: 0,
  message: 'Saved',
  kind: ToastKind.info,
  icon: null,
  action: null,
  duration: Duration(seconds: 3),
);

void main() {
  testWidgets('Liquid Glass: a dialog takes the kit alert radius',
      (tester) async {
    await tester.pumpWidget(_host(
      const GlassDialog(title: Text('Remove account?')),
      liquid: true,
    ));
    expect(_radiusOf(tester), BorderRadius.circular(34));
    expect(LiquidGeometry.dialogRadius, 34);
  });

  testWidgets('Liquid Glass: a popover takes the kit menu radius',
      (tester) async {
    await tester.pumpWidget(_host(
      const GlassPopoverSurface(child: Text('Rows')),
      liquid: true,
    ));
    expect(_radiusOf(tester), BorderRadius.circular(32));
  });

  testWidgets('Frosted: the popover keeps its 12 point Material card',
      (tester) async {
    await tester.pumpWidget(_host(
      const GlassPopoverSurface(child: Text('Rows')),
      liquid: false,
    ));
    expect(find.byType(GlassSurface), findsNothing);
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(GlassPopoverSurface),
        matching: find.byType(Material),
      ),
    );
    expect(material.borderRadius, BorderRadius.circular(12));
  });

  testWidgets('Liquid Glass: a sheet rounds its top corners to 34',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showGlassSheet<void>(
              context: context,
              builder: (_) => const Text('Sheet body'),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      _radiusOf(tester),
      const BorderRadius.vertical(top: Radius.circular(34)),
    );
  });

  testWidgets('Liquid Glass: a short cast state centres in the capsule',
      (tester) async {
    const key = Key('cast-child');
    await tester.pumpWidget(_host(
      const CastPill(child: SizedBox(key: key, width: 100, height: 20)),
      liquid: true,
    ));
    expect(
      tester.getCenter(find.byKey(key)).dy,
      tester.getCenter(find.byType(GlassSurface)).dy,
    );
  });

  testWidgets('Liquid Glass: a standard cast row is a true capsule',
      (tester) async {
    await tester.pumpWidget(_host(
      SizedBox(
        width: 400,
        child: CastPill(
          child: CastBarRow(
            leading: const Icon(Icons.cast_connected, size: 34),
            title: 'Living room',
            status: 'Playing',
            dot: CastDot.live,
            actions: [
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
      liquid: true,
    ));
    final height = tester.getSize(find.byType(GlassSurface)).height;
    expect(height, CastPill.liquidMinHeight);
    expect(_radiusOf(tester), BorderRadius.circular(height / 2));
  });

  testWidgets('Frosted: the cast pill keeps radius 18', (tester) async {
    await tester.pumpWidget(_host(
      const CastPill(child: SizedBox(width: 200, height: 24)),
      liquid: false,
    ));
    expect(_radiusOf(tester), CastPill.radius);
  });

  testWidgets('Liquid Glass: a one line toast is a capsule', (tester) async {
    await tester
        .pumpWidget(_host(const ToastPill(entry: _toast), liquid: true));
    final height = tester.getSize(find.byType(GlassSurface)).height;
    expect(_radiusOf(tester), BorderRadius.circular(height / 2));
    expect(
      tester.getCenter(find.text('Saved')).dy,
      tester.getCenter(find.byType(GlassSurface)).dy,
    );
  });

  testWidgets('Frosted: the toast keeps radius 22', (tester) async {
    await tester
        .pumpWidget(_host(const ToastPill(entry: _toast), liquid: false));
    expect(_radiusOf(tester), BorderRadius.circular(ToastMetrics.radius));
  });
}
