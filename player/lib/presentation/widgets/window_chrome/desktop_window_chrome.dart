import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/window/decoration_layout.dart';
import '../../../core/window/window_buttons_hidden.dart';
import '../../../core/window/window_controller.dart';
import '../../../core/window/window_controller_native.dart';
import '../../../core/window/window_fullscreen.dart';
import 'window_buttons.dart';
import 'window_drag_band.dart';
import 'window_resize_edges.dart';

/// Draws the window's own decorations inside the window, on platforms where
/// the OS no longer does.
///
/// Mounted once, outermost in the `MaterialApp.router` builder alongside
/// `WindowChromeInset`. That file's doc comment records why anywhere else is
/// unsafe: a per-screen treatment is what let the detail screens and the
/// player slide under the macOS traffic lights in the first place.
///
/// Linux only for now. macOS keeps AppKit's traffic lights, which float over
/// the Flutter view already, and Windows still has its native caption.
class DesktopWindowChrome extends StatelessWidget {
  const DesktopWindowChrome({
    super.key,
    required this.child,
    required ValueListenable<DecorationLayout> layout,
    WindowController? controller,
    ValueListenable<bool>? fullscreen,
    ValueListenable<bool>? buttonsHidden,
  })  : _layout = layout,
        _controller = controller,
        _fullscreen = fullscreen,
        _buttonsHidden = buttonsHidden;

  final Widget child;

  final ValueListenable<DecorationLayout> _layout;

  /// Injected by tests. Defaults to the real window.
  final WindowController? _controller;

  /// Injected by tests. Default to the app-wide signals.
  final ValueListenable<bool>? _fullscreen;
  final ValueListenable<bool>? _buttonsHidden;

  @override
  Widget build(BuildContext context) {
    final isWeb = kIsWeb;
    final platform = defaultTargetPlatform;

    // Short-circuits before subscribing to any signal: off Linux (and on web,
    // where `defaultTargetPlatform` reports the host OS but there is no
    // window to decorate) nothing can flip this decision, so there is no
    // reason to rebuild on it.
    if (isWeb || platform != TargetPlatform.linux) return child;

    return ValueListenableBuilder<bool>(
      valueListenable: _fullscreen ?? windowFullscreen,
      builder: (context, isFullscreen, _) {
        if (!shouldShowWindowChrome(
          isWeb: isWeb,
          platform: platform,
          isFullscreen: isFullscreen,
        )) {
          return child;
        }

        final controller = _controller ?? const WindowManagerController();

        return WindowResizeEdges(
          controller: controller,
          child: Stack(
            children: [
              Positioned.fill(child: child),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: WindowDragBand(
                  controller: controller,
                  height: kLinuxWindowChromeHeight,
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: kLinuxWindowChromeHeight,
                child: _buttons(controller),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The buttons fade out with the playback chrome, while the drag band and
  /// the resize edges stay live. They are invisible either way, and losing
  /// the ability to move or resize the window mid-playback would be a
  /// regression.
  Widget _buttons(WindowController controller) {
    return ValueListenableBuilder<bool>(
      valueListenable: _buttonsHidden ?? windowButtonsHidden,
      builder: (context, hidden, _) {
        if (hidden) return const SizedBox.shrink();

        return ValueListenableBuilder<DecorationLayout>(
          valueListenable: _layout,
          builder: (context, layout, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                WindowButtons(buttons: layout.start, controller: controller),
                const Spacer(),
                WindowButtons(buttons: layout.end, controller: controller),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Whether the Flutter-drawn window chrome should be mounted.
///
/// Pure, and exposed separately so it can be unit-tested for every input
/// combination. `kIsWeb` is a compile-time constant that is always `false`
/// under `flutter test`, so a regression deleting the web check from
/// [DesktopWindowChrome.build] would pass every widget test unless the
/// underlying logic is tested on explicit inputs. Same reasoning as
/// `windowChromeInsetFor`.
@visibleForTesting
bool shouldShowWindowChrome({
  required bool isWeb,
  required TargetPlatform platform,
  required bool isFullscreen,
}) =>
    !isWeb && platform == TargetPlatform.linux && !isFullscreen;
