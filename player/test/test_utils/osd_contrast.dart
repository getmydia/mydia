/// WCAG contrast arithmetic for glyphs drawn on the OSD material
/// (`GlassSurface.osd`).
///
/// The contract is the fill alone over a pure-white frame. A Gaussian blur of
/// a uniform backdrop is that same backdrop, and the drop shadow is not
/// credited, so the worst case reduces to one src-over blend. Flutter blends
/// in sRGB-encoded space, which is what [compositeOver] does.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';

/// WCAG relative luminance of an opaque colour.
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// [top] painted src-over onto the opaque [bottom].
Color compositeOver(Color top, Color bottom) {
  final a = top.a;
  double mix(double t, double b) => t * a + b * (1 - a);
  return Color.from(
    alpha: 1,
    red: mix(top.r, bottom.r),
    green: mix(top.g, bottom.g),
    blue: mix(top.b, bottom.b),
  );
}

/// WCAG contrast ratio between two opaque colours, lighter over darker.
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The OSD fill composited over a pure-white frame.
Color get osdWorstCaseBackground => compositeOver(
      DepthTokens.osdTint.withValues(alpha: DepthTokens.osdFillOpacity),
      Colors.white,
    );

/// Contrast of [foreground], which may be translucent, drawn on the OSD
/// material over a pure-white frame.
double osdContrast(Color foreground) {
  final bg = osdWorstCaseBackground;
  return contrastRatio(compositeOver(foreground, bg), bg);
}

/// Every colour OSD text may use. Each must clear WCAG SC 1.4.3 (4.5:1).
/// [AppColors.textDisabled] and [AppColors.warning] are deliberately absent.
final Set<Color> osdTextColors = {
  AppColors.textPrimary,
  AppColors.textSecondary,
  AppColors.primary,
  AppColors.successText,
  AppColors.warningText,
  Colors.white,
  Colors.white.withValues(alpha: 0.80),
  Colors.white.withValues(alpha: 0.94),
};

/// Colours used only for icons on the OSD material. Each must clear WCAG
/// SC 1.4.11 (3:1).
final Set<Color> osdIconOnlyColors = {AppColors.error};

/// The colour of every text run (and icon glyph, which is also a
/// [RichText]) under [scope], as painted.
List<Color> osdParagraphColors(WidgetTester tester, Finder scope) {
  final colors = <Color>[];
  final paragraphs = tester.renderObjectList<RenderParagraph>(
    find.descendant(of: scope, matching: find.byType(RichText)),
  );
  for (final paragraph in paragraphs) {
    paragraph.text.visitChildren((span) {
      final color = span.style?.color;
      if (color != null) colors.add(color);
      return true;
    });
  }
  return colors;
}
