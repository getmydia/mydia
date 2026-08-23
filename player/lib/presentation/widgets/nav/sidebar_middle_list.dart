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
/// outside this widget so Downloads and Settings never scroll away, Settings
/// being the only route back from a hidden row.
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

  /// Minimum interactive (tap/click) region for the restore control, in
  /// logical pixels. Kept at Material's 48dp-adjacent minimum touch target
  /// guidance even though the glyph itself stays small — restore is tapped
  /// repeatedly while a user cleans up a long hidden list on a phone, so a
  /// cramped hit target is a real usability defect, not polish.
  static const double _restoreControlTapSize = 44;

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
                  width: _restoreControlTapSize,
                  height: _restoreControlTapSize,
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
