import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../window/decoration_layout.dart';
import '../window/window_fullscreen.dart';

/// Height of the macOS title bar band the traffic light window controls
/// float in.
///
/// `MainFlutterWindow.swift` sets `titlebarAppearsTransparent`, hides the
/// title, inserts `.fullSizeContentView` and attaches an empty toolbar with
/// the `.unifiedCompact` style, so the Flutter view runs under a 40pt band
/// with AppKit's close/minimize/zoom buttons centred in it, the proportions
/// of Music, TV and Finder. Measured on macOS: the buttons span x 12-71,
/// y 13-26. The embedder reports no safe-area inset for that
/// band, so the app has to reserve it.
///
/// If the toolbar style changes, remeasure: `window.frame.height -
/// window.contentLayoutRect.height` in a debug build gives the band height.
const double kMacTitleBarOverlap = 40.0;

/// Height of the title row drawn at the top of the Linux window, where the
/// Flutter-drawn window buttons sit.
///
/// Close to a GNOME/libadwaita headerbar (47px with 34px buttons), so the
/// window sits naturally among native apps: the 32px title-row controls get
/// 7px above and below, and the 28px window buttons 9px.
///
/// No longer a full-width reserved band: [windowChromeInsetsFor] only
/// reserves the corners the buttons occupy, sized by
/// [linuxButtonGroupReserve]. This is the row's height, used to size the
/// drag band and the button strip `DesktopWindowChrome` positions over it.
const double kLinuxWindowChromeHeight = 46.0;

/// Width kept clear at the macOS title bar's leading edge for the traffic
/// lights.
///
/// The lights span x 12-71 per the measurement in [kMacTitleBarOverlap]'s
/// doc comment, plus a 9pt gap before whatever draws next to them.
/// Remeasure together with [kMacTitleBarOverlap] if the toolbar style ever
/// changes.
const double kMacTrafficLightsWidth = 80.0;

/// Width of one Flutter-drawn Linux window button, padding included.
///
/// Must match `WindowButtonWidget.size` (28) in `window_button.dart` plus
/// the 2px horizontal padding `WindowButtons` wraps each one in, in
/// `window_buttons.dart`.
const double kLinuxWindowButtonExtent = 32.0;

/// Padding between the window edge and the first Linux window button.
///
/// Must match the 6px horizontal padding `DesktopWindowChrome` wraps its
/// button row in, in `desktop_window_chrome.dart`.
const double kLinuxChromeEdgePadding = 6.0;

/// Gap left between the outermost Linux window button and whatever content
/// starts past the reserved corner.
const double kLinuxChromeGap = 8.0;

/// Corner radius of the floating Linux window.
///
/// Must equal the `border-radius` in `kFrameCss` in
/// `linux/runner/my_application.cc`: GTK rounds the frame and shadow to that
/// curve and `DesktopWindowChrome` clips the Flutter view to this one, so a
/// mismatch shows as a sliver of frame or a square app corner.
const double kLinuxWindowCornerRadius = 15.0;

/// Fallback [DecorationLayout] used by [WindowChromeInset.build] when no real
/// signal is injected. Only Linux ever consults it, and `app.dart` always
/// passes the real signal there, so in practice this only feeds tests.
///
/// A single top-level instance, never mutated: the value it holds never
/// changes, so allocating a fresh `ValueNotifier` on every `build` would only
/// create and immediately discard a `ChangeNotifier` on every rebuild for no
/// reason. Holding one instance here avoids that churn.
final ValueNotifier<DecorationLayout> _fallbackDecorationLayout =
    ValueNotifier(parseDecorationLayout(kFallbackDecorationLayout));

/// How much room the OS window controls need: a band height, plus the width
/// kept clear at each edge of that band for the controls themselves.
@immutable
class WindowChromeInsets {
  const WindowChromeInsets({
    required this.height,
    required this.leading,
    required this.trailing,
  });

  static const zero = WindowChromeInsets(height: 0, leading: 0, trailing: 0);

