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
  VideoScaling.fill => Icons.crop_free_rounded,
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
/// Used for the back pill and the corner overlays. The top bar sits on
/// `ChromeScrim`'s top band, whose plateau is the same OSD fill, so the bare
/// title beside the pills stays legible over bright video. Text and icons
/// carry no shadow: the OSD fill holds their contrast on its own
/// (`osd_legibility_test.dart`).
class GlassPill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// Pill height. Defaults to [defaultHeight]; `UpNextPrompt` passes 44 at the
  /// touch tier so its two hit targets clear the 44px floor. The top bar's
  /// back pill takes the default.
  final double height;

  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.height = defaultHeight,
  });

  /// Default pill height, shared by the back pill and the top bar's actions
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

/// The playback screen's top chrome: a back pill, the bare left-aligned
/// title, and one actions pill holding the scaling and cast controls.
///
/// Replaces the former left-aligned chevron-and-title row that lived in
/// `player_screen.dart`, so all playback chrome is owned by one widget.
class ChromeTopBar extends StatelessWidget {
  /// Media title. When null no title text renders and the actions pill
  /// stays at the end of the row.
  final String? title;

  /// Back action. When null the back pill is inert but still rendered.
  final VoidCallback? onBack;

  /// Whether the back pill renders at all.
  ///
  /// False on the remote tier, whose BACK key already dismisses the chrome
  /// and then leaves playback. Distinct from a null [onBack], which keeps the
  /// pill on screen but inert.
  final bool showBack;

  /// Cast / AirPlay affordance. When null the pill is omitted.
  final Widget? castAction;

  /// Cast tap handler. Lives here rather than inside [castAction] so the whole
  /// pill is the tap target: an 18px glyph in a 36px pill would leave most of
  /// the affordance dead to touch, and only the pill can offer the hover
  /// cursor. When null the pill renders but is inert, like the back pill.
  final VoidCallback? onCastTap;

  /// Fit/Fill toggle. When null the pill is omitted: the remote tier puts
  /// this control in `SecondaryCluster` instead, because the top bar takes
  /// no focus there.
  final VoidCallback? onScalingTap;

  /// The mode in effect, which picks the pill's glyph.
  final VideoScaling scaling;

  const ChromeTopBar({
    super.key,
    this.title,
    this.onBack,
    this.showBack = true,
    this.castAction,
    this.onCastTap,
    this.onScalingTap,
    this.scaling = VideoScaling.fit,
  });

  static const Key backKey = Key('chrome-back');
  static const Key titleKey = Key('chrome-title');
  static const Key castKey = Key('chrome-cast');
  static const Key scalingKey = Key('chrome-scaling');

  /// The single pill holding the scaling and cast controls.
  static const Key actionsPillKey = Key('osd-top-actions');

  /// Gap between back, title and the actions pill.
  static const double gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final titleText = title;
    final cast = castAction;
    final l10n = context.l10n;
    const side = GlassPill.defaultHeight;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showBack) ...[
          Tooltip(
            message: l10n.commonBack,
            child: Semantics(
              label: l10n.commonBack,
              button: true,
              onTap: onBack,
              excludeSemantics: true,
              child: GlassPill(
                key: backKey,
                onTap: onBack,
                child: const Icon(Icons.chevron_left_rounded, size: 22),
              ),
            ),
          ),
          const SizedBox(width: gap),
        ],
        Expanded(
          child: titleText == null
              ? const SizedBox.shrink()
              : Text(
                  titleText,
                  key: titleKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xD9FFFFFF), // white @ 0.85
                  ),
                ),
        ),
        if (onScalingTap != null || cast != null) ...[
          const SizedBox(width: gap),
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
      ],
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
