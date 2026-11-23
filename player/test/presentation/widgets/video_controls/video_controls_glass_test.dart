// The playback control panel renders the OSD material.

import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/glass_style.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Colors.white)),
        child,
      ],
    ),
  ),
);

ChromePanel _panel() => ChromePanel(
  metrics: PanelMetrics.forWidth(1600),
  transport: const SizedBox(width: 200, height: 48),
  scrubber: const SizedBox(width: 300, height: 32),
  secondary: const SizedBox(width: 120, height: 40),
);

void main() {
  group('ChromePanel OSD material', () {
    testWidgets('blurs once, at the OSD sigma', (tester) async {
      await tester.pumpWidget(_host(_panel()));

      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
        ImageFilter.blur(
          sigmaX: DepthTokens.osdBlurSigma,
          sigmaY: DepthTokens.osdBlurSigma,
        ),
      );
    });

    testWidgets('fills flat at the OSD opacity', (tester) async {
      await tester.pumpWidget(_host(_panel()));

      final fill =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byType(BackdropFilter),
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
      expect(fill.gradient, isNull);
    });

    testWidgets('lifts with the panel shadow', (tester) async {
      await tester.pumpWidget(_host(_panel()));

      final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
      expect(surface.shadows, DepthTokens.osdShadowPanel);
    });

    testWidgets('controls remain interactive inside the panel', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          ChromePanel(
            metrics: PanelMetrics.forWidth(1600),
            transport: ElevatedButton(
              onPressed: () => tapped = true,
              child: const Text('play'),
            ),
            scrubber: const SizedBox(width: 300, height: 32),
          ),
        ),
      );

      await tester.tap(find.text('play'));
      expect(tapped, isTrue);
    });
  });

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
