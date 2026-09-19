import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import 'toast_controller.dart';
import 'toast_models.dart';
import 'toast_pill.dart';
import 'toaster.dart';

/// Hosts the app's toasts above every route, dialog and the cast bar.
///
/// `app.dart` mounts this in `MaterialApp.router`'s `builder`, so a toast
/// outlives the route that showed it and scales with `TvCanvas` like the
/// rest of the UI. The pill centres in whatever the registered
/// `ToastObstruction`s leave free: right of the desktop sidebar, above the
/// mobile dock, the cast bar and the visible playback controls.
class ToastLayer extends StatefulWidget {
  const ToastLayer({super.key, required this.child});

  final Widget child;

  @override
  State<ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<ToastLayer> {
  final ToastController _controller = ToastController();
  final GlobalKey _stackKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _controller.layerBox =
        () => _stackKey.currentContext?.findRenderObject() as RenderBox?;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.accessibleNavigation =
        MediaQuery.accessibleNavigationOf(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return ToasterScope(
      controller: _controller,
      child: Stack(
        key: _stackKey,
        children: [
          widget.child,
          // Neither the padding nor the Align hit-tests its own empty space,
          // so everything outside the pill still reaches `child` below.
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  final insets = _controller.insetsFor(constraints.biggest);
                  final bottom = insets.bottom > 0
                      ? insets.bottom + ToastMetrics.obstructionGap
                      : safeBottom + ToastMetrics.restingGap;
                  // A claim can reach the layer's own far edge, and a gutter
                  // on each side of one that wide asks `Padding` for more
                  // width than the layer has, which deflates the pill to
                  // nothing. A claim that leaves no room for the pill plus
                  // both gutters degrades to the resting box: a gutter on
                  // each side of the whole layer, overlapping the claim
                  // rather than collapsing under it.
                  final cleared = constraints.maxWidth -
                      insets.left -
                      2 * ToastMetrics.gutter;
                  final entry = _controller.current;
                  return AnimatedPadding(
                    duration:
                        reduceMotion ? Duration.zero : DepthTokens.motionMedium,
                    curve: DepthTokens.curveEmphasized,
                    padding: EdgeInsets.only(
                      left: cleared > 0
                          ? insets.left + ToastMetrics.gutter
                          : ToastMetrics.gutter,
                      right: ToastMetrics.gutter,
                      bottom: bottom,
                    ),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: ExcludeFocus(
                        child: AnimatedSwitcher(
                          duration: DepthTokens.motionMedium,
                          switchInCurve: DepthTokens.curveStandard,
                          switchOutCurve: DepthTokens.curveStandard,
                          transitionBuilder: (child, animation) =>
                              _ToastTransition(
                            animation: animation,
                            reduceMotion: reduceMotion,
                            child: child,
                          ),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              ...previous,
                              if (current != null) current,
                            ],
                          ),
                          child: entry == null
                              ? const SizedBox.shrink()
                              : _ToastView(
                                  key: ValueKey<int>(entry.id),
                                  entry: entry,
                                  controller: _controller,
                                ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fade plus an [ToastMetrics.rise] rise on entry. The switcher runs the
/// same animation in reverse on exit, so the outgoing pill sinks as it fades.
class _ToastTransition extends StatelessWidget {
  const _ToastTransition({
    required this.animation,
    required this.reduceMotion,
    required this.child,
  });

  final Animation<double> animation;
  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final faded = FadeTransition(opacity: animation, child: child);
    if (reduceMotion) return faded;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, (1 - animation.value) * ToastMetrics.rise),
        child: child,
      ),
      child: faded,
    );
  }
}

/// One shown toast: hover pauses it, a downward swipe dismisses it.
class _ToastView extends StatefulWidget {
  const _ToastView({
    super.key,
    required this.entry,
    required this.controller,
  });

  final ToastEntry entry;
  final ToastController controller;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> {
  static const double _dismissDistance = 24;
  static const double _dismissVelocity = 300;

  /// Downward drag so far, so the pill follows the finger.
  double _drag = 0;

  void _close() => widget.controller.close(widget.entry.id);

  @override
  Widget build(BuildContext context) {
    final action = widget.entry.action;
    return MouseRegion(
      onEnter: (_) => widget.controller.pause(widget.entry.id),
      onExit: (_) => widget.controller.resume(widget.entry.id),
      child: GestureDetector(
        onVerticalDragUpdate: (details) =>
            setState(() => _drag = math.max(0, _drag + details.delta.dy)),
        onVerticalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (_drag > _dismissDistance || velocity > _dismissVelocity) {
            _close();
          } else {
            setState(() => _drag = 0);
          }
        },
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: ToastPill(
            entry: widget.entry,
            onAction: action == null
                ? null
                : () {
                    action.onPressed();
                    _close();
                  },
          ),
        ),
      ),
    );
  }
}
