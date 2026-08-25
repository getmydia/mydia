import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A focus ring plus keyboard activation, wrapped around any child.
///
/// Extracted from `video_controls/control_button.dart`, which grew the pattern
/// first and is now a consumer of it. The app has one other place that needed
/// it and about a dozen that will: a viewer holding a D-pad remote has no
/// cursor, so the ring is the only thing telling them where they are, and
/// every tappable surface in the app needs one.
///
/// Deliberately not gated on `InputCapabilities.directionalPrimary`. The ring
/// follows `FocusableActionDetector`'s own highlight tracking, which shows it
/// for keyboard and directional traversal and hides it under touch and mouse.
/// That keeps phone and desktop behaviour unchanged without this widget
/// knowing anything about televisions.
class FocusHighlight extends StatefulWidget {
  /// The wrapped content. Painted identically focused or not; only the ring
  /// around it changes.
  final Widget child;

  /// Called on Enter, Space, or a D-pad centre press while focused.
  ///
  /// When null the widget cannot take focus at all. A focused surface that
  /// does nothing is a dead stop in the traversal order, which on a remote
  /// reads as the app having frozen.
  final VoidCallback? onActivate;

  /// Optional externally-owned node, for callers that need to request focus
  /// or observe it. One is created internally when this is null.
  final FocusNode? focusNode;

  /// Whether to take focus on first build.
  final bool autofocus;

  /// Ring geometry. [circular] overrides [borderRadius] for round targets.
  final BorderRadius borderRadius;
  final double ringWidth;
  final Color ringColor;
  final double ringOpacity;
  final bool circular;

  /// Padding between the child's bounds and the ring, for cards whose art
  /// runs to the edge and would otherwise have the ring sitting on top of it.
  final EdgeInsets ringInset;

  /// Fired on every focus transition, for callers that need to scroll the
  /// child into view or lift the state.
  final ValueChanged<bool>? onFocusChange;

  const FocusHighlight({
    super.key,
    required this.child,
    this.onActivate,
    this.focusNode,
    this.autofocus = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.ringWidth = 2,
    this.ringColor = Colors.white,
    this.ringOpacity = 0.60,
    this.ringInset = EdgeInsets.zero,
    this.circular = false,
    this.onFocusChange,
  });

  /// Finder handle for the ring itself, so tests assert on the decoration
  /// rather than on whichever child happens to be inside.
  static const ringKey = ValueKey('focus-highlight-ring');

  @override
  State<FocusHighlight> createState() => _FocusHighlightState();
}

class _FocusHighlightState extends State<FocusHighlight> {
  bool _showRing = false;

  bool get _interactive => widget.onActivate != null;

  void _handleShowFocusHighlight(bool value) {
    if (!mounted || value == _showRing) return;
    setState(() => _showRing = value);
  }

  void _handleFocusChange(bool value) {
    widget.onFocusChange?.call(value);
    // The ring itself is driven solely by `onShowFocusHighlight`, which is
    // gated on `FocusManager.highlightMode`. Do not also drive it from raw
    // focus here: `Focus.onFocusChange` fires whenever this node or any
    // descendant holds focus, including a tap on a descendant `InkWell`, so
    // wiring the ring to it would paint a ring on every tap under touch and
    // mouse, contradicting this widget's whole purpose.
  }

  void _activate() => widget.onActivate?.call();

  @override
  Widget build(BuildContext context) {
    final Widget ringed = Padding(
      padding: widget.ringInset,
      child: DecoratedBox(
        key: FocusHighlight.ringKey,
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: widget.circular ? null : widget.borderRadius,
          shape: widget.circular ? BoxShape.circle : BoxShape.rectangle,
          border: _showRing
              ? Border.all(
                  color: widget.ringColor.withValues(alpha: widget.ringOpacity),
                  width: widget.ringWidth,
                )
              : null,
        ),
        child: widget.child,
      ),
    );

    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: _interactive,
      onShowFocusHighlight: _handleShowFocusHighlight,
      onFocusChange: _handleFocusChange,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      child: ringed,
    );
  }
}
