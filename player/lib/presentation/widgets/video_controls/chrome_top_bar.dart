import 'package:flutter/material.dart';

import '../../../core/player/platform_features.dart';
import '../../../core/theme/depth_tokens.dart';
import '../glass_surface.dart';

/// A 36px-tall pill in the playback glass material.
///
/// Each piece of top chrome carries its own surface, which is what makes a
/// full-width scrim unnecessary. Unlike [chrome_panel.dart]'s ~130px-tall
/// panel, a pill is short enough that GlassSurface.playerChrome's top-to-
/// bottom gradient compresses into a much shorter ramp across it — see
/// `pill_legibility_test.dart`, which measures that fill alone leaves pill
/// text well under the WCAG 4.5:1 text-contrast floor at this height, unlike
/// the panel it was tuned for. [GlassPill] closes that gap with a small,
/// targeted text shadow (matching the same treatment/precedent set for
/// `ChromePanel`'s row-2 timecodes) rather than by making the fill denser,
/// which would push the panel's shared fill tokens back above
/// [DepthTokens.glassLegibilityFloor] and erase this material's whole
/// transparency claim.
class GlassPill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final PlayerGlassTier? tier;

  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.tier,
  });

  /// Pill height. Matched across all three top-bar pills.
  static const double height = 36.0;

  /// Text shadow applied to pill text only (never to icons) — measured in
  /// `pill_legibility_test.dart` to bring worst-case text contrast from
  /// 2.4671976733802308:1 (fill alone, over the pill's 36px gradient) to
  /// 7.755850943957899:1, comfortably above the WCAG SC 1.4.3 floor of
  /// 4.5:1. Same alpha as the precedent set for `ChromePanel`'s row-2
  /// timecodes (`Colors.black` @ 0.6 — `Color(0x99000000)`, since
  /// `Colors.black54` is 0x8A, alpha ~0.541, not 0.6); blur radius is
  /// smaller here (3px vs. 4px) to match the pill's smaller scale.
  static const List<Shadow> textShadow = [
    Shadow(color: Color(0x99000000), blurRadius: 3),
  ];

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
              shadows: textShadow,
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

    content = GlassSurface.playerChrome(
      tier: tier,
      borderRadius: const BorderRadius.all(
        Radius.circular(DepthTokens.radiusPlayerPill),
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

  /// Cast / AirPlay affordance. When null the pill is omitted.
  final Widget? castAction;

  /// Cast tap handler. Lives here rather than inside [castAction] so the whole
  /// pill is the tap target: an 18px glyph in a 36px pill would leave most of
  /// the affordance dead to touch, and only the pill can offer the hover
  /// cursor. When null the pill renders but is inert, like the back pill.
  final VoidCallback? onCastTap;

  final PlayerGlassTier? tier;

  const ChromeTopBar({
    super.key,
    this.title,
    this.onBack,
    this.castAction,
    this.onCastTap,
    this.tier,
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
            child: GlassPill(
              key: backKey,
              tier: tier,
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
                tier: tier,
                child: Text(
                  titleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xCCFFFFFF), // white @ 0.80
                    shadows: GlassPill.textShadow,
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
                    tier: tier,
                    onTap: onCastTap,
                    child: cast,
                  ),
          ),
        ),
      ],
    );
  }
}
