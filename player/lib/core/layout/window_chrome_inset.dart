import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../window/window_fullscreen.dart';

/// Height of the macOS title bar strip the traffic light window controls
/// float in.
///
/// `MainFlutterWindow.swift` sets `titlebarAppearsTransparent`, hides the
/// title and inserts `.fullSizeContentView`, so the Flutter view runs under
/// the title bar and AppKit draws the close/minimize/zoom buttons on top of
/// it at roughly x 7-75, y 8-28. The embedder reports no safe-area inset for
/// that strip, so the app has to reserve it.
///
/// 28 is the standard regular-height title bar. The buttons span roughly
/// y14-y26, so this clears them with a few points to spare.
const double kMacTitleBarOverlap = 28.0;

/// Height of the band reserved at the top of the Linux window for the
/// Flutter-drawn window buttons.
///
/// Full width rather than only as wide as the buttons. The sidebar and the
/// content column then both clear it with no side-specific logic, which
/// matters because a user whose `gtk-decoration-layout` puts buttons on the
/// start side would otherwise have them land on top of the sidebar's logo.
/// It also makes the whole top edge a drag target instead of a narrow gap
/// beside the buttons. `MediaQuery.padding.top` could not express a
/// one-sided inset anyway.
const double kLinuxWindowChromeHeight = 36.0;

/// Reserves the macOS title bar strip by republishing [MediaQuery] with a
/// larger `padding.top`.
///
/// Mounted once, outermost in the `MaterialApp.router` builder. Injecting into
/// `MediaQuery` rather than padding individual screens means `SafeArea`,
/// `Scaffold`, `AppBar` and `SliverAppBar` all honour the strip for free, so
/// a screen cannot forget it — which is exactly how the detail screens and the
/// player ended up under the traffic lights in the first place.
///
/// Full-bleed layers stay full-bleed: the video surface and the ambient
/// backdrop sit outside any `SafeArea`, so they are unaffected by this.
class WindowChromeInset extends StatelessWidget {
  const WindowChromeInset({
    super.key,
    required this.child,
    ValueListenable<bool>? fullscreen,
  }) : _fullscreen = fullscreen;

  final Widget child;

  /// Injected by tests. Defaults to the app-wide [windowFullscreen] signal.
  final ValueListenable<bool>? _fullscreen;

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
      return child;
    }

    return ValueListenableBuilder<bool>(
      valueListenable: _fullscreen ?? windowFullscreen,
      builder: (context, isFullscreen, child) {
        final inset = windowChromeInsetFor(
          isWeb: isWeb,
          platform: platform,
          isFullscreen: isFullscreen,
        );
        if (inset == 0) return child!;

        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(
              top: media.padding.top + inset,
            ),
          ),
          child: child!,
        );
      },
      child: child,
    );
  }
}

/// How much vertical space the OS window chrome needs reserved at the top,
/// in logical pixels.
///
/// Pure, and exposed separately from [WindowChromeInset.build] so it can be
/// unit-tested for every input combination without actually running on each
/// platform.
///
/// `kIsWeb` is a compile-time constant baked in per build target — it is
/// always `false` under `flutter test`, so a regression that deleted the web
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
double windowChromeInsetFor({
  required bool isWeb,
  required TargetPlatform platform,
  required bool isFullscreen,
}) {
  if (isWeb || isFullscreen) return 0;
  return switch (platform) {
    TargetPlatform.macOS => kMacTitleBarOverlap,
    TargetPlatform.linux => kLinuxWindowChromeHeight,
    _ => 0,
  };
}
