import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/navigation/sidebar_layout.dart';

/// The sidebar's scrolling middle region, in one of two renderings.
///
/// Normal mode is a plain [ListView] that constructs no drag recognizer at
/// all. That is the whole point: [ReorderableDragStartListener] uses an
/// immediate multi-drag recognizer, so wrapping every row in one meant a touch
/// drag won the gesture arena the moment the finger moved and the scrollable
/// never saw it. The sidebar could not be scrolled on any touch device.
///
/// Edit mode is a [ReorderableListView] whose drag listener wraps only the
/// grip, and which additionally renders hidden rows in place so the user can
/// see where a restored row will land.
///
/// This region must own the leftover vertical space and scroll inside it. It
/// must not size to its content: the flat list renders every destination at
/// once, where the old tree kept Library collapsed, so on a short viewport the
/// column overflowed by ~100px and the render library threw. Anchors stay
/// outside this widget so Downloads and Settings never scroll away. The
/// route back from a hidden row is the edit-mode pencil plus this list's
/// own per-row restore control, not Settings.
class SidebarMiddleList extends StatelessWidget {
  const SidebarMiddleList({
    super.key,
    required this.editing,
    required this.rows,
    required this.buildRow,
    required this.onReorder,
    required this.onRestore,
  });

  /// Whether edit mode is active.
  final bool editing;

  /// Every middle row, hidden ones included. Normal mode filters them out
  /// here rather than at the call site, so the caller passes one list
  /// regardless of mode.
  final List<SidebarEditRow> rows;

  /// Builds the row body. [editingTrailing] is null outside edit mode.
  final Widget Function(SidebarEditRow row, {Widget? editingTrailing}) buildRow;

  /// Raw `ReorderableListView` indices into [rows], passed through with no
  /// arithmetic. `SidebarLayout.orderAfterReorder` performs the
  /// newIndex-past-oldIndex adjustment itself; doing it here too would be a
  /// second adjustment and an off-by-one on downward drags.
  final void Function(int oldIndex, int newIndex) onReorder;

  final void Function(String id) onRestore;

  /// Minimum interactive (tap/click) height for the restore control, in
  /// logical pixels. Kept at the WCAG 2.5.5 / Apple HIG minimum touch target
  /// size even though the glyph itself stays small — restore is tapped
  /// repeatedly while a user cleans up a long hidden list on a phone, so a
  /// cramped hit target is a real usability defect, not polish.
  ///
  /// Height only, deliberately. This control renders as `SidebarRow`'s
  /// `editingTrailing` inside its shared trailing slot (`_menuWidth` in
  /// sidebar_row.dart), which every customisable row's overflow menu also
  /// occupies at 36px wide. Declaring a width here would not even be a
  /// no-op: `IconButton` fills its own slot horizontally only because
  /// Material's default `MaterialTapTargetSize.padded` behaviour pads a
  /// small icon out to its 48dp minimum and then `BoxConstraints.enforce`
  /// clamps that padding down into whatever the ambient slot allows: 36px
  /// here, not 48. Requesting a tight 44px width instead would shrink the
  /// button back down to its unpadded icon size (about 20px) and leave a
  /// gap in the slot, which is worse than the width this finding's
  /// predecessor complained about. Widening the slot itself to reach a
  /// clean 44px target on both axes was rejected too: the slot is shared
  /// with normal mode's row layout, and widening it would shift rows there
  /// too, breaking the "nothing shifts between the two modes" guarantee
  /// `sidebar_row_editing_test.dart` covers.
  ///
  /// The honest result: this control fills its 36px-wide slot exactly (via
  /// the padding mechanism above, not this constant), and is at least this
  /// tall — in practice 48px, since height is the one dimension nothing
  /// upstream constrains, so Material's own padded minimum applies in full.
  static const double _restoreControlTapHeight = 44;

  @override
  Widget build(BuildContext context) {
    if (!editing) {
      final visible = rows.where((row) => !row.hidden).toList();

      return ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final row = visible[index];
          return Padding(
            key: ValueKey(row.destination.id),
            padding: const EdgeInsets.only(bottom: 2),
            child: buildRow(row),
          );
        },
      );
    }

    return ReorderableListView.builder(
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      onReorder: onReorder,
      itemBuilder: (context, index) {
        final row = rows[index];

        // A hidden row gets a restore control instead of a grip, so it cannot
        // be dragged. Visible rows can still be dropped either side of it,
        // which is what keeps its stored slot meaningful.
        final Widget trailing = row.hidden
            ? IconButton(
                onPressed: () => onRestore(row.destination.id),
                tooltip: 'Restore ${row.destination.label}',
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  height: _restoreControlTapHeight,
                ),
                icon: const Icon(
                  Icons.add_circle_outline_rounded,
                  color: AppColors.primary,
                ),
              )
            : ReorderableDragStartListener(
                index: index,
                child: const Icon(
                  Icons.drag_indicator,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
              );

        return Padding(
          key: ValueKey(row.destination.id),
          padding: const EdgeInsets.only(bottom: 2),
          child: buildRow(row, editingTrailing: trailing),
        );
      },
    );
  }
}
