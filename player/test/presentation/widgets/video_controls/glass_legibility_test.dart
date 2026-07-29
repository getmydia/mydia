// The player glass fills at 0.45 nominal — deliberately below the browse UI's
// 0.60 legibility floor. That trade is only safe if white controls still clear
// 4.5:1 against a worst-case bright backdrop. This measures it.
//
// If this fails, the fix is more gradient weight under the control row, NOT a
// higher flat fill — flat fill is the defect this redesign removes.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';

/// WCAG relative luminance.
double _luminance(int r, int g, int b) {
  double channel(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

double _contrastWithWhite(int r, int g, int b) {
  final bg = _luminance(r, g, b);
  return (1.0 + 0.05) / (bg + 0.05);
}

void main() {
  testWidgets(
    'white controls clear 4.5:1 over a worst-case bright backdrop',
    (tester) async {
      tester.view.physicalSize = const ui.Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              child: Stack(
                children: [
                  // Worst case: a fully blown-out white frame.
                  const Positioned.fill(
                    child: ColoredBox(color: Colors.white),
                  ),
                  ChromePanel(
                    metrics: PanelMetrics.forWidth(1600),
                    tier: PlayerGlassTier.full,
                    transport: const SizedBox(width: 200, height: 48),
                    scrubber: const SizedBox(width: 300, height: 32),
                    secondary: const SizedBox(width: 120, height: 40),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(data, isNotNull);

      final panel = tester.getRect(find.byType(ChromePanel));
      // Sample the control row — the vertical band where glyphs sit.
      final sampleY = (panel.top + panel.height * 0.30).round();
      final bytes = data!.buffer.asUint8List();
      final imageWidth = image.width;
      // Bytes are already copied out via toByteData; the native handle isn't
      // needed past this point.
      image.dispose();

      var worst = double.infinity;
      for (var x = panel.left.round() + 8;
          x < panel.right.round() - 8;
          x += 16) {
        final offset = (sampleY * imageWidth + x) * 4;
        final contrast = _contrastWithWhite(
          bytes[offset],
          bytes[offset + 1],
          bytes[offset + 2],
        );
        if (contrast < worst) worst = contrast;
      }

      expect(
        worst,
        greaterThanOrEqualTo(4.5),
        reason: 'White-on-glass contrast was $worst:1 over a white backdrop. '
            'Increase playerChromeFillBottomAlpha (gradient weight under the '
            'control row) — do not raise the flat fill.',
      );
    },
    // This project's nix/macOS test environment has an environment-level
    // issue, unrelated to ChromePanel: any testWidgets body that reads pixels
    // via Image.toByteData() after RenderRepaintBoundary.toImage() /
    // .toImageSync() can hang in flutter_test's own post-body binding
    // teardown — reproduced here with a bare ColoredBox with no BackdropFilter
    // or gradient at all, independent of image size, sync-vs-async capture,
    // byte format, or whether the image is disposed (see task-10-report.md
    // for the isolation trail). The assertion above is verified correct on
    // its own merits — a completed run measured 4.55:1. This shorter timeout
    // only bounds that known teardown flakiness so a recurrence fails fast
    // instead of consuming the framework's 10-minute default and starving
    // sibling test files sharing its runner shard.
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
