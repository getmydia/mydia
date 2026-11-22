/// How large text subtitles are drawn, per device.
///
/// media_kit_video's `SubtitleView` scales its 32pt text by
/// `sqrt(viewport area / 1920x1080)`. On a phone in landscape that comes to
/// about 0.4, so cues land near 13pt: the same share of screen height a TV
/// gets, on a screen a fraction of the size held at arm's length. The
/// floor below is what fixes that; the presets scale on top of it.
///
/// Text tracks only. Bitmap tracks are drawn by mpv from their own pixels
/// (see `subtitle_render.dart`).
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show SubtitleViewConfiguration;

import '../theme/app_theme.dart' show kAppFontFamily;

/// media_kit's default subtitle font size, which the player keeps.
const double kSubtitleBaseFontSize = 32;

/// The smallest a Medium cue is drawn, in logical points.
const double kSubtitleMinFontSize = 18;

const double _referenceArea = 1920 * 1080;

enum SubtitleSize {
  small(0.8),
  medium(1.0),
  large(1.25),
  extraLarge(1.5);

  const SubtitleSize(this.multiplier);

  final double multiplier;

  /// The next smaller preset, or null at [small].
  SubtitleSize? get smaller => index == 0 ? null : values[index - 1];

  /// The next larger preset, or null at [extraLarge].
  SubtitleSize? get larger =>
      index == values.length - 1 ? null : values[index + 1];

  /// Reads a stored [name]. Anything unrecognised is [medium], so a value
  /// written by a newer build degrades to the default instead of failing.
  static SubtitleSize fromStorageKey(String? key) =>
      values.firstWhere((size) => size.name == key, orElse: () => medium);
}

/// The text scaler `SubtitleView` should use for [viewport] at [size].
TextScaler subtitleTextScaler(Size viewport, SubtitleSize size) {
  final areaScale = viewport.isFinite
      ? math.sqrt(
          (viewport.width * viewport.height / _referenceArea).clamp(0.0, 1.0),
        )
      : 1.0;
  final base = math.max(
    kSubtitleBaseFontSize * areaScale,
    kSubtitleMinFontSize,
  );
  return TextScaler.linear(base * size.multiplier / kSubtitleBaseFontSize);
}

/// media_kit's stock configuration with the scaler replaced and the app font
/// named. Padding stays at its default: `chrome_subtitle_lift.dart` animates
/// it and `subtitle_position.dart` assumes its default bottom inset.
///
/// The family is explicit because media_kit wraps the text in Flutter's own
/// `Material`, which reads flutter/material's `Theme`, not the app's
/// material_ui one, and so would otherwise fall back to Roboto.
SubtitleViewConfiguration subtitleViewConfigurationFor(
  Size viewport,
  SubtitleSize size,
) => SubtitleViewConfiguration(
  style: _stockStyle.copyWith(fontFamily: kAppFontFamily),
  textScaler: subtitleTextScaler(viewport, size),
);

final TextStyle _stockStyle = const SubtitleViewConfiguration().style;
