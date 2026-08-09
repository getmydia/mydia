// Guards the `ChromePanel` composition against real `RenderFlex` overflows
// across the widths where it actually gets tight: `chrome_panel_test.dart`
// cannot catch these — its slots are plain `SizedBox`es, which shrink under a
// tight parent instead of overflowing the way `Row`-based content
// (`SecondaryCluster`, `VolumeSurface`) does.
//
// Unlike the golden file, this runs on every platform, including Linux CI —
// it is the CI-visible half of the regression guard for this whole class of
// bug.
//
// Only 320px remains broken, and it is still broken *by construction*, not
// pending: four 32px buttons at zero gap cost 128px, and 320px's equal-flex
// slot offers 122px after compaction. Closing the remaining 6px needs either
// a sub-32px button or abandoning the equal-flex centering guarantee for this
// one width, and neither is this file's call. If that changes, *move* 320px
// from `_knownBrokenWidths` to `_passingWidths` — don't just delete its
// assertion.
//
// 320px is the one width whose outcome now depends on `quality`, unlike
// every other width tested here: the 128px figure above is the 4-button
// (quality: true) case. With only 3 buttons (quality: false) — the same
// count every other width's "worst case" no longer forces once `_panel`
// stopped replicating the old platform gate — the need drops to 96px
// against the same 122px slot, a comfortable 26px margin. So 320px's
// quality:false case is asserted passing, separately, right after the main
// passing-widths loop below, rather than inside the uniform
// `_knownBrokenWidths` loop with quality:true.
//
// 600px and 650px *were* asserted broken in an earlier revision of this
// file — that escalation was wrong. Both close with two more one-constant
// levers: `PanelMetrics.forWidth`'s tablet-branch width factor (0.8 -> 0.9)
// and per-tier `horizontalPadding` on `PanelMetrics` (20 -> 12 for mobile and
// tablet). See the constants' own dartdocs for the exact arithmetic.
//
// **`quality` axis:** the quality button used to be gated to the desktop
// tier, because a 4th `SecondaryCluster` button raised its floor from 120 to
// 160px each side and overflowed below 424px, 600-666px, and 900-1026px in
// production. That gate is gone: the control is wired on every platform and
// every tier now shows it. What closed the budget was compaction rather than
// a lever — transport 256 -> 192, secondary buttons 40 -> 32, padding 20/12
// -> 12/8 — so `_panel` below no longer needs to replicate a platform gate.
// `quality: true` now genuinely exercises the 4-button layout at every width
// in `_passingWidths`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

/// Mirrors `PlaybackChrome`'s real composition as closely as a `Player`-free
/// test can: episode-nav wired unconditionally (as `PlaybackChrome` now does
/// — see its wiring comment), `compact` following `metrics.compactTransport`
/// (split from `touchTargets`; dropping seek/episode-nav to play/pause-only
/// below the mobile breakpoint), `volume` supplied whenever
/// `metrics.showVolume`, and the
/// quality button shown whenever [quality] requests it — every tier's
/// `metrics.showQuality` is true now, so there is no gate left to replicate
/// (see the file header's `quality` axis note). This is deliberately the
/// *worst case* PlaybackChrome can present at a given width — a caller with
/// no adjacent episodes gets an easier layout, not a harder one.
///
/// [alwaysOnTop] works differently from [quality]: it wires
/// `onAlwaysOnTopTap` straight from the parameter, unconditionally, rather
/// than consulting `metrics.showAlwaysOnTop` the way real `PlaybackChrome`
/// composition would. That is deliberate, not an oversight — the five-button
/// group below exists to measure the raw `SecondaryCluster` layout budget at
/// widths a real device would never actually show 5 buttons at, since
/// `showAlwaysOnTop` gates those same widths off in production (see its
/// dartdoc in `chrome_panel.dart`). Consulting the real gate here would make
/// [alwaysOnTop] a no-op everywhere it is passed `true`.
Widget _panel(double width, {bool quality = false, bool alwaysOnTop = false}) {
  final metrics = PanelMetrics.forWidth(width);
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: ChromePanel(
          metrics: metrics,
          tier: PlayerGlassTier.full,
          transport: TransportSurface(
            isPlaying: true,
            onPreviousEpisode: () {},
            onNextEpisode: () {},
            compact: metrics.compactTransport,
          ),
          volume: metrics.showVolume
              ? VolumeSurface(
                  volume: 70,
                  onVolumeChanged: (_) {},
                  onToggleMute: () {},
                )
              : null,
          secondary: SecondaryCluster(
            subtitleTrackCount: 1,
            audioTrackCount: 2,
            gap: metrics.secondaryGap,
            onQualityTap: quality ? () {} : null,
            // Unconditional, because this helper measures the worst case and
            // the fullscreen button is present on every platform that has a
            // fullscreen route at all. Passing null would omit it (see
            // `SecondaryCluster.onFullscreenTap`), quietly shrinking the very
            // budget these widths exist to measure.
            onFullscreenTap: () {},
            onAlwaysOnTopTap: alwaysOnTop ? () {} : null,
          ),
          scrubber: ProgressBarSurface(
            progress: 0.35,
            buffered: 0.55,
            touchTarget: metrics.touchTargets,
          ),
        ),
      ),
    ),
  );
}

