import 'package:flutter/widgets.dart';

import '../player/input_capabilities.dart';

/// Where a [FocusMemoryRegion] sends focus when it has nothing to remember.
enum FocusMemoryEntry {
  /// The registered item with the lowest index.
  first,

  /// The registered item with the lowest index whose focus target is at least
  /// partly on screen, falling back to [first] when none is.
  ///
  /// For one-column vertical lists, where the lowest built index can sit a
  /// whole cache extent above the viewport and landing there would scroll the
  /// list back to an item the viewer had already scrolled past.
  firstVisible,
}

/// Whether [node] sits inside a popup route rather than on the page itself.
///
/// `ModalRoute.of` walks up from [node]'s `context` to the nearest route.
/// `PopupRoute` is the common supertype of `ModalBottomSheetRoute`, the route
/// `showMenu` pushes, and dialog routes, while a go_router shell destination
/// is a `PageRoute`. Checking against `PopupRoute` therefore tells "a modal is
/// open above the page" from "this is the page", without naming any one sheet
/// or menu type. Answers false, rather than throwing, when the node has no
/// context or its context is no longer mounted, since there is then nothing to
/// ask.
///
/// Shared by [RegionTraversalPolicy], which must never hand a press from
/// inside a popup to the sidebar behind it, and [FocusMemory.requestFocus],
/// which must never redirect a move inside a popup to a remembered item on
/// the page behind it. Both rules are the same promise: focus never moves
/// somewhere the viewer cannot see it went.
bool isInsidePopupRoute(FocusNode node) {
  final context = node.context;
  if (context == null || !context.mounted) return false;
  return ModalRoute.of(context) is PopupRoute;
}

/// The focus rule for the television tier: a row remembers its place.
///
/// Flutter's directional traversal answers every D-pad press with "the
/// nearest focusable node in that direction". That has no memory, so DOWN
/// from a card lands on whichever card in the next row happens to sit closest
/// at that row's current scroll offset, often a card built off-screen by the
/// rail's cache extent, and UP does not return to the card it came from.
///
/// [requestFocus] is installed as a traversal policy's
/// `requestFocusCallback`. Every move `DirectionalFocusTraversalPolicyMixin`
/// makes goes through that callback, including the up/down history it
/// replays to avoid hysteresis, so this one function sees every directional
/// landing without replacing the geometric search or the policy that runs
/// it. The search still decides *which region* a press enters; this decides
/// *where in that region* it lands.
abstract final class FocusMemory {
  /// A [TraversalRequestFocusCallback] that redirects a move entering a
  /// [FocusMemoryRegion] to the item that region remembers.
  ///
  /// The move is redirected only when [node] belongs to a region and that
  /// region is not the one holding focus now. A move inside a region (LEFT
  /// and RIGHT along a rail, UP and DOWN inside a vertical list) is left as
  /// the geometric search chose it, because there "the next item over" is
  /// exactly what the viewer asked for. A node inside a popup route is never
  /// redirected (see [isInsidePopupRoute]).
  ///
  /// Whatever the target, focusing and scrolling go through
  /// [FocusTraversalPolicy.defaultTraversalRequestFocusCallback] with the
  /// alignment arguments unchanged, so a redirected landing scrolls into view
  /// exactly as an unredirected one does.
  ///
  /// Off the television tier this only delegates.
  static void requestFocus(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) {
    FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
      _redirect(node),
      alignmentPolicy: alignmentPolicy,
      alignment: alignment,
      duration: duration,
      curve: curve,
    );
  }

  static FocusNode _redirect(FocusNode node) {
    if (!InputCapabilities.directionalPrimary) return node;
    if (isInsidePopupRoute(node)) return node;
    final region = _regionOf(node);
    if (region == null) return node;
    if (identical(region, _regionOf(FocusManager.instance.primaryFocus))) {
      return node;
    }
    return region.resolveTarget() ?? node;
  }

  static _FocusMemoryRegionState? _regionOf(FocusNode? node) {
    final context = node?.context;
    if (context == null || !context.mounted) return null;
    return context.findAncestorStateOfType<_FocusMemoryRegionState>();
  }
}

