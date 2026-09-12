import 'package:flutter/widgets.dart';

/// The sidebar/content focus boundary's memory and its two moves.
///
/// Extracted from `AppShell`'s state rather than left inline because the shell
/// cannot be mounted by a widget test — it needs the authenticated provider
/// graph — and the property that matters here is invisible from the outside:
/// that the trip is *reversible*, i.e. returning from the sidebar lands on the
/// card that left it rather than the first card in the rail. A test that wires
/// its own callbacks cannot tell those apart, so the logic lives here where it
/// can be driven directly.
///
/// Both moves report whether focus actually landed. That is not a nicety: the
/// caller is a traversal policy's `onExit`, and returning true tells the
/// framework the key was consumed. Claiming a move that did not happen turns
/// the D-pad's left press into a dead button, which is precisely the defect
/// this boundary exists to fix.
///
/// The same honesty is why returning to the content has a fallback. Activating
/// a sidebar row calls `context.go`, which replaces the routed child, so the
/// node this boundary remembered is disposed in the process. Without a
/// fallback the right press after picking a destination finds nothing to move
/// to, reports false, and does nothing at all — a dead RIGHT on the one press
/// a viewer is most likely to make, since it is how they leave the sidebar.
/// The fallback lands focus on the first focusable in the content region
/// instead, so the key still does what it promises. It reports false when the
/// region is genuinely empty, because then nothing moved and the key must fall
/// through rather than be swallowed.
class SidebarFocusBoundary {
  /// The node on the sidebar's currently selected row.
  final FocusNode sidebarNode;

  /// The content region's scope.
  ///
  /// Required for the fallback: it is the only handle on the region's own
  /// focusables, so without it a boundary whose remembered origin has gone can
  /// only report that it could not move. Optional in the constructor so a test
  /// can drive the remembered round trip on its own — the fallback is then
  /// simply unavailable.
  final FocusScopeNode? contentScope;

  SidebarFocusBoundary({required this.sidebarNode, this.contentScope});

  FocusNode? _origin;

  /// The node focus came from when it last entered the sidebar.
  ///
  /// Exposed for tests; the shell has no reason to read it.
  @visibleForTesting
  FocusNode? get origin => _origin;

  /// Moves focus into the sidebar, remembering where it came from.
  ///
  /// Returns false when there is nothing to move to, so the caller can let the
  /// key fall through instead of swallowing it. Also false if the move did not
  /// take, which keeps the `onExit` contract honest even if a future caller
  /// forgets the liveness guard.
  ///
  /// The guard asks whether the remembered context is still mounted rather
  /// than whether `context` is null: `FocusNode._context` is assigned once in
  /// `attach()` and never cleared, so a node that was attached and has since
  /// been unmounted still reports a non-null context. `context?.mounted` is
  /// what distinguishes "in the tree now" from "departed"; a null context
  /// means never attached, an unmounted one means departed. Skipping
  /// `requestFocus` on a departed node matters beyond the return value —
  /// `requestFocus` on a parentless node sets `_requestFocusWhenReparented`,
  /// so a node reused after re-attachment would steal focus uninvited. The
  /// returned value does not depend on the guard being complete: [_landed]
  /// re-reads `hasFocus` after flushing, so even a case the guard
  /// misclassifies still answers false.
  bool focusSidebar() {
    if (!(sidebarNode.context?.mounted ?? false)) return false;

    final current = FocusManager.instance.primaryFocus;
    if (current != null && current != sidebarNode) _origin = current;

    sidebarNode.requestFocus();
    return _landed(sidebarNode);
  }

  /// Returns focus to where it was before it entered the sidebar.
  ///
  /// False when there is nothing to move to at all — the key must fall through
  /// rather than be consumed. When the remembered node has left the tree
  /// (which is what a `context.go` from the sidebar does to it) the first
  /// focusable in [contentScope] is used instead, so the press still lands on
  /// something real; only a region that holds nothing focusable reports false.
  ///
  /// The origin check is `context?.mounted`, not `canRequestFocus`: the latter
  /// is true for a detached node, so gating on it would report a move from a
  /// card that is no longer on screen. It is also not `context == null`,
  /// because `FocusNode._context` is assigned once in `attach()` and never
  /// cleared, so a departed node still reports a non-null context.
  ///
  /// The guard is a cheap side-effect filter, not the source of the answer:
  /// [_landed] re-reads `hasFocus` after flushing, so a departed node that the
  /// guard cannot classify still reports false rather than consuming the key.
  bool focusContent() {
    final origin = _origin;
    if (origin != null && (origin.context?.mounted ?? false)) {
      origin.requestFocus();
      return _landed(origin);
    }

    final fallback = _firstFocusableInContent();
    if (fallback == null) return false;
    fallback.requestFocus();
    return _landed(fallback);
  }

  /// The first focusable inside [contentScope], or null if the region holds
  /// none.
  ///
  /// `FocusScopeNode.traversalDescendants` is the region scope's own
  /// enumeration of the nodes a traversal policy would consider, so this finds
  /// a real destination without reaching into the region's widgets, and in the
  /// same order the region's own move would have considered them.
  ///
  /// The mounted check is not redundant with `canRequestFocus`, which
  /// `traversalDescendants` already filters on: a detached node reports
  /// `canRequestFocus` true, and requesting focus on one arms
  /// `_requestFocusWhenReparented`, so a node that is merely waiting to be
  /// re-attached would steal focus when it came back. That is the same trap
  /// [focusSidebar] guards against, and it applies here for the same reason —
  /// a route change is exactly when nodes are parked and re-attached.
  FocusNode? _firstFocusableInContent() {
    final scope = contentScope;
    if (scope == null) return null;
    for (final node in scope.traversalDescendants) {
      if (!(node.context?.mounted ?? false)) continue;
      return node;
    }
    return null;
  }

  /// Whether [node] holds focus now.
  ///
  /// `requestFocus` only *marks* the node: [FocusManager] applies the change in
  /// a microtask, so reading `hasFocus` straight afterwards still reports the
  /// previous value. Every genuine move would therefore be reported as not
  /// having happened — the false negative this class exists to avoid, and one
  /// that would leave the sidebar unreachable with nothing failing. Flushing is
  /// the documented way to resolve pending changes before acting on them (the
  /// framework's own `MenuAnchor` does it to restore focus before running a
  /// menu callback) and is legal outside the build phase, which is where a key
  /// handler runs.
  static bool _landed(FocusNode node) {
    FocusManager.instance.applyFocusChangesIfNeeded();
    return node.hasFocus;
  }
}
