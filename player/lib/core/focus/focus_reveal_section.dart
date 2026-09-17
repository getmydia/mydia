import 'package:flutter/widgets.dart';

import '../player/input_capabilities.dart';

/// Scrolls the whole of its child into view, top-aligned, when focus enters
/// it.
///
/// A directional move reveals only the node that took focus, with
/// `keepVisibleAtStart`, so a section whose focusable controls sit below its
/// content (a hero with its buttons along the bottom) stays cut off when UP
/// lands on a control: the button is on screen and everything above it is
/// not. Wrapping the section makes arriving anywhere inside it show the
/// section from its top.
///
/// It reacts to focus *entering*, not to every move inside. A move between
/// two buttons in the section does not notify this node, since the focus
/// manager only notifies nodes whose focus state changed, and the state also
/// ignores any notification that is not a false-to-true transition.
///
/// The scroll is deferred to after the frame for the same reason
/// `RailFocusScroller` defers its own: the notification arrives while focus
/// changes are being applied, and it has to start after the traversal's
/// immediate reveal so it replaces that scroll instead of being replaced by
/// it.
///
/// Television tier only. Elsewhere this returns [child] untouched, so the
/// focus tree on phones, desktops and the web is unchanged.
class FocusRevealSection extends StatefulWidget {
  final Widget child;

  const FocusRevealSection({super.key, required this.child});

  @override
  State<FocusRevealSection> createState() => _FocusRevealSectionState();
}

class _FocusRevealSectionState extends State<FocusRevealSection> {
  /// Whether the subtree held focus at the last notification.
  ///
  /// `Focus` calls `onFocusChange` on every notification its node receives,
  /// including property changes that leave focus where it was, so the
  /// transition is tracked here rather than assumed.
  bool _hadFocus = false;

  void _handleFocusChange(bool hasFocus) {
    final entered = hasFocus && !_hadFocus;
    _hadFocus = hasFocus;
    if (!entered || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!InputCapabilities.directionalPrimary) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _handleFocusChange,
      child: widget.child,
    );
  }
}
