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

        return _WindowChrome(
          layout: _layout,
          controller: _controller ?? const WindowManagerController(),
          buttonsHidden: _buttonsHidden ?? windowButtonsHidden,
          child: child,
        );
      },
    );
  }
}

/// The Linux branch of [DesktopWindowChrome].
///
/// Split into its own widget so the hover state that keeps the buttons alive
/// under an approaching cursor has somewhere to live, without making the
/// public widget stateful on every platform.
class _WindowChrome extends StatefulWidget {
  const _WindowChrome({
    required this.child,
    required this.layout,
    required this.controller,
    required this.buttonsHidden,
  });

  final Widget child;
  final ValueListenable<DecorationLayout> layout;
  final WindowController controller;
  final ValueListenable<bool> buttonsHidden;

  @override
  State<_WindowChrome> createState() => _WindowChromeState();
}

class _WindowChromeState extends State<_WindowChrome> {
  /// Whether the pointer is somewhere in the top strip.
  ///
  /// Tracked because the strip is drawn *over* the app, so everything beneath
  /// it — the player's chrome most visibly — sees a pointer moving up into the
  /// strip as a `PointerExitEvent` and concludes the pointer left the window.
  /// The player answers that by hiding its chrome, which sets
  /// `windowButtonsHidden`, which used to delete the very buttons the cursor
  /// was travelling towards. `ChromeVisibility` already refuses to fade out
  /// from under a cursor resting on one of its own controls; this is that same
  /// rule applied to the window buttons.
  bool _pointerOverStrip = false;

  void _setPointerOverStrip(bool over) {
    if (_pointerOverStrip == over) return;
    setState(() => _pointerOverStrip = over);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: WindowResizeEdges(
            controller: widget.controller,
            child: Stack(
              children: [
                Positioned.fill(child: widget.child),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: WindowDragBand(
                    controller: widget.controller,
                    height: kLinuxWindowChromeHeight,
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: kLinuxWindowChromeHeight,
                  child: _buttons(),
                ),
              ],
            ),
          ),
        ),

        // Topmost so nothing can shadow it — not the resize edges above the
        // strip, not the drag band, not the buttons themselves — and
        // `opaque: false` so it shadows nothing in turn.
        // `RenderMouseRegion.hitTest` returns `super.hitTest(...) && _opaque`,
        // which still records the region for the mouse tracker while
        // answering false, so the hit test carries on into the siblings
        // underneath and every gesture below behaves exactly as it did.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: kLinuxWindowChromeHeight,
          child: MouseRegion(
            opaque: false,
            onEnter: (_) => _setPointerOverStrip(true),
            onExit: (_) => _setPointerOverStrip(false),
          ),
        ),
      ],
    );
  }

  /// The buttons fade out with the playback chrome, while the drag band and
  /// the resize edges stay live. They are invisible either way, and losing
  /// the ability to move or resize the window mid-playback would be a
  /// regression.
  ///
  /// A pointer inside the strip overrides the hidden state in both
  /// directions: buttons under the cursor are never taken away, and reaching
  /// for the top of the window during playback brings them back rather than
  /// leaving a viewer to hunt for controls that are not drawn.
  Widget _buttons() {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.buttonsHidden,
      builder: (context, hidden, _) {
        if (hidden && !_pointerOverStrip) return const SizedBox.shrink();

        return ValueListenableBuilder<DecorationLayout>(
          valueListenable: widget.layout,
          builder: (context, layout, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                WindowButtons(
                  buttons: layout.start,
                  controller: widget.controller,
                ),
                const Spacer(),
                WindowButtons(
                  buttons: layout.end,
                  controller: widget.controller,
                ),
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
