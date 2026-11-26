import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/player/video_scaling.dart';
import '../../../core/theme/depth_tokens.dart';
import '../../../l10n/l10n.dart';
import '../glass_surface.dart';
import 'control_button.dart';

/// The glyph for the mode in effect, shared by the top-bar pill and the TV
/// cluster button so the two never disagree.
IconData scalingIcon(VideoScaling scaling) => switch (scaling) {
  VideoScaling.fit => Icons.fit_screen_rounded,
  // Not `crop_free`: its four corners read as the fullscreen glyph in the
  // bottom bar.
  VideoScaling.fill => Icons.crop_rounded,
};

/// The tooltip naming the mode in effect, shown on both scaling controls.
String scalingTooltip(AppLocalizations l10n, VideoScaling scaling) =>
    switch (scaling) {
      VideoScaling.fit => l10n.videoScalingFit,
      VideoScaling.fill => l10n.videoScalingFill,
    };

/// A 36px-tall pill in the unblurred OSD pill material
/// ([GlassSurface.osdPill]).
///
/// Used for the corner overlays. Text and icons carry no shadow: the OSD
/// fill holds their contrast on its own over a pure-white frame
/// (`osd_legibility_test.dart`).
class GlassPill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// Pill height. Defaults to [defaultHeight]; `UpNextPrompt` passes 44 at the
  /// touch tier so its two hit targets clear the 44px floor.
  final double height;

  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.height = defaultHeight,
  });

  /// Default pill height, used by the skip and Up Next pills.
  static const double defaultHeight = 36.0;

  @override
  Widget build(BuildContext context) {
    Widget content = SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          widthFactor: 1,
          child: DefaultTextStyle.merge(
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xCCFFFFFF), // white @ 0.80
            ),
            child: IconTheme.merge(
              data: const IconThemeData(size: 18, color: Color(0xCCFFFFFF)),
              child: child,
            ),
          ),
        ),
      ),
    );

    content = GlassSurface.osdPill(
      borderRadius: const BorderRadius.all(
        Radius.circular(DepthTokens.radiusOsdPill),
      ),
      child: content,
    );

    if (onTap == null) return content;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// The playback screen's top chrome: a round back disc at the start and, at
/// the end, a capsule holding the scaling and cast controls (and, on a touch
/// phone, one holding the track buttons).
///
/// No scrim sits behind it (`ChromeScrim` darkens only the bottom), so every
/// piece is its own OSD pill: the fill holds contrast over a bright frame and
/// the rest of the picture stays clear. The title lives in the bottom bar's
/// title block, not here.
class ChromeTopBar extends StatelessWidget {
  /// Back action. When null the back disc is inert but still rendered.
  final VoidCallback? onBack;

  /// Whether the back chevron renders at all.
  ///
  /// False on the remote tier, whose BACK key already dismisses the chrome
  /// and then leaves playback. Distinct from a null [onBack], which keeps the
  /// chevron on screen but inert.
  final bool showBack;

  /// Cast / AirPlay affordance. When null the pill is omitted.
  final Widget? castAction;

  /// Cast tap handler. Lives here rather than inside [castAction] so the whole
  /// pill is the tap target: an 18px glyph in a 36px pill would leave most of
  /// the affordance dead to touch, and only the pill can offer the hover
  /// cursor. When null the pill renders but is inert, like the back chevron.
  final VoidCallback? onCastTap;

  /// Fit/Fill toggle. When null the pill is omitted: the remote tier puts
  /// this control in `SecondaryCluster` instead, because the top bar takes
  /// no focus there.
  final VoidCallback? onScalingTap;

  /// The mode in effect, which picks the pill's glyph.
  final VideoScaling scaling;

  /// Controls drawn in their own pill just before the actions pill. On a
  /// touch phone this is the track buttons (subtitles, audio, quality),
  /// moved up from the bottom bar so the bar can be a single row.
  final Widget? trailing;

  /// Whether to use [compactGap] between the groups, on a touch phone.
  final bool compact;

  const ChromeTopBar({
    super.key,
    this.onBack,
    this.showBack = true,
    this.castAction,
    this.onCastTap,
    this.onScalingTap,
    this.scaling = VideoScaling.fit,
    this.trailing,
    this.compact = false,
  });

  static const Key backKey = Key('chrome-back');