  /// Height of the title-bar band the window controls sit in.
  final double height;

  /// Width kept clear at the start and end edges of the band, directional.
  final double leading;
  final double trailing;

  bool get isZero => height == 0;

  WindowChromeInsets copyWith({double? leading, double? trailing}) =>
      WindowChromeInsets(
        height: height,
        leading: leading ?? this.leading,
        trailing: trailing ?? this.trailing,
      );

  static WindowChromeInsets of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_WindowChromeInsetsScope>()
          ?.insets ??
      zero;

  static Widget scope({
    required WindowChromeInsets insets,
    required Widget child,
  }) =>
      _WindowChromeInsetsScope(insets: insets, child: child);

  /// Takes the band back out of `MediaQuery.padding.top` for [child], which
  /// draws its own title row into it. Anything else in the padding, such as
  /// a phone's status bar, is left in place.
  static Widget removeBand({required Widget child}) => Builder(
        builder: (context) {
          final band = of(context).height;
          if (band == 0) return child;
          final media = MediaQuery.of(context);
          final top = media.padding.top - band;
          return MediaQuery(
            data: media.copyWith(
              padding: media.padding.copyWith(top: top < 0 ? 0 : top),
            ),
            child: child,
          );
        },
      );

  @override
  bool operator ==(Object other) =>
      other is WindowChromeInsets &&
      other.height == height &&
      other.leading == leading &&
      other.trailing == trailing;

  @override
  int get hashCode => Object.hash(height, leading, trailing);

  @override
  String toString() =>
      'WindowChromeInsets(height: $height, leading: $leading, trailing: $trailing)';
}

class _WindowChromeInsetsScope extends InheritedWidget {
  const _WindowChromeInsetsScope({required this.insets, required super.child});

  final WindowChromeInsets insets;

  @override
  bool updateShouldNotify(_WindowChromeInsetsScope old) => old.insets != insets;
}

/// How much width one side's group of Linux window buttons needs kept clear,
/// including the strip's edge padding and the gap before content.
///
/// Zero for an empty group: a side with no buttons on it needs no edge
/// padding or gap either, since there is nothing there to pad or clear.
double linuxButtonGroupReserve(int buttonCount) => buttonCount == 0
    ? 0
    : kLinuxChromeEdgePadding +
        buttonCount * kLinuxWindowButtonExtent +
        kLinuxChromeGap;

/// How much room the OS window controls need reserved, in logical pixels.
///
/// Pure, and exposed separately from [WindowChromeInset.build] so it can be
/// unit-tested for every input combination without actually running on each
/// platform.
///
/// `kIsWeb` is a compile-time constant baked in per build target (it is
/// always `false` under `flutter test`), so a regression that deleted the web
/// check from [WindowChromeInset.build] would pass every test unless the
/// underlying logic is tested independently of the real `kIsWeb` value.
/// Mirrors `PlatformFeatures.computeSupportsKeyboardShortcuts` in
/// `platform_features.dart`, which exists for exactly the same reason.
///
/// Web is checked first: `defaultTargetPlatform` reports macOS for Safari and
/// Chrome on a Mac, where there is no frameless window and no buttons to
/// clear. Fullscreen is checked next: macOS auto-hides the traffic lights
/// there and the Linux chrome unmounts itself, so reserving the strip would
/// only letterbox the video.
@visibleForTesting
WindowChromeInsets windowChromeInsetsFor({
  required bool isWeb,
  required TargetPlatform platform,
  required bool isFullscreen,
  required DecorationLayout decorationLayout,
  required TextDirection textDirection,
}) {
  if (isWeb || isFullscreen) return WindowChromeInsets.zero;
  switch (platform) {
    case TargetPlatform.macOS:
      // AppKit keeps the lights on the physical left under RTL too.
      final ltr = textDirection == TextDirection.ltr;
      return WindowChromeInsets(
        height: kMacTitleBarOverlap,
        leading: ltr ? kMacTrafficLightsWidth : 0,
        trailing: ltr ? 0 : kMacTrafficLightsWidth,
      );
    case TargetPlatform.linux:
      return WindowChromeInsets(
        height: kLinuxWindowChromeHeight,
        leading: linuxButtonGroupReserve(decorationLayout.start.length),
        trailing: linuxButtonGroupReserve(decorationLayout.end.length),
      );
    default:
      return WindowChromeInsets.zero;
  }
}

