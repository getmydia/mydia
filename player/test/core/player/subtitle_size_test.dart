import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:player/core/player/subtitle_size.dart';

double _points(Size viewport, SubtitleSize size) =>
    subtitleTextScaler(viewport, size).scale(kSubtitleBaseFontSize);

void main() {
  group('subtitleTextScaler', () {
    const phone = Size(844, 390);
    const androidTv = Size(960, 540);
    const desktop = Size(1920, 1080);
    const fourK = Size(3840, 2160);

    test('a phone hits the floor, then scales by preset', () {
      expect(_points(phone, SubtitleSize.small), closeTo(14.4, 0.01));
      expect(_points(phone, SubtitleSize.medium), closeTo(18, 0.01));
      expect(_points(phone, SubtitleSize.large), closeTo(22.5, 0.01));
      expect(_points(phone, SubtitleSize.extraLarge), closeTo(27, 0.01));
    });

    test('an Android TV at DPR 2 is lifted from 16 to the floor', () {
      expect(_points(androidTv, SubtitleSize.medium), closeTo(18, 0.01));
    });

    test('1080p keeps media_kit sizing at Medium', () {
      expect(_points(desktop, SubtitleSize.small), closeTo(25.6, 0.01));
      expect(_points(desktop, SubtitleSize.medium), closeTo(32, 0.01));
      expect(_points(desktop, SubtitleSize.large), closeTo(40, 0.01));
      expect(_points(desktop, SubtitleSize.extraLarge), closeTo(48, 0.01));
    });

    test('larger than 1080p is clamped like media_kit does', () {
      expect(_points(fourK, SubtitleSize.medium), closeTo(32, 0.01));
    });

    test('an unbounded viewport uses full size; an empty one the floor', () {
      expect(_points(Size.infinite, SubtitleSize.medium), closeTo(32, 0.01));
      expect(_points(Size.zero, SubtitleSize.medium), closeTo(18, 0.01));
    });
  });

  group('SubtitleSize', () {
    test('fromStorageKey reads every name and defaults to medium', () {
      for (final size in SubtitleSize.values) {
        expect(SubtitleSize.fromStorageKey(size.name), size);
      }
      expect(SubtitleSize.fromStorageKey(null), SubtitleSize.medium);
      expect(SubtitleSize.fromStorageKey('huge'), SubtitleSize.medium);
    });

    test('smaller and larger step through presets and stop at the ends', () {
      expect(SubtitleSize.small.smaller, isNull);
      expect(SubtitleSize.small.larger, SubtitleSize.medium);
      expect(SubtitleSize.medium.larger, SubtitleSize.large);
      expect(SubtitleSize.extraLarge.larger, isNull);
      expect(SubtitleSize.extraLarge.smaller, SubtitleSize.large);
    });

    test('labels', () {
      expect(SubtitleSize.values.map((s) => s.label),
          ['Small', 'Medium', 'Large', 'Extra large']);
    });
  });

  test('subtitleViewConfigurationFor keeps media_kit style and padding', () {
    const stock = SubtitleViewConfiguration();
    final config =
        subtitleViewConfigurationFor(const Size(844, 390), SubtitleSize.large);

    expect(config.style, stock.style);
    expect(config.padding, stock.padding);
    expect(
        config.textScaler!.scale(kSubtitleBaseFontSize), closeTo(22.5, 0.01));
  });
}