/// A row, grid, list or button bar that remembers which of its items last
/// had focus, and sends focus entering it from outside back to that item.
///
/// Items opt in by wrapping themselves in a [FocusMemoryItem] with a stable
/// id. The region itself adds nothing to the tree: it is found by
/// [FocusMemory.requestFocus] walking up from the node a move is about to
/// focus, which is why it needs no `Focus` or `FocusScope` of its own, and
/// why it cannot change how traversal inside it behaves.
///
/// What it lands on when entered, in order:
///
/// 1. The remembered item, by id, wherever it has moved to. A row remembers
///    the item, not the slot, so a title Continue Watching moved to the front
///    is still the one focus returns to.
/// 2. If that item is not registered (removed from the list, or scrolled out
///    of the build cache so it has no element), the registered item whose
///    index is nearest the remembered index.
/// 3. With nothing remembered, the item [entry] picks.
///
/// With no items registered at all (an emptied row), it lands nowhere of its
/// own and the move keeps the geometric search's choice.
///
/// Off the television tier it returns [child] untouched and remembers
/// nothing.
class FocusMemoryRegion extends StatefulWidget {
  const FocusMemoryRegion({
    super.key,
    required this.child,
    this.entry = FocusMemoryEntry.first,
    this.debugLabel,
  });

  final Widget child;

  /// Where focus lands when the region has nothing remembered.
  final FocusMemoryEntry entry;

  /// Names the region in diagnostics only.
  final String? debugLabel;

  @override
  State<FocusMemoryRegion> createState() => _FocusMemoryRegionState();
}

class _FocusMemoryRegionState extends State<FocusMemoryRegion> {
  Object? _rememberedId;
  int? _rememberedIndex;

  /// The items currently built under this region, by id.
  ///
  /// Only built items are here: a lazy list drops an item's element once it
  /// leaves the cache extent, and its state unregisters on dispose. That is
  /// what lets [resolveTarget] tell "the remembered item exists but is not
  /// built" from "it is built, focus it", and fall back by index for the
  /// former instead of reaching for a node that does not exist.
  final Map<Object, _FocusMemoryItemState> _items = {};

  void _remember(Object id, int index) {
    _rememberedId = id;
    _rememberedIndex = index;
  }

  void _register(_FocusMemoryItemState item) {
    _items[item.widget.id] = item;
    // A remembered item that moved keeps the index fallback pointed at where
    // it went, so if it is later removed the nearest survivor is chosen
    // around its last known position rather than where it was first focused.
    if (item.widget.id == _rememberedId) _rememberedIndex = item.widget.index;
  }

  /// Removes [item] under [id] only if it is still the state registered
  /// there.
  ///
  /// A lazy list rebuilt with its items reordered reuses elements by slot,
  /// so one item state can take over an id another state held a moment ago
  /// within the same build. Removing unconditionally would let the old holder
  /// delete the new holder's entry, depending on the order the slots update.
  void _unregister(Object id, _FocusMemoryItemState item) {
    if (identical(_items[id], item)) _items.remove(id);
  }

  /// The node focus should land on when entering this region, or null when
  /// no registered item has anything focusable.
  FocusNode? resolveTarget() {
    final candidates = <({int index, FocusNode target})>[
      for (final item in _items.values)
        if (item._target case final target?)
          (index: item.widget.index, target: target),
    ]..sort((a, b) => a.index.compareTo(b.index));
    if (candidates.isEmpty) return null;

    final remembered = _items[_rememberedId]?._target;
    if (remembered != null) return remembered;

    final rememberedIndex = _rememberedIndex;
    if (rememberedIndex != null) {
      // Sorted by index, and only a strictly nearer candidate replaces the
      // current best, so a tie goes to the lower index.
      var best = candidates.first;
      for (final c in candidates) {
        if ((c.index - rememberedIndex).abs() <
            (best.index - rememberedIndex).abs()) {
          best = c;
        }
      }
      return best.target;
    }

    switch (widget.entry) {
      case FocusMemoryEntry.first:
        return candidates.first.target;
      case FocusMemoryEntry.firstVisible:
        for (final c in candidates) {
          if (_isOnScreen(c.target)) return c.target;
        }
        return candidates.first.target;
    }
  }

