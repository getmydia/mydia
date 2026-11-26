import 'package:material_ui/material_ui.dart';

import 'chrome_top_bar.dart';

/// Size tier of [ChromeTitleBlock]: pointer layouts, compact (phone) layouts
/// and the ten-foot remote layout.
enum ChromeTitleTier { pointer, compact, remote }

/// The two-line playback title that sits bottom-left, directly above the
/// scrubber: a small kicker line over the title.
///
/// Display only: it holds no focus node, no gesture handler and no glass, and
/// it ignores pointers. Its outer height is exactly [heightFor] at every text
/// scale; the lines shrink to fit instead of growing.
class ChromeTitleBlock extends StatelessWidget {
  const ChromeTitleBlock({
    super.key,
    required this.title,
    this.kicker,
    required this.tier,
  });

  final String title;

  /// The line above the title. Its slot stays reserved when null so the title
  /// does not move.
  final String? kicker;

  final ChromeTitleTier tier;

  static const Key kickerKey = Key('chrome-title-kicker');

  static const double kickerOpacity = 0.78;
  static const double _titleOpacity = 0.95;

  /// Total height of the block.
  static double heightFor(ChromeTitleTier tier) =>
      _kickerBoxHeight(tier) + _titleBoxHeight(tier);

  /// The gap below the block; the bar adds it.
  static double gapFor(ChromeTitleTier tier) => switch (tier) {
    ChromeTitleTier.pointer => 6,
    ChromeTitleTier.compact => 4,
    ChromeTitleTier.remote => 6,
  };

  static double kickerFontSize(ChromeTitleTier tier) => switch (tier) {
    ChromeTitleTier.pointer => 13,
    ChromeTitleTier.compact => 11,
    ChromeTitleTier.remote => 18,
  };

  static double titleFontSize(ChromeTitleTier tier) => switch (tier) {
    ChromeTitleTier.pointer => 22,
    ChromeTitleTier.compact => 15,
    ChromeTitleTier.remote => 30,
  };

  static double _kickerBoxHeight(ChromeTitleTier tier) => switch (tier) {
    ChromeTitleTier.pointer => 18,
    ChromeTitleTier.compact => 14,
    ChromeTitleTier.remote => 24,
  };

  static double _titleBoxHeight(ChromeTitleTier tier) => switch (tier) {
    ChromeTitleTier.pointer => 28,
    ChromeTitleTier.compact => 20,
    ChromeTitleTier.remote => 38,
  };

  @override
  Widget build(BuildContext context) {
    final kickerText = kicker;
    final titleSize = titleFontSize(tier);
    return IgnorePointer(
      // Glyphs stay at the designed size at every text scale: the lines are
      // pinned to their boxes, so a scaler would only shrink the width the
      // ellipsis gets.
      child: MediaQuery.withNoTextScaling(
        child: SizedBox(
          height: heightFor(tier),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Line(
                height: _kickerBoxHeight(tier),
                text: kickerText,
                textKey: kickerKey,
                style: TextStyle(
                  fontSize: kickerFontSize(tier),
                  height: _kickerBoxHeight(tier) / kickerFontSize(tier),
                  leadingDistribution: TextLeadingDistribution.even,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: kickerOpacity),
                ),
              ),
              _Line(
                height: _titleBoxHeight(tier),
                text: title,
                textKey: ChromeTopBar.titleKey,
                style: TextStyle(
                  fontSize: titleSize,
                  height: _titleBoxHeight(tier) / titleSize,
                  leadingDistribution: TextLeadingDistribution.even,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: _titleOpacity),
                  letterSpacing: -0.01 * titleSize,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One single-line text in a fixed-height box. The text ellipsizes at the
/// box width and scales down, bottom-start anchored, when scaling would
/// otherwise make it taller than the box.
class _Line extends StatelessWidget {
  const _Line({
    required this.height,
    required this.text,
    required this.textKey,
    required this.style,
  });

  final double height;
  final String? text;
  final Key textKey;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final value = text;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: value == null
          ? null
          : LayoutBuilder(
              builder: (context, constraints) => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.bottomStart,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  child: Text(
                    value,
                    key: textKey,
                    style: style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
              ),
            ),
    );
  }
}
