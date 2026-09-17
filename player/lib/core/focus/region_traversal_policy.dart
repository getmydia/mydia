import 'package:flutter/widgets.dart';

/// Called when a region has no candidate in [direction].
///
/// Return true only if focus was actually moved. Returning true for a
/// direction nothing handled reports the key as consumed, which on a remote
/// reads as a dead button.
typedef RegionExitCallback = bool Function(TraversalDirection direction);

/// A geometric traversal policy that hands off at a region edge.
///
/// Extends [ReadingOrderTraversalPolicy] because that is the policy the app
/// already runs: `WidgetsApp` installs one at the root, and overriding only
/// [inDirection] here leaves `next`/`previous` (Tab) behaving exactly as it
/// does today. Both this and [WidgetOrderTraversalPolicy] mix in
/// [DirectionalFocusTraversalPolicyMixin], so arrow-key movement is identical
/// whichever is extended; the choice only affects Tab order, and silently
/// reordering that across the desktop tier would be a behaviour change this
/// change is not allowed to make.
///
/// `onExit` exists because that geometric search cannot be confined by a
/// [FocusTraversalGroup]: it iterates `nearestScope.traversalDescendants`,
/// which spans every focusable node in the scope regardless of grouping, so an
/// arrow that finds nothing to the left inside a region will silently walk into
/// whatever is to the left in the *scope*. Pairing each region with its own
/// [FocusScope] makes `nearestScope` the region, so the search runs out of
/// candidates exactly at the boundary and this callback gets its chance.
///
/// Left and right moves are also confined to the focused node's row. When
/// nothing in the row lies in that direction, Flutter's search falls back to
/// the nearest node in *any* row, and on a television that is usually a card
/// a scrolled rail keeps built off-screen. LEFT from the first card of a rail
/// then jumps rows instead of reaching the sidebar, depending on how the other
/// rails happen to be scrolled. So a horizontal move with no candidate in the
/// row skips the search and goes straight to `onExit`.
class RegionTraversalPolicy extends ReadingOrderTraversalPolicy {
  /// Consulted when the region has nothing in [TraversalDirection], and for
  /// left and right when the focused node's row has nothing that way.
  final RegionExitCallback? onExit;

  RegionTraversalPolicy({
    this.onExit,
    super.requestFocusCallback,
  });

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (_rowEndsIn(currentNode, direction)) {
      return onExit?.call(direction) ?? false;
    }
    // `@mustCallSuper` on the mixin, and it is the mixin that performs the
    // in-region move. When it reports true the move already happened inside
    // the region, which is the case that must not consult `onExit`. It is
    // skipped above only when focus is about to leave the region anyway.
    if (super.inDirection(currentNode, direction)) return true;
    return onExit?.call(direction) ?? false;
  }

  /// Whether a left or right move from the scope's focused node has no
  /// candidate in that node's row.
  ///
  /// Mirrors the tests the mixin applies before its out-of-row fallback, so
  /// the two agree on what a row is: a candidate's centre must lie past the
  /// focused edge, and its rect must intersect the focused node's horizontal
  /// band. Uses the scope's focused child, as the mixin does, and answers
  /// false when there is none so the mixin handles that case as before.
  static bool _rowEndsIn(FocusNode currentNode, TraversalDirection direction) {
    if (direction != TraversalDirection.left &&
        direction != TraversalDirection.right) {
      return false;
    }
    final scope = currentNode.nearestScope;
    final focused = scope?.focusedChild;
    if (scope == null || focused == null) return false;

    final target = focused.rect;
    final band = Rect.fromLTRB(
      double.negativeInfinity,
      target.top,
      double.infinity,
      target.bottom,
    );
    for (final node in scope.traversalDescendants) {
      final rect = node.rect;
      if (rect == target) continue;
      final beyond = direction == TraversalDirection.left
          ? rect.center.dx <= target.left
          : rect.center.dx >= target.right;
      if (beyond && !rect.intersect(band).isEmpty) return false;
    }
    return true;
  }
}
