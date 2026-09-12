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
/// [inDirection] here leaves `next`/`previous` — Tab — behaving exactly as it
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
class RegionTraversalPolicy extends ReadingOrderTraversalPolicy {
  /// Consulted only when the region has nothing in [TraversalDirection].
  final RegionExitCallback? onExit;

  RegionTraversalPolicy({
    this.onExit,
    super.requestFocusCallback,
  });

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    // `@mustCallSuper` on the mixin, and it is the mixin that performs the
    // in-region move. When it reports true the move already happened inside
    // the region, which is the case that must not consult `onExit`.
    if (super.inDirection(currentNode, direction)) return true;
    return onExit?.call(direction) ?? false;
  }
}
