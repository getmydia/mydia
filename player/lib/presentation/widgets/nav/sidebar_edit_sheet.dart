/// The sidebar's edit mode, in a sheet on touch platforms and a dialog on
/// desktop, for the native sidebars, which cannot arrange the viewer's whole
/// layout themselves.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/palette.dart';
import '../glass/glass_sheet.dart';
import 'sidebar_content.dart';

/// Opens on the root navigator, so the iPad native sidebar hides while it is
/// up (`AppShell.nativeBarVisible`), and ends edit mode however it closes.
/// The macOS sidebar is its own pane and stays, as it does for every popup.
Future<void> showSidebarEditSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String location,
}) async {
  if (!ref.read(sidebarEditModeProvider)) {
    ref.read(sidebarEditModeProvider.notifier).toggle();
  }
  // Read before the await: the caller can unmount while the sheet is up (the
  // iPad going compact swaps the host out), and the provider outlives it.
  final editMode = ref.read(sidebarEditModeProvider.notifier);
  final desktop = switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows =>
      true,
    _ => false,
  };
  if (desktop) {
    // A bottom sheet reads as a phone affordance in a desktop window.
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => Dialog(
        backgroundColor: context.palette.surfaceVariant,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640),
          child: _EditSheet(location: location, inDialog: true),
        ),
      ),
    );
  } else {
    await showGlassSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.palette.surfaceVariant,
      builder: (_) => _EditSheet(location: location),
    );
  }
  editMode.exit();
}

class _EditSheet extends ConsumerWidget {
  const _EditSheet({required this.location, this.inDialog = false});

  final String location;

  /// In a dialog the height comes from the dialog's own constraints; the
  /// sheet takes 80% of the screen.
  final bool inDialog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Done in the edit bar ends edit mode; the sheet follows it. The sheet
    // stays mounted through its exit animation after a barrier or drag
    // dismissal, and `showSidebarEditSheet` then calls `exit()`: popping
    // there would remove the route underneath, so pop only while this
    // sheet's own route is still current.
    ref.listen(sidebarEditModeProvider, (_, editing) {
      if (!editing && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).pop();
      }
    });
    final content = SafeArea(
      child: SidebarContent(
        location: location,
        // Edit mode has no navigation: its rows arrange, they do not open.
        onNavigate: (_) {},
        isOffline: false,
      ),
    );
    if (!inDialog) {
      return SizedBox(
        key: const Key('sidebar-edit-sheet'),
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: content,
      );
    }
    // SidebarContent lays out with Expanded, so it needs a tight height: fill
    // whatever the dialog allows.
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        key: const Key('sidebar-edit-sheet'),
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        child: content,
      ),
    );
  }
}
