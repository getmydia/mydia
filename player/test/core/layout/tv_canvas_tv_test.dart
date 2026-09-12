// Television-tier proof that TvCanvas actually rewrites the MediaQuery the rest
// of the tree reads, not merely that the predicate returns 0.75 (that part is
// covered, tier-agnostic, by tv_canvas_scale_test.dart).
//
// Requires --dart-define=MYDIA_FORCE_TV=true; see login_tv_test.dart for why
// this file skips itself rather than failing without it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/tv_canvas.dart';
import 'package:player/core/player/input_capabilities.dart';

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; forcedTv is a compile-time '
          'flag (bool.fromEnvironment), so this file is a deliberate no-op '
          'unless the whole test process is compiled with that define. CI '
          'runs it explicitly in the "Run television-tier tests" step.';

  group('TvCanvas (requires MYDIA_FORCE_TV=true)', () {
    testWidgets('presents a 1280x720 canvas for a 960x540 viewport',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late Size seen;
      await tester.pumpWidget(
        MaterialApp(
          home: TvCanvas(
            child: Builder(
              builder: (context) {
                seen = MediaQuery.sizeOf(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(seen, const Size(1280, 720));
    });

    testWidgets('passes the devicePixelRatio through untouched',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      late double seenDpr;
      await tester.pumpWidget(
        MaterialApp(
          home: TvCanvas(
            child: Builder(
              builder: (context) {
                seenDpr = MediaQuery.devicePixelRatioOf(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      // The canvas is wider, the panel is unchanged: glyphs must rasterise at
      // the panel's real density, which is the whole reason this is a
      // MediaQuery override and not a devicePixelRatio edit.
      expect(seenDpr, 2.0);
    });

    testWidgets('is a passthrough when the canvas is already large enough',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late Size seen;
      await tester.pumpWidget(
        MaterialApp(
          home: TvCanvas(
            child: Builder(
              builder: (context) {
                seen = MediaQuery.sizeOf(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(seen, const Size(1920, 1080));
    });

    testWidgets(
        'lays the tree out on the enlarged canvas, not just the '
        'MediaQuery', (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const probeKey = ValueKey('tv-canvas-probe');
      await tester.pumpWidget(
        MaterialApp(
          home: TvCanvas(
            child: SizedBox.expand(key: probeKey),
          ),
        ),
      );

      // The assertion the MediaQuery check cannot make: a real layout box of
      // 1280x720. Without the constraint relief in build() this reports
      // 960x540, which is exactly the defect that MediaQuery-only assertion
      // let through.
      expect(tester.getSize(find.byKey(probeKey)), const Size(1280, 720));
    });

    testWidgets('a pointer reaches the far corner of the enlarged canvas',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var taps = 0;
      const probeKey = ValueKey('tv-canvas-corner-probe');
      await tester.pumpWidget(
        MaterialApp(
          home: TvCanvas(
            child: Align(
              alignment: Alignment.bottomRight,
              child: GestureDetector(
                key: probeKey,
                // A bare SizedBox paints nothing and is not itself a hit
                // target, so the default `deferToChild` would make the
                // detector unreachable at any position and the assertion
                // vacuously unreachable. `opaque` makes the 80x80 box the
                // target, which is what isolates the nesting under test.
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(width: 80, height: 80),
              ),
            ),
          ),
        ),
      );

      // A physical point near the panel's bottom-right corner. It maps to a
      // canvas coordinate beyond 960x540, which is exactly where the
      // OverflowBox/Transform ordering used to reject the hit.
      await tester.tapAt(const Offset(940, 520));
      await tester.pump();

      expect(taps, 1);
    });
  }, skip: skipReason);
}