  /// Key of the title text. The top bar draws no title; `ChromeTitleBlock`
  /// keys its title line with this.
  static const Key titleKey = Key('chrome-title');
  static const Key castKey = Key('chrome-cast');
  static const Key scalingKey = Key('chrome-scaling');

  /// The single pill holding the scaling and cast controls.
  static const Key actionsPillKey = Key('osd-top-actions');

  /// The pill holding [trailing].
  static const Key trailingPillKey = Key('osd-top-trailing');

  /// The back disc's glass surface. [backKey] is the tap target around it.
  static const Key backDiscKey = Key('osd-top-back');

  /// The height of the capsules and the diameter of the back disc: 36 on the
  /// touch phone, 40 elsewhere.
  static double sideFor({required bool compact}) => compact ? 36.0 : 40.0;

  /// Distance from the top of the safe area to the bar where no window chrome
  /// needs clearing: 16, or 8 on a touch phone, whose landscape height is
  /// short. `PlayerTopBarSlot` places the bar there.
  static double topInsetFor({required bool compact}) => compact ? 8.0 : 16.0;

  /// Gap between the pills.
  static const double gap = 12.0;

  /// [gap] when [compact].
  static const double compactGap = 8.0;

  @override
  Widget build(BuildContext context) {
    final cast = castAction;
    final l10n = context.l10n;
    final side = sideFor(compact: compact);
    final glyph = compact ? 19.0 : 20.0;
    final gap = compact ? compactGap : ChromeTopBar.gap;
    final trailing = this.trailing;
    final pills = <Widget>[
      if (trailing != null) ...[
        SizedBox(
          height: side,
          child: GlassSurface.osdPill(
            key: trailingPillKey,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Center(widthFactor: 1, child: trailing),
            ),
          ),
        ),
      ],
      if (onScalingTap != null || cast != null) ...[
        if (trailing != null) SizedBox(width: gap),
        SizedBox(
          height: side,
          child: GlassSurface.osdPill(
            key: actionsPillKey,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onScalingTap != null)
                    ControlButton(
                      key: scalingKey,
                      icon: scalingIcon(scaling),
                      size: side,
                      iconSize: glyph,
                      tooltip: scalingTooltip(l10n, scaling),
                      onTap: onScalingTap,
                    ),
                  if (cast != null) _castButton(cast, side, glyph),
                ],
              ),
            ),
          ),
        ),
      ],
    ];

    // The capsules take whatever the back disc leaves. Below ~300 px, where
    // they would not fit, they scale down rather than overflow, as the bottom
    // bar's pill does.
    return LayoutBuilder(
      builder: (context, constraints) {
        final reserved = showBack ? side : 0.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: showBack
                    ? _backDisc(l10n.commonBack, side)
                    : const SizedBox.shrink(),
              ),
            ),
            if (pills.isNotEmpty) ...[
              SizedBox(width: gap),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.max(0, constraints.maxWidth - reserved - gap),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerEnd,
                  child: Row(mainAxisSize: MainAxisSize.min, children: pills),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The back chevron on a circular OSD pill. The whole disc is the tap
  /// target.
  Widget _backDisc(String label, double side) {
    Widget target = SizedBox(
      key: backKey,
      width: side,
      height: side,
      child: GlassSurface.osdPill(
        key: backDiscKey,
        borderRadius: BorderRadius.circular(side / 2),
        child: const Center(
          child: Icon(
            Icons.chevron_left_rounded,
            size: 22,
            color: Color(0xCCFFFFFF), // white @ 0.80
          ),
        ),
      ),
    );
    if (onBack != null) {
      target = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onBack,
          child: target,
        ),
      );
    }
    return Tooltip(
      message: label,
      // The Semantics below already carries the label; without this the
      // tooltip would announce Back a second time.
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        button: true,
        onTap: onBack,
        excludeSemantics: true,
        child: target,
      ),
    );
  }

  /// The cast affordance in a square tap target. The whole square is the tap
  /// target, not the glyph; with no [onCastTap] it stays inert.
  Widget _castButton(Widget cast, double side, double glyph) {
    final target = SizedBox(
      key: castKey,
      width: side,
      height: side,
      child: Center(
        child: IconTheme.merge(
          data: IconThemeData(size: glyph, color: const Color(0xEBFFFFFF)),
          child: cast,
        ),
      ),
    );
    if (onCastTap == null) return target;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onCastTap,
        child: target,
      ),
    );
  }
}
