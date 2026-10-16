/// The sidebar's edit mode in a sheet, for the native iPad sidebar, which
/// cannot arrange the viewer's whole layout itself.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/colors.dart';
import 'sidebar_content.dart';

/// Opens on the root navigator, so the native sidebar hides while it is up
/// (`AppShell.nativeBarVisible`), and ends edit mode however it closes.
Future<void> showSidebarEditSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String location,
}) async {
  if (!ref.read(sidebarEditModeProvider)) {
    ref.read(sidebarEditModeProvider.notifier).toggle();
  }
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surfaceVariant,
    builder: (_) => _EditSheet(location: location),
  );
  ref.read(sidebarEditModeProvider.notifier).exit();
}

class _EditSheet extends ConsumerWidget {
  const _EditSheet({required this.location});

  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Done in the edit bar ends edit mode; the sheet follows it. Once the
    // sheet is dismissed it is unmounted, so this never pops a second time.
    ref.listen(sidebarEditModeProvider, (_, editing) {
      if (!editing) Navigator.of(context).maybePop();
    });
    return SizedBox(
      key: const Key('sidebar-edit-sheet'),
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: SafeArea(
        child: SidebarContent(
          location: location,
          // Edit mode has no navigation: its rows arrange, they do not open.
          onNavigate: (_) {},
          isOffline: false,
        ),
      ),
    );
  }
}
