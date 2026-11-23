// The OSD pill material paints no blur and uses the OSD fill.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/glass_style.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

void main() {
  group('GlassSurface.osdPill', () {
    Widget pill({required bool liquid}) => MaterialApp(
      theme: ThemeData(extensions: [GlassStyle(liquid: liquid)]),
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            Center(
              child: GlassSurface.osdPill(
                child: const SizedBox(width: 120, height: 36),
              ),
            ),
          ],
        ),
      ),
    );

    for (final liquid in [false, true]) {
      testWidgets('paints no BackdropFilter (liquid: $liquid)', (tester) async {
        await tester.pumpWidget(pill(liquid: liquid));

        expect(
          find.descendant(
            of: find.byType(GlassSurface),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
      });
    }

    testWidgets('uses the OSD fill and hairline', (tester) async {
      await tester.pumpWidget(pill(liquid: false));

      final fill =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byType(ClipRRect),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(
        fill.color,
        DepthTokens.osdTint.withValues(alpha: DepthTokens.osdFillOpacity),
      );
      expect((fill.border! as Border).top.color, DepthTokens.osdHairline);
    });
  });
}