/// Widths where `ChromePanel` renders every control at its own full,
/// specified size with no overflow. Covers: the full mobile range once the
/// transport is compact (352-599 — 352 specifically because it's the
/// narrowest width that was ever asserted-broken along the way, at the old
/// 20px padding; see `PanelMetrics.horizontalPadding`'s dartdoc), the whole
/// tablet range once `PanelMetrics`'s tablet-branch width factor and
/// per-tier padding are both in effect (600-899, including the 650px width a
/// previous revision of this file wrongly escalated), and the desktop tier
/// (900, 920, and 1600 — the last specifically to prove the `min(720, …)`
/// cap still holds once quality is wired: the widened 0.60 -> 0.70 factor
/// only matters below the point where it saturates at the cap, ~1029px, so
/// nothing about 1600px's layout should change).
const _passingWidths = <double>[
  352,
  360,
  400,
  480,
  599,
  600,
  650,
  670,
  690,
  900,
  920,
  1600,
];

/// Widths that still overflow, by construction, in their `quality: true`
/// case — see the file header. 320px's `quality: false` case does *not*
/// overflow (3 buttons fit with real margin), so it is exercised separately,
/// right after the passing-widths loop below, rather than looped here
/// uniformly with `quality: true`.
const _knownBrokenWidths = <double>[320];

/// Consumes every exception `tester` recorded, rather than just the first —
/// `TestWidgetsFlutterBinding` fails a test at teardown if *any* recorded
/// exception goes un-taken, and at some of [_knownBrokenWidths] both
/// `VolumeSurface`'s and `SecondaryCluster`'s own `Row`s overflow
/// independently in the same pump, i.e. more than one exception at once.
List<Object> _takeAllExceptions(WidgetTester tester) {
  final exceptions = <Object>[];
  for (;;) {
    final exception = tester.takeException();
    if (exception == null) break;
    exceptions.add(exception);
  }
  return exceptions;
}

/// Shared body for a width/quality combination expected to render every
/// control at its own full, natural size with no overflow. Used both by the
/// main [_passingWidths] loop and, separately, by 320px's `quality: false`
/// case (see [_knownBrokenWidths]'s dartdoc for why that one is not looped
/// alongside the rest).
Future<void> _expectFitsAtFullSize(
  WidgetTester tester,
  double width, {
  required bool quality,
}) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_panel(width, quality: quality));
  await tester.pumpAndSettle();

  expect(_takeAllExceptions(tester), isEmpty);

  // Effective on-screen size — not `tester.getSize`, which reports
  // the pre-transform intrinsic size and would silently miss a
  // `FittedBox`-style scale-down applied by an ancestor. `getRect` is
  // transform-aware: it independently maps each corner through
  // `RenderBox.localToGlobal`, so its width reflects any ancestor
  // scaling.
  //
  // 32, not 40: the whole control row was compacted so four discrete
  // buttons fit down to 360px. See `PanelMetrics.showQuality`'s
  // dartdoc for the arithmetic that replaced the old desktop gate.
  //
  // 32 is also below `ControlButton`'s own 44px default hit target
  // (`control_button.dart`), which `control_button_test.dart`'s "default
  // target meets the 44px touch minimum" test pins as this codebase's
  // stated minimum. `SecondaryCluster` has deliberately undercut that
  // default since before this change — it hard-codes its own smaller size
  // rather than inheriting `ControlButton`'s default, and never receives
  // `touchTargets`, so nothing expands the hit area to compensate. That
  // trade-off is intentional and this commit doesn't revisit it, but
  // compaction raises its stakes: `showQuality` is now true at the mobile
  // tier too, so phones move from three 40px sub-44px targets to four 32px
  // ones.
  final secondaryRect = tester.getRect(
    find.byKey(SecondaryCluster.fullscreenKey),
  );
  expect(secondaryRect.width, greaterThanOrEqualTo(32));
  expect(secondaryRect.height, greaterThanOrEqualTo(32));

  final metrics = PanelMetrics.forWidth(width);
  if (metrics.showVolume) {
    final volumeRect = tester.getRect(find.byKey(VolumeSurface.muteKey));
    expect(volumeRect.width, greaterThanOrEqualTo(40));
    expect(volumeRect.height, greaterThanOrEqualTo(40));
  }

  // Every tier shows the quality button now, so requesting it is
  // enough — there is no tier that suppresses it.
  expect(
    find.byKey(SecondaryCluster.qualityKey),
    quality ? findsOneWidget : findsNothing,
  );
  if (quality) {
    final qualityRect = tester.getRect(
      find.byKey(SecondaryCluster.qualityKey),
    );
    expect(qualityRect.width, greaterThanOrEqualTo(32));
    expect(qualityRect.height, greaterThanOrEqualTo(32));
  }
}