  /// Whether [node]'s rect overlaps what the viewer can see.
  ///
  /// The view alone is not enough: a list that does not fill the screen
  /// keeps cached items laid out beyond its own viewport, which can still be
  /// inside the view's rectangle while clipped from sight. So the visible
  /// area is the view intersected with every enclosing scrollable's viewport.
  /// `Rect.overlaps` is strict, so an item whose edge only touches the
  /// boundary counts as off screen.
  static bool _isOnScreen(FocusNode node) {
    final context = node.context;
    if (context == null || !context.mounted) return false;
    final view = View.maybeOf(context);
    var bounds = view == null
        ? Rect.largest
        : Offset.zero & (view.physicalSize / view.devicePixelRatio);
    var scrollable = Scrollable.maybeOf(context);
    while (scrollable != null) {
      final box = scrollable.context.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        bounds = bounds.intersect(box.localToGlobal(Offset.zero) & box.size);
      }
      scrollable = Scrollable.maybeOf(scrollable.context);
    }
    return node.rect.overlaps(bounds);
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  String toStringShort() =>
      '${super.toStringShort()}(${widget.debugLabel ?? ''})';
}

/// One item of a [FocusMemoryRegion]: a card in a rail, a cell in a grid, a
/// button in a bar.
///
/// [id] must be stable across rebuilds and reorders (the media item's id,
/// not its position), because it is what the region remembers. [index] is the
/// item's current position, used to fall back to the nearest survivor when
/// the remembered item is gone and to order the region's entry choice.
///
/// Wraps [child] in a non-focusable `Focus` that only listens: when anything
/// inside the item gains focus, the region remembers this item. The node
/// focus lands on when the region picks this item is the outermost
/// traversable node inside it, so an item whose card has its own `Focus`
/// needs nothing else, and a button nested in that card is not picked over
/// the card.
///
/// Off the television tier it returns [child] untouched and registers
/// nothing.
class FocusMemoryItem extends StatefulWidget {
  const FocusMemoryItem({
    super.key,
    required this.id,
    required this.index,
    required this.child,
  });

  final Object id;
  final int index;
  final Widget child;

  @override
  State<FocusMemoryItem> createState() => _FocusMemoryItemState();
}

class _FocusMemoryItemState extends State<FocusMemoryItem> {
  final FocusNode _node = FocusNode(
    debugLabel: 'FocusMemoryItem',
    canRequestFocus: false,
    skipTraversal: true,
  );

  _FocusMemoryRegionState? _region;

  /// The outermost traversable node inside this item.
  ///
  /// `traversalDescendants` lists a node's children before the node itself,
  /// so for a card holding a button of its own (an episode card's watched
  /// menu) the button comes first. Landing there would put focus on a corner
  /// control instead of the card, so a later node that encloses the current
  /// pick replaces it.
  FocusNode? get _target {
    FocusNode? target;
    for (final node in _node.traversalDescendants) {
      final context = node.context;
      if (context == null || !context.mounted) continue;
      if (target == null || target.ancestors.contains(node)) target = node;
    }
    return target;
  }

  @override
  void initState() {
    super.initState();
    if (!InputCapabilities.directionalPrimary) return;
    _region = context.findAncestorStateOfType<_FocusMemoryRegionState>();
    _region?._register(this);
  }

  @override
  void didUpdateWidget(FocusMemoryItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!InputCapabilities.directionalPrimary) return;
    _region?._unregister(oldWidget.id, this);
    _region = context.findAncestorStateOfType<_FocusMemoryRegionState>();
    _region?._register(this);
  }

  @override
  void dispose() {
    _region?._unregister(widget.id, this);
    _node.dispose();
    super.dispose();
  }

  void _handleFocusChange(bool hasFocus) {
    if (hasFocus) _region?._remember(widget.id, widget.index);
  }

  @override
  Widget build(BuildContext context) {
    if (!InputCapabilities.directionalPrimary) return widget.child;
    return Focus(
      focusNode: _node,
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _handleFocusChange,
      child: widget.child,
    );
  }
}