/// Reserves the macOS title bar strip or the Linux button corners by
/// republishing [MediaQuery] with a larger `padding.top`, and publishes the
/// resolved [WindowChromeInsets] to descendants via [WindowChromeInsets.of].
///
/// Mounted once, outermost in the `MaterialApp.router` builder. Injecting into
/// `MediaQuery` rather than padding individual screens means `SafeArea`,
/// `Scaffold`, `AppBar` and `SliverAppBar` all honour the strip for free, so
/// a screen cannot forget it — which is exactly how the detail screens and the
/// player ended up under the traffic lights in the first place. A screen that
/// wants to draw its own title row into that space instead opts out of the
/// padding with `WindowTitleRow` (or [WindowChromeInsets.removeBand]
/// directly), reading [WindowChromeInsets.of] for how much room the window
/// controls actually need at each edge.
///
/// Full-bleed layers stay full-bleed: the video surface and the ambient
/// backdrop sit outside any `SafeArea`, so they are unaffected by this.
class WindowChromeInset extends StatelessWidget {
  const WindowChromeInset({
    super.key,
    required this.child,
    ValueListenable<bool>? fullscreen,
    ValueListenable<DecorationLayout>? decorationLayout,
  })  : _fullscreen = fullscreen,
        _decorationLayout = decorationLayout;

  final Widget child;

  /// Injected by tests. Defaults to the app-wide [windowFullscreen] signal.
  final ValueListenable<bool>? _fullscreen;

  /// Injected by tests. Defaults to the fallback layout, since only Linux
  /// consults it and `app.dart` always passes the real signal there.
  final ValueListenable<DecorationLayout>? _decorationLayout;

  @override
  Widget build(BuildContext context) {
    final isWeb = kIsWeb;
    final platform = defaultTargetPlatform;

    // Short-circuits before ever subscribing to the fullscreen signal: on a
    // platform with no Flutter-drawn chrome (and on web, where
    // `defaultTargetPlatform` reports macOS for Safari/Chrome on a Mac but
    // there is no frameless window to clear) fullscreen can never flip this
    // decision, so there is no reason to rebuild on it.
    if (isWeb ||
        (platform != TargetPlatform.macOS &&
            platform != TargetPlatform.linux)) {
      return WindowChromeInsets.scope(
        insets: WindowChromeInsets.zero,
        child: child,
      );
    }

    return ValueListenableBuilder<bool>(
      valueListenable: _fullscreen ?? windowFullscreen,
      builder: (context, isFullscreen, child) {
        return ValueListenableBuilder<DecorationLayout>(
          valueListenable: _decorationLayout ?? _fallbackDecorationLayout,
          builder: (context, decorationLayout, child) {
            final insets = windowChromeInsetsFor(
              isWeb: isWeb,
              platform: platform,
              isFullscreen: isFullscreen,
              decorationLayout: decorationLayout,
              textDirection:
                  Directionality.maybeOf(context) ?? TextDirection.ltr,
            );
            if (insets.isZero) {
              return WindowChromeInsets.scope(insets: insets, child: child!);
            }

            final media = MediaQuery.of(context);
            return WindowChromeInsets.scope(
              insets: insets,
              child: MediaQuery(
                data: media.copyWith(
                  padding: media.padding.copyWith(
                    top: media.padding.top + insets.height,
                  ),
                ),
                child: child!,
              ),
            );
          },
          child: child,
        );
      },
      child: child,
    );
  }
}
