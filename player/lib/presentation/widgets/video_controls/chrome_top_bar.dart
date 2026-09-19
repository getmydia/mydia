import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import '../glass_surface.dart';

/// A 36px-tall pill in the OSD material ([GlassSurface.osd]).
///
/// Each piece of top chrome carries its own surface, which is what makes a
/// full-width scrim unnecessary. Text and icons carry no shadow: the OSD fill
/// holds their contrast on its own (`osd_legibility_test.dart`).
class GlassPill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// Pill height. Defaults to [defaultHeight]; `UpNextPrompt` passes 44 at the
  /// touch tier so its two hit targets clear the 44px floor. The three
  /// top-bar pills take the default and are unchanged.
  final double height;

  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.height = defaultHeight,
  });

  /// Default pill height. Matched across all three top-bar pills.
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
              data: const IconThemeData(
                size: 18,
                color: Color(0xCCFFFFFF),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );

    content = GlassSurface.osd(
      elevation: OsdElevation.pill,
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

/// The playback screen's top chrome: back, title, and cast pills.
///
/// Replaces the former left-aligned chevron-and-title row that lived in
/// `player_screen.dart`, so all playback chrome is owned by one widget.
class ChromeTopBar extends StatelessWidget {
  /// Media title. When null the title pill is omitted.
  final String? title;

  /// Back action. When null the back pill is inert but still rendered, so the
  /// title stays optically centered.
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

  const ChromeTopBar({
    super.key,
    this.title,
    this.onBack,
    this.showBack = true,
    this.castAction,
    this.onCastTap,
  });

  static const Key backKey = Key('chrome-back');
  static const Key titleKey = Key('chrome-title');
  static const Key castKey = Key('chrome-cast');

  @override
  Widget build(BuildContext context) {
    final titleText = title;
    final cast = castAction;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: !showBack
                ? const SizedBox.shrink()
                : GlassPill(
                    key: backKey,
                    onTap: onBack,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chevron_left_rounded),
                        SizedBox(width: 2),
                        Text('Back'),
                      ],
                    ),
                  ),
          ),
        ),
        if (titleText != null)
          Flexible(
            flex: 2,
            // A bare Flexible only bounds its child's max width; Flutter
            // anchors a loose-fit child (GlassPill shrink-wraps to its own
            // text width) to the *leading* edge of its allotted slot, not
            // the slot's center. Without this Center, the title pill sits
            // left-aligned within the middle 50% of the row instead of
            // centered on the row as a whole — confirmed via
            // tester.getRect in chrome_top_bar_test.dart (a bug that a
            // property assertion like "title pill exists" cannot catch).
            child: Center(
              child: GlassPill(
                key: titleKey,
                child: Text(
                  titleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xCCFFFFFF), // white @ 0.80
                  ),
                ),
              ),
            ),
          ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: cast == null
                ? const SizedBox.shrink()
                : GlassPill(
                    key: castKey,
                    onTap: onCastTap,
                    child: cast,
                  ),
          ),
        ),
      ],
    );
  }
}
