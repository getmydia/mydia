import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/playback/stats/stats_metrics.dart';
import 'package:player/presentation/widgets/video_controls/chrome_bottom_bar.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

void main() {
  StatsMetrics? resolve(double w, double h, {bool tv = false}) =>
      StatsMetrics.resolve(viewport: Size(w, h), directionalPrimary: tv);

  // The bar is taller with a touch-sized scrubber, so a touch tablet's
  // panel has to stop higher than a pointer's at the same viewport.
  test('with touchPrimary the panel still clears the taller touch bar', () {
    const viewport = Size(1024, 720);
    final touch = StatsMetrics.resolve(
      viewport: viewport,
      directionalPrimary: false,
      touchPrimary: true,
    )!;
    final pointer = StatsMetrics.resolve(
      viewport: viewport,
      directionalPrimary: false,
    )!;
    final touchBar = ChromeMetrics.resolve(
      width: viewport.width,
      height: viewport.height,
      touchPrimary: true,
    );

    final panelBottom = touch.top + touch.maxHeight;
    expect(
      viewport.height - touchBar.barHeight - panelBottom,
      greaterThanOrEqualTo(ChromeMetrics.cornerGap),
    );
    expect(touch.maxHeight, lessThan(pointer.maxHeight));
  });

  // The remote tier's title block is taller, so its bar is too.
  test('on the remote tier the panel clears the taller remote bar', () {
    const viewport = Size(1280, 540);
    final tv = StatsMetrics.resolve(
      viewport: viewport,
      directionalPrimary: true,
    )!;
    final remoteBar = ChromeMetrics.resolve(
      width: viewport.width,
      height: viewport.height,
      touchPrimary: false,
      remote: true,
    );
    expect(remoteBar.cornerInsetBottom, remoteBar.barHeight + 12);
    final panelBottom = tv.top + tv.maxHeight;
    expect(
      viewport.height - remoteBar.barHeight - panelBottom,
      greaterThanOrEqualTo(ChromeMetrics.cornerGap),
    );
  });

  // The panel and the bar both sit inside the safe area, so a home
  // indicator below and a notch above eat into the room between them.
  test('verticalSafeInset shrinks the room above the bar', () {
    const viewport = Size(1024, 720);
    final bare = StatsMetrics.resolve(
      viewport: viewport,
      directionalPrimary: false,
      touchPrimary: true,
    )!;
    final inset = StatsMetrics.resolve(
      viewport: viewport,
      directionalPrimary: false,
      touchPrimary: true,
      verticalSafeInset: 24 + 21,
    )!;

    expect(inset.maxHeight, bare.maxHeight - 45);
  });

  test('a desktop window takes the full panel', () {
    final metrics = resolve(1280, 720);

    expect(metrics, isNotNull);
    expect(metrics!.density, StatsDensity.full);
    expect(metrics.showSparkline, isTrue);
    expect(metrics.showButtons, isTrue);
  });

  // 390 tall, minus the 64px top inset, minus the tablet tier's 158px
  // corner inset, leaves 168: enough for the compact panel and not the
  // full one.
  test('a phone in landscape drops to compact', () {
    final metrics = resolve(844, 390);

    expect(metrics!.density, StatsDensity.compact);
    expect(metrics.showSparkline, isFalse);
    expect(
      metrics.maxHeight,
      greaterThanOrEqualTo(StatsMetrics.compactMinHeight),
    );
  });

  // A panel that cannot clear the control panel must not be drawn at all.
  // Overlapping the controls is worse than being absent.
  test('a window too short for the compact panel resolves to null', () {
    expect(resolve(600, 300), isNull);
  });

  test('the remote tier takes the tv panel, with no buttons', () {
    final metrics = resolve(1920, 1080, tv: true);

    expect(metrics!.density, StatsDensity.tv);
    expect(metrics.showButtons, isFalse);
    expect(metrics.showSparkline, isTrue);
    expect(metrics.valueSize, greaterThan(14));
  });

  // A D-pad viewport too short for the tv tier falls through to full or
  // compact, but buttons must stay off regardless: a focusable button in
  // the panel would still join D-pad traversal and fight the OSD's focus
  // scope, and that hazard does not care which density branch was taken.
  test('a D-pad viewport that falls through to full still hides buttons', () {
    // 650 tall, minus the 68px top inset, minus the desktop tier's 188px
    // corner inset, leaves 394: enough for the full panel, not the tv one.
    final metrics = resolve(1280, 650, tv: true);

    expect(metrics!.density, StatsDensity.full);
    expect(metrics.showButtons, isFalse);
  });

  test(
    'a D-pad viewport that falls through to compact still hides buttons',
    () {
      // Taller than a landscape phone: the remote bar now carries a
      // 62px title block, so 390 no longer leaves the compact minimum.
      final metrics = resolve(844, 440, tv: true);

      expect(metrics!.density, StatsDensity.compact);
      expect(metrics.showButtons, isFalse);
    },
  );

  // The panel hangs 12px below the top bar as the chrome really places it:
  // the back disc is 40 tall off the phone and 36 on it, and the slot's top
  // inset differs too. Measured from a real bar rather than from constants.
  for (final (label, touch, size) in [
    ('pointer', false, const Size(1280, 720)),
    ('touch tablet', true, const Size(1200, 800)),
    ('phone', true, const Size(760, 350)),
  ]) {
    testWidgets('the panel sits 12px below the top bar: $label', (
      tester,
    ) async {
      InputCapabilities.debugTouchPrimaryOverride = touch;
      addTearDown(() => InputCapabilities.debugTouchPrimaryOverride = null);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(
              children: [
                PlayerTopBarSlot(
                  child: ChromeTopBar(
                    onBack: () {},
                    compact: ChromeMetrics.isCompactTouch(
                      size,
                      touchPrimary: touch,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final barBottom = tester.getRect(find.byKey(ChromeTopBar.backKey)).bottom;
      final metrics = StatsMetrics.resolve(
        viewport: size,
        directionalPrimary: false,
        touchPrimary: touch,
      )!;
      expect(metrics.top - barBottom, 12.0);
    });
  }
}
