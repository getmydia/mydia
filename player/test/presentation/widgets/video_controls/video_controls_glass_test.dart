// The playback control chrome is a token-driven glass panel. This replaces the
// former VideoControlsGlassBar tests: that widget wrapped a full-width bar in
// browse-UI chrome tokens (0.80 fill over a sigma-10 blur), which rendered a
// near-solid rectangle. ChromePanel uses the dedicated player material instead.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/core/theme/depth_tokens.dart';
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

ChromePanel _panel(PlayerGlassTier tier) => ChromePanel(
      metrics: PanelMetrics.forWidth(1600),
      tier: tier,
      transport: const SizedBox(width: 200, height: 48),
      scrubber: const SizedBox(width: 300, height: 32),
      secondary: const SizedBox(width: 120, height: 40),
    );

void main() {
  group('ChromePanel glass', () {
    testWidgets('blurs at the player sigma, not the browse chrome sigma',
        (tester) async {
      await tester.pumpWidget(_host(_panel(PlayerGlassTier.reduced)));

      final filter =
          tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter;
      expect(
        filter,
        ImageFilter.blur(
          sigmaX: DepthTokens.blurPlayerChrome,
          sigmaY: DepthTokens.blurPlayerChrome,
        ),
      );
      expect(
        filter,
        isNot(ImageFilter.blur(
          sigmaX: DepthTokens.blurChrome,
          sigmaY: DepthTokens.blurChrome,
        )),
      );
    });

    testWidgets(
        'stays below the browse legibility floor at both edges, by design',
        (tester) async {
      await tester.pumpWidget(_host(_panel(PlayerGlassTier.full)));

      final decoration = tester
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(BackdropFilter),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .decoration as BoxDecoration;
      final gradient = decoration.gradient! as LinearGradient;

      // The gradient is asymmetric and dense-at-the-top: ChromePanel puts the
      // control row (row 1) at the top of the panel, so density follows it
      // there. Unlike an earlier iteration, the dense (top) end itself also
      // stays under the browse-UI floor — glassLegibilityFloor guards this
      // directly in depth_tokens_test — so *nowhere* in the panel is as
      // dense as browse chrome. glass_legibility_test measures the actual
      // worst-case WCAG contrast at the control-row icons (3:1, non-text)
      // and the scrubber timecodes (4.5:1, text, with a targeted shadow).
      expect(
        gradient.colors.first.a,
        lessThan(DepthTokens.glassLegibilityFloor),
      );
      expect(
        gradient.colors.last.a,
        lessThan(DepthTokens.glassLegibilityFloor),
      );
    });

    testWidgets('controls remain interactive inside the panel', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          ChromePanel(
            metrics: PanelMetrics.forWidth(1600),
            tier: PlayerGlassTier.full,
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
}
