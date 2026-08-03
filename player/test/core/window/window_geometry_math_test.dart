import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_geometry_math.dart';

void main() {
  // A single 1920x1080 display whose top 25px is the macOS menu bar.
  const primary = WorkArea(
    bounds: Rect.fromLTWH(0, 25, 1920, 1055),
    isPrimary: true,
  );
  // A second display arranged to the right of the primary.
  const secondary = WorkArea(
    bounds: Rect.fromLTWH(1920, 0, 2560, 1440),
    isPrimary: false,
  );

  group('isTitleBarReachable', () {
    test('a window sitting well inside a display is reachable', () {
      expect(
        isTitleBarReachable(
          const Rect.fromLTWH(100, 100, 1200, 800),
          const [primary],
        ),
        isTrue,
      );
    });

    test('a window on a display that is no longer attached is not', () {
      expect(
        isTitleBarReachable(
          const Rect.fromLTWH(2100, 100, 1200, 800),
          const [primary],
        ),
        isFalse,
      );
    });

    test('a window whose title bar is above the menu bar is not reachable', () {
      // The body of this window overlaps the work area substantially — y 25
      // through 770 — so a plain intersection check would call it fine. But
      // the title bar strip spans y -30..10, entirely above the work area, so
      // there is nothing to grab and the user cannot drag it back.
      expect(
        isTitleBarReachable(
          const Rect.fromLTWH(100, -30, 1200, 800),
          const [primary],
        ),
        isFalse,
      );
    });

    test('a sliver of title bar is not enough to grab', () {
      // 40px of width poking onto the display is below the 100px threshold.
      expect(
        isTitleBarReachable(
          const Rect.fromLTWH(1880, 100, 1200, 800),
          const [primary],
        ),
        isFalse,
      );
    });

    test('a window reachable on a secondary display is reachable', () {
      expect(
        isTitleBarReachable(
          const Rect.fromLTWH(2100, 100, 1200, 800),
          const [primary, secondary],
        ),
        isTrue,
      );
    });

    test('no displays means nothing is reachable', () {
      expect(
        isTitleBarReachable(const Rect.fromLTWH(0, 0, 1200, 800), const []),
        isFalse,
      );
    });
  });

  group('recoverOffscreenWindow', () {
    test('leaves a reachable window exactly where it is', () {
      const saved = Rect.fromLTWH(100, 100, 1200, 800);

      expect(recoverOffscreenWindow(saved, const [primary]), saved);
    });

    test('re-centers a window from a vanished display onto the primary', () {
      final recovered = recoverOffscreenWindow(
        const Rect.fromLTWH(2100, 100, 1200, 800),
        const [primary],
      );

      // Size preserved, centered in the 1920x1055 work area that starts at y=25.
      expect(recovered, const Rect.fromLTWH(360, 152.5, 1200, 800));
    });

    test('clamps a window larger than the primary work area', () {
      final recovered = recoverOffscreenWindow(
        const Rect.fromLTWH(5000, 0, 2400, 1600),
        const [primary],
      );

      expect(recovered, const Rect.fromLTWH(0, 25, 1920, 1055));
    });

    test('returns null when there are no displays to recover onto', () {
      expect(
        recoverOffscreenWindow(const Rect.fromLTWH(0, 0, 1200, 800), const []),
        isNull,
      );
    });
  });

  group('defaultWindowRect', () {
    test('centers the default size on the primary display', () {
      // (1920-1280)/2 = 320; 25 + (1055-800)/2 = 152.5
      expect(
        defaultWindowRect(const [primary, secondary]),
        const Rect.fromLTWH(320, 152.5, 1280, 800),
      );
    });

    test('falls back to the first display when none is flagged primary', () {
      const unflagged = WorkArea(
        bounds: Rect.fromLTWH(0, 0, 1440, 900),
        isPrimary: false,
      );

      expect(
        defaultWindowRect(const [unflagged]),
        const Rect.fromLTWH(80, 50, 1280, 800),
      );
    });

    test('returns null when there are no displays', () {
      expect(defaultWindowRect(const []), isNull);
    });
  });

  group('fitToAspect', () {
    const desktop = Rect.fromLTWH(0, 0, 2560, 1400);

    test('keeps the width and the center point', () {
      // 1200 wide at 16:9 is 675 tall. Center of the old rect is (700, 550),
      // so the new top is 550 - 337.5.
      expect(
        fitToAspect(
          current: const Rect.fromLTWH(100, 100, 1200, 900),
          aspect: 16 / 9,
          workArea: desktop,
        ),
        const Rect.fromLTWH(100, 212.5, 1200, 675),
      );
    });

    test('a 2.39:1 film is floored at the minimum height', () {
      // 1000 / 2.39 = 418.4, below the 480 minimum, so the window letterboxes
      // rather than shrinking past what is usable.
      expect(
        fitToAspect(
          current: const Rect.fromLTWH(0, 0, 1000, 800),
          aspect: 2.39,
          workArea: desktop,
        ),
        const Rect.fromLTWH(0, 160, 1000, 480),
      );
    });

    test('scales width down when the derived height exceeds the work area', () {
      // A square video in an 1800-wide window would want 1800 of height, more
      // than the 1080 available, so both dimensions come down together and the
      // aspect survives.
      const smallDesktop = Rect.fromLTWH(0, 0, 1920, 1080);

      expect(
        fitToAspect(
          current: const Rect.fromLTWH(0, 0, 1800, 900),
          aspect: 1.0,
          workArea: smallDesktop,
        ),
        const Rect.fromLTWH(360, 0, 1080, 1080),
      );
    });

    test('translates a rect that would overflow the bottom edge', () {
      const smallDesktop = Rect.fromLTWH(0, 0, 1920, 1080);

      // Centering would put the bottom at 1312.5; the rect slides up instead
      // of being resized, so the aspect is untouched.
      expect(
        fitToAspect(
          current: const Rect.fromLTWH(200, 900, 1200, 150),
          aspect: 16 / 9,
          workArea: smallDesktop,
        ),
        const Rect.fromLTWH(200, 405, 1200, 675),
      );
    });

    test('respects a work area that does not start at the origin', () {
      // macOS: the menu bar pushes the usable area down by 25px.
      const menuBarDesktop = Rect.fromLTWH(0, 25, 1920, 1055);

      final fitted = fitToAspect(
        current: const Rect.fromLTWH(100, 30, 1200, 400),
        aspect: 16 / 9,
        workArea: menuBarDesktop,
      );

      expect(fitted.width, 1200);
      expect(fitted.height, 675);
      expect(fitted.top, greaterThanOrEqualTo(25));
      expect(fitted.bottom, lessThanOrEqualTo(1080));
    });

    test('enforces the minimum width on a very tall video', () {
      // 9:16 vertical video. Height caps at the work area, and the derived
      // width falls below the 720 minimum, so the minimum wins.
      const smallDesktop = Rect.fromLTWH(0, 0, 1920, 1080);

      final fitted = fitToAspect(
        current: const Rect.fromLTWH(0, 0, 1400, 600),
        aspect: 9 / 16,
        workArea: smallDesktop,
      );

      expect(fitted.width, 720);
      expect(fitted.height, 1080);
    });
  });

  group('areaContaining', () {
    test('finds the display holding the window centre', () {
      expect(
        areaContaining(const Rect.fromLTWH(2100, 100, 1200, 800), const [
          primary,
          secondary,
        ])?.bounds,
        secondary.bounds,
      );
    });

    test('falls back to the primary when the centre is nowhere', () {
      expect(
        areaContaining(
          const Rect.fromLTWH(9000, 9000, 100, 100),
          const [primary, secondary],
        )?.bounds,
        primary.bounds,
      );
    });

    test('returns null when there are no displays', () {
      expect(areaContaining(const Rect.fromLTWH(0, 0, 100, 100), const []),
          isNull);
    });
  });
}