void main() {
  for (final width in _passingWidths) {
    for (final quality in const [false, true]) {
      testWidgets(
        'ChromePanel at ${width}px (quality: $quality): no RenderFlex '
        'overflow, and every control renders at its own full natural size '
        '(not squeezed)',
        (tester) => _expectFitsAtFullSize(tester, width, quality: quality),
      );
    }
  }

  // 320px, quality: false only — see _knownBrokenWidths' dartdoc. Its
  // quality: true case is covered by the broken-widths loop below.
  testWidgets(
    'ChromePanel at 320.0px (quality: false): no RenderFlex overflow, and '
    'every control renders at its own full natural size (not squeezed)',
    (tester) => _expectFitsAtFullSize(tester, 320, quality: false),
  );

  for (final width in _knownBrokenWidths) {
    testWidgets(
      'ChromePanel at ${width}px (quality: true): out of budget by '
      'construction, not pending — see this file\'s header',
      (tester) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_panel(width, quality: true));
        await tester.pumpAndSettle();

        final exceptions = _takeAllExceptions(tester);
        expect(
          exceptions,
          isNotEmpty,
          reason: 'this width was expected to still overflow; if it no '
              'longer does, move ${width}px from _knownBrokenWidths to '
              '_passingWidths above instead of loosening this assertion',
        );
        for (final exception in exceptions) {
          expect(exception.toString(), contains('RenderFlex'));
        }
      },
    );
  }

  // Five-button case: subtitles, audio, quality, fullscreen, and
  // always-on-top all requested at once — the scenario a narrowed desktop
  // window can reach, which `quality`-only widths above never exercise.
  //
  // Desktop widths only, not the full `_passingWidths` set: the tablet
  // branch (600-899px) was tried first (per `PanelMetrics.showAlwaysOnTop`'s
  // dartdoc's initial hypothesis) and its narrowest width, 600px, overflowed
  // `SecondaryCluster`'s row by 18px with a 5th button — 650/670/690 held,
  // but the field is a per-branch lever, not per-width, so the whole tablet
  // tier fell back to `showAlwaysOnTop: false`. Only the desktop branch
  // (>= 900px, looser padding and gap) affords the 5th button, so only its
  // widths are asserted here.
  const fiveButtonWidths = <double>[900, 920, 1600];

  for (final width in fiveButtonWidths) {
    testWidgets(
      'ChromePanel at ${width}px with always-on-top: no RenderFlex '
      'overflow with all five SecondaryCluster buttons showing',
      (tester) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester
            .pumpWidget(_panel(width, quality: true, alwaysOnTop: true));
        await tester.pumpAndSettle();

        expect(_takeAllExceptions(tester), isEmpty);

        final alwaysOnTopRect = tester.getRect(
          find.byKey(SecondaryCluster.alwaysOnTopKey),
        );
        expect(alwaysOnTopRect.width, greaterThanOrEqualTo(32));
        expect(alwaysOnTopRect.height, greaterThanOrEqualTo(32));
      },
    );
  }
}
