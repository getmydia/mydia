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
class SidebarFocusBoundary {
  /// The node on the sidebar's currently selected row.
  final FocusNode sidebarNode;

  SidebarFocusBoundary({required this.sidebarNode});

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
  /// forgets the attachment guard.
  bool focusSidebar() {
    if (sidebarNode.context == null) return false;

    final current = FocusManager.instance.primaryFocus;
    if (current != null && current != sidebarNode) _origin = current;

    sidebarNode.requestFocus();
    return _landed(sidebarNode);
  }

  /// Returns focus to where it was before it entered the sidebar.
  ///
  /// False when nothing was remembered, or the remembered node has since left
  /// the tree — in which case the key must fall through rather than be
  /// consumed. `FocusNode.context` is the check, not `canRequestFocus`: the
  /// latter is true for a detached node, so gating on it would report a move
  /// from a card that is no longer on screen.
  bool focusContent() {
    final origin = _origin;
    if (origin == null || origin.context == null) return false;

    origin.requestFocus();
    return _landed(origin);
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
