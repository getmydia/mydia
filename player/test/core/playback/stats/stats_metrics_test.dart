import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/stats/stats_metrics.dart';

void main() {
  StatsMetrics? resolve(double w, double h, {bool tv = false}) =>
      StatsMetrics.resolve(
        viewport: Size(w, h),
        directionalPrimary: tv,
      );

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
    expect(metrics.maxHeight, greaterThanOrEqualTo(StatsMetrics.compactHeight));
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
    // 650 tall, minus the 64px top inset, minus the desktop tier's 174px
    // corner inset, leaves 412: enough for the full panel, not the tv one.
    final metrics = resolve(1280, 650, tv: true);

    expect(metrics!.density, StatsDensity.full);
    expect(metrics.showButtons, isFalse);
  });

  test('a D-pad viewport that falls through to compact still hides buttons',
      () {
    final metrics = resolve(844, 390, tv: true);

    expect(metrics!.density, StatsDensity.compact);
    expect(metrics.showButtons, isFalse);
  });

  // The panel hangs below the chrome's top pill row, which sits at
  // `Positioned(top: 16)` inside a SafeArea and is GlassPill.defaultHeight
  // (36) tall. Anything smaller draws the panel over the title pill.
  test('the top inset clears the chrome top bar', () {
    expect(StatsMetrics.topInset, 64.0);
    expect(resolve(1280, 720)!.top, 64.0);
  });
}
