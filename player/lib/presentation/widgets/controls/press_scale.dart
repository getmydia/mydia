import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/ui/reduced_motion.dart';

/// Press feedback for the Frosted theme: scales the child to [pressedScale]
/// while a pointer or an activation key (Select, Enter, Space, gameButtonA)
/// is held.
///
/// Keys are observed through [HardwareKeyboard] while focus is inside the
/// subtree, because the wrapped control's own shortcuts consume the key
/// before an ancestor [Focus] would see it. It observes input only. It adds no focus stop, no semantics, and never
/// consumes a key, so the wrapped control's own activation fires unchanged.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// When false the child is never scaled.
  final bool enabled;

  static const double pressedScale = 0.97;
  static const scaleKey = ValueKey('press-scale');

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale>
    with SingleTickerProviderStateMixin {
  static final _activationKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 160),
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 1.0,
    end: PressScale.pressedScale,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  bool _pointerDown = false;
  bool _keyDown = false;

  // Never a traversal stop; it only marks this subtree in the focus path.
  final FocusNode _focusNode = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    debugLabel: 'PressScale',
  );

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _sync() {
    final pressed = widget.enabled && (_pointerDown || _keyDown);
    if (pressed) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _setPointer(bool down) {
    _pointerDown = down;
    _sync();
  }

  // A global observer rather than Focus.onKeyEvent: a wrapped control's own
  // Shortcuts handle (and stop) the key before it bubbles to an ancestor
  // Focus. Observing never consumes the event (returns false), so the
  // control's ActivateIntent fires exactly once.
  bool _onKey(KeyEvent event) {
    if (!_activationKeys.contains(event.logicalKey)) return false;
    if (event is KeyDownEvent && _focusNode.hasFocus) {
      _keyDown = true;
      _sync();
    } else if (event is KeyUpEvent && _keyDown) {
      _keyDown = false;
      _sync();
    }
    return false;
  }

  @override
  void didUpdateWidget(PressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _sync();
  }

  @override
  Widget build(BuildContext context) {
    if (ReducedMotion.of(context)) {
      _controller.value = 0;
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _setPointer(true),
      onPointerUp: (_) => _setPointer(false),
      onPointerCancel: (_) => _setPointer(false),
      child: Focus(
        focusNode: _focusNode,
        child: AnimatedBuilder(
          animation: _scale,
          child: widget.child,
          builder: (context, child) => Transform.scale(
            key: PressScale.scaleKey,
            scale: ReducedMotion.of(context) ? 1.0 : _scale.value,
            child: child,
          ),
        ),
      ),
    );
  }
}
