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
  /// touch tier so its two hit targets clear the 44px floor. The top bar's
  /// title pill takes the default.
  final double height;

  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.height = defaultHeight,
  });

  /// Default pill height, shared by the title pill and the top bar's actions
  /// pill.
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

/// The playback screen's top chrome: one pill holding the back chevron and
/// the title, and one actions pill holding the scaling and cast controls.
///
/// No scrim sits behind it (`ChromeScrim` darkens only the bottom), so the
/// title lives inside the pill: the OSD fill holds its contrast over a
/// bright frame, and the rest of the picture stays clear.
class ChromeTopBar extends StatelessWidget {
  /// Media title. When null no title text renders and the actions pill
  /// stays at the end of the row.
  final String? title;

  /// Back action. When null the back chevron is inert but still rendered.
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
    this.title,
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
  static const Key titleKey = Key('chrome-title');
  static const Key castKey = Key('chrome-cast');
  static const Key scalingKey = Key('chrome-scaling');

  /// The single pill holding the scaling and cast controls.
  static const Key actionsPillKey = Key('osd-top-actions');

  /// The pill holding [trailing].
  static const Key trailingPillKey = Key('osd-top-trailing');

  /// The pill holding the back chevron and the title.
  static const Key titlePillKey = Key('osd-top-title');

  /// Width of the back chevron's tap target inside the title pill.
  static const double backWidth = 40.0;

  /// Inset between the title text and the title pill's edge, and between the
  /// text and the back target. The chevron's own target supplies most of the
  /// space on its side, so that gap is narrower.
  static const double titleInset = 14.0;

  /// Gap between the back target and the title text.
  static const double titleGap = 2.0;

  /// Gap between the title pill and the other pills.
  static const double gap = 12.0;

  /// [gap] when [compact].
  static const double compactGap = 8.0;

  @override
  Widget build(BuildContext context) {
    final titleText = title;
    final cast = castAction;
    final l10n = context.l10n;
    const side = GlassPill.defaultHeight;
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
                      iconSize: 19,
                      tooltip: scalingTooltip(l10n, scaling),
                      onTap: onScalingTap,
                    ),
                  if (cast != null) _castButton(cast, side),
                ],
              ),
            ),
          ),
        ),
      ],
    ];

    final titlePill = (showBack || titleText != null)
        ? _titlePill(titleText, l10n.commonBack)
        : null;

    // The title pill takes its natural width up to whatever the other pills
    // leave, ellipsizing past that. Below ~300 px, where the pills alone
    // would not fit, they scale down rather than overflow, as the bottom
    // bar's pill does, and the title pill keeps at least the back target.
    return LayoutBuilder(
      builder: (context, constraints) {
        final reserved = showBack ? backWidth : 0.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: titlePill ?? const SizedBox.shrink(),
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

  /// The back chevron and the title in one OSD pill. Only the chevron's
  /// target is the back button; the title is plain text.
  Widget _titlePill(String? titleText, String backLabel) {
    const side = GlassPill.defaultHeight;
    return SizedBox(
      height: side,
      child: GlassSurface.osdPill(
        key: titlePillKey,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showBack) _backButton(backLabel, side),
            if (titleText != null)
              Flexible(
                child: Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: showBack ? titleGap : titleInset,
                    end: titleInset,
                  ),
                  child: Text(
                    titleText,
                    key: titleKey,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.start,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xD9FFFFFF), // white @ 0.85
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _backButton(String label, double side) {
    Widget target = SizedBox(
      key: backKey,
      width: backWidth,
      height: side,
      child: const Center(
        child: Icon(
          Icons.chevron_left_rounded,
          size: 22,
          color: Color(0xCCFFFFFF), // white @ 0.80
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
  Widget _castButton(Widget cast, double side) {
    final target = SizedBox(
      key: castKey,
      width: side,
      height: side,
      child: Center(
        child: IconTheme.merge(
          data: const IconThemeData(size: 19, color: Color(0xEBFFFFFF)),
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
