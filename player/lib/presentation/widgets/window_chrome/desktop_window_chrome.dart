import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/window/decoration_layout.dart';
import '../../../core/window/window_buttons_hidden.dart';
import '../../../core/window/window_controller.dart';
import '../../../core/window/window_controller_native.dart';
import '../../../core/window/window_frame_state.dart';
import '../../../core/window/window_fullscreen.dart';
import 'window_buttons.dart';

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
///
/// It also clips the app to the corner radius GTK rounds the window frame
/// to (`kFrameCss` in `linux/runner/my_application.cc`), squaring it
/// whenever GTK squares the frame. The Flutter view is transparent on Linux,
/// so the clipped-away corners show GTK's frame and shadow.
class DesktopWindowChrome extends StatelessWidget {
  const DesktopWindowChrome({
    super.key,
    required this.child,
    required ValueListenable<DecorationLayout> layout,
    required ValueListenable<WindowFrameState> frameState,
    WindowController? controller,
    ValueListenable<bool>? fullscreen,
    ValueListenable<bool>? buttonsHidden,
  })  : _layout = layout,
        _frameState = frameState,
        _controller = controller,
        _fullscreen = fullscreen,
        _buttonsHidden = buttonsHidden;

  /// The `ClipRRect` rounding the app to the GTK frame. Exposed for tests.
  static const Key clipKey = ValueKey('desktop-window-chrome-clip');

  final Widget child;

  final ValueListenable<DecorationLayout> _layout;

  /// Maximized / tiled / fullscreen, from `WindowFrameStateSource`. Drives
  /// the corner radius so the clip matches the frame GTK draws around it.
  final ValueListenable<WindowFrameState> _frameState;

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
          frameState: _frameState,
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
    required this.frameState,
    required this.controller,
    required this.buttonsHidden,
  });

  final Widget child;
  final ValueListenable<DecorationLayout> layout;
  final ValueListenable<WindowFrameState> frameState;
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
    // Always a `ClipRRect`, even when square: swapping it in and out would
    // change the tree shape and remount the entire app on every maximize.
    // `Clip.none` at radius zero skips the clip's cost entirely.
    return ValueListenableBuilder<WindowFrameState>(
      valueListenable: widget.frameState,
      builder: (context, state, stack) {
        final radius = windowCornerRadiusFor(state);
        return ClipRRect(
          key: DesktopWindowChrome.clipKey,
          borderRadius:
              radius == 0 ? BorderRadius.zero : BorderRadius.circular(radius),
          clipBehavior: radius == 0 ? Clip.none : Clip.antiAlias,
          child: stack,
        );
      },
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),

          // On top of everything else: the button
          // corners are the only part of this widget still drawn over the app,
          // and only where a corner actually has buttons in it.
          ValueListenableBuilder<DecorationLayout>(
            valueListenable: widget.layout,
            builder: (context, layout, _) => Stack(children: _corners(layout)),
          ),
        ],
      ),
    );
  }

  /// Two `Positioned` per side that actually carries buttons (none for an
  /// empty side: nothing there needs a hit area, and drawing one would just
  /// be more surface for a stray tap or hover to hit for no reason), each
  /// covering the same rect at exactly `_cornerWidth` and
  /// `kLinuxWindowChromeHeight`:
  ///
  /// - The buttons themselves, a plain positioned child with nothing wrapping
  ///   it that could steal its hit test. A tap on a button has to return
  ///   `true` all the way up through this entry so the `Stack` stops right
  ///   here, the same as it always did before this widget grew corners: a
  ///   click on close or minimize must never also reach whatever the corner
  ///   happens to be drawn over (the resize edges, and beyond them the app's
  ///   own content, one layer of which is `WindowTitleRow`'s drag band).
  /// - A hover-tracking `MouseRegion`, listed after (so painted on top of)
  ///   the buttons entry, with no child of its own and `opaque: false`. See
  ///   its own comment below for why it is a separate sibling rather than a
  ///   wrapper around the buttons.
  List<Widget> _corners(DecorationLayout layout) => [
        for (final (isStart, buttons) in [
          (true, layout.start),
          (false, layout.end),
        ])
          if (buttons.isNotEmpty) ...[
            PositionedDirectional(
              top: 0,
              start: isStart ? 0 : null,
              end: isStart ? null : 0,
              height: kLinuxWindowChromeHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kLinuxChromeEdgePadding,
                ),
                child: _buttons(buttons),
              ),
            ),

            // Topmost so nothing can shadow it, and `opaque: false` so it
            // shadows nothing in turn. `RenderMouseRegion.hitTest` returns
            // `super.hitTest(...) && opaque`, which still records the region
            // for the mouse tracker while answering false, so the hit test
            // carries on into the buttons entry beneath and every gesture
            // there behaves exactly as it would with no hover region here at
            // all. Wrapping the buttons in this `MouseRegion` instead of
            // stacking it as a sibling, as an earlier version of this widget
            // did, would make the *buttons'* own successful hit test return
            // false too (the whole point of `opaque: false` is to always
            // answer false), letting the tap fall through to whatever the
            // corner sits over. That silently doubled every button press
            // into a click on `WindowTitleRow`'s drag band underneath, which
            // holds the gesture arena for `kDoubleTapTimeout` waiting to see
            // if it becomes a double-click-to-maximize.
            PositionedDirectional(
              top: 0,
              start: isStart ? 0 : null,
              end: isStart ? null : 0,
              height: kLinuxWindowChromeHeight,
              width: _cornerWidth(buttons.length),
              child: MouseRegion(
                opaque: false,
                onEnter: (_) => _setPointerOverButtons(true),
                onExit: (_) => _setPointerOverButtons(false),
              ),
            ),
          ],
      ];

  /// Width of one side's button group exactly as `_buttons` draws it: edge
  /// padding on both sides of the row, plus the buttons themselves, the same
  /// whether they are actually visible or standing in as the hidden-state
  /// placeholder. Deliberately not `linuxButtonGroupReserve`, which also
  /// budgets `kLinuxChromeGap` for content clearance elsewhere and does not
  /// describe what is drawn here.
  static double _cornerWidth(int buttonCount) =>
      2 * kLinuxChromeEdgePadding + buttonCount * kLinuxWindowButtonExtent;

  /// The buttons fade out with the playback chrome.
  ///
  /// A pointer inside the corner overrides the hidden state in both
  /// directions: buttons under the cursor are never taken away, and reaching
  /// for a corner during playback brings them back rather than leaving a
  /// viewer to hunt for controls that are not drawn.
  ///
  /// Hidden state keeps a `SizedBox` the width the buttons would occupy
  /// rather than `SizedBox.shrink()`, so this entry's rendered size always
  /// matches `_cornerWidth`, the fixed size the sibling hover `MouseRegion`
  /// in `_corners` covers regardless of hidden state. The hover region does
  /// not actually read this widget's size (it is a sibling, not a wrapper,
  /// precisely so a hit on a real button is never swallowed), but keeping
  /// the two in agreement is what makes `_cornerWidth`'s doc comment true.
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

/// The radius `DesktopWindowChrome` clips the app to.
///
/// Zero in every state where GTK squares its own frame (maximized, tiled,
/// fullscreen, or compositor-less `solidFrame`), so the clip always follows
/// the frame it sits in. Pure and exposed for the same reason as
/// [shouldShowWindowChrome].
@visibleForTesting
double windowCornerRadiusFor(WindowFrameState state) =>
    !state.isFloating || state.solidFrame ? 0.0 : kLinuxWindowCornerRadius;
