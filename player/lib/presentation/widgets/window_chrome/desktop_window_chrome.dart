import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/window/decoration_layout.dart';
import '../../../core/window/window_buttons_hidden.dart';
import '../../../core/window/window_controller.dart';
import '../../../core/window/window_controller_native.dart';
import '../../../core/window/window_fullscreen.dart';
import 'window_buttons.dart';
import 'window_resize_edges.dart';

/// Draws the window's own decorations inside the window, on platforms where
/// the OS no longer does.
///
/// Mounted once, outermost in the `MaterialApp.router` builder alongside
/// `WindowChromeInset`. That file's doc comment records why anywhere else is
/// unsafe: a per-screen treatment is what let the detail screens and the
/// player slide under the macOS traffic lights in the first place.
///
/// Draws only the button corners now, not a full-width strip: dragging the
/// window is `WindowTitleRow`'s job, mounted per screen, and the player's own
/// video surface answers to a drag started over it too (`onWindowDrag` in
/// `playback_chrome.dart`). This widget only ever needed the strip to host
/// the buttons and their hover tracking, and both now fit in the corners
/// they actually occupy, per `linuxButtonGroupReserve`.
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
  /// Whether the pointer is somewhere in one of the button corners.
  ///
  /// Tracked because a corner is drawn *over* the app, so everything beneath
  /// it, the player's chrome most visibly, sees a pointer moving into the
  /// corner as a `PointerExitEvent` and concludes the pointer left the
  /// window. The player answers that by hiding its chrome, which sets
  /// `windowButtonsHidden`, which used to delete the very buttons the cursor
  /// was travelling towards. `ChromeVisibility` already refuses to fade out
  /// from under a cursor resting on one of its own controls; this is that same
  /// rule applied to the window buttons.
  bool _pointerOverButtons = false;

  void _setPointerOverButtons(bool over) {
    if (_pointerOverButtons == over) return;
    setState(() => _pointerOverButtons = over);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: WindowResizeEdges(
            controller: widget.controller,
            child: widget.child,
          ),
        ),

        // On top of the resize edges (and everything else): the button
        // corners are the only part of this widget still drawn over the app,
        // and only where a corner actually has buttons in it.
        ValueListenableBuilder<DecorationLayout>(
          valueListenable: widget.layout,
          builder: (context, layout, _) => Stack(children: _corners(layout)),
        ),
      ],
    );
  }

  /// One `Positioned` per side that actually carries buttons, sized to
  /// exactly the corner `linuxButtonGroupReserve` clears for it and no
  /// further. An empty side gets no widget at all: nothing there needs a hit
  /// area, and drawing one would just be more surface for a stray tap or
  /// hover to hit for no reason.
  List<Widget> _corners(DecorationLayout layout) => [
        for (final (isStart, buttons) in [
          (true, layout.start),
          (false, layout.end),
        ])
          if (buttons.isNotEmpty)
            PositionedDirectional(
              top: 0,
              start: isStart ? 0 : null,
              end: isStart ? null : 0,
              height: kLinuxWindowChromeHeight,
              child: MouseRegion(
                opaque: false,
                onEnter: (_) => _setPointerOverButtons(true),
                onExit: (_) => _setPointerOverButtons(false),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: kLinuxChromeEdgePadding,
                  ),
                  child: _buttons(buttons),
                ),
              ),
            ),
      ];

  /// The buttons fade out with the playback chrome, while the resize edges
  /// stay live. They are invisible either way, and losing the ability to
  /// resize the window mid-playback would be a regression.
  ///
  /// A pointer inside the corner overrides the hidden state in both
  /// directions: buttons under the cursor are never taken away, and reaching
  /// for a corner during playback brings them back rather than leaving a
  /// viewer to hunt for controls that are not drawn.
  ///
  /// Hidden state keeps a `SizedBox` the width the buttons would occupy
  /// rather than `SizedBox.shrink()`: shrinking to nothing would shrink the
  /// corner's `MouseRegion` right along with it, and a pointer aimed at
  /// where the buttons used to be would land past the hover region that is
  /// supposed to bring them back.
  Widget _buttons(List<WindowButton> buttons) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.buttonsHidden,
      builder: (context, hidden, _) {
        if (hidden && !_pointerOverButtons) {
          return SizedBox(
            width: buttons.length * kLinuxWindowButtonExtent,
            height: kLinuxWindowChromeHeight,
          );
        }
        return WindowButtons(buttons: buttons, controller: widget.controller);
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
/// `windowChromeInsetsFor`.
@visibleForTesting
bool shouldShowWindowChrome({
  required bool isWeb,
  required TargetPlatform platform,
  required bool isFullscreen,
}) =>
    !isWeb && platform == TargetPlatform.linux && !isFullscreen;
