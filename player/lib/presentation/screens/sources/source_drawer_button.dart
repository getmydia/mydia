/// The drawer button for third-party source screens on a phone.
library;

import 'package:flutter/material.dart';

import '../../widgets/app_shell.dart';

/// Opens the shell's navigation drawer.
///
/// The source screens build their own `Scaffold`, which has no drawer, so
/// their `AppBar` never shows a menu icon by itself: the drawer belongs to
/// the shell's `Scaffold`, and the sidebar opens these screens with `go`,
/// leaving nothing to pop. Swiping from the edge still reached the drawer,
/// which is how the missing icon went unnoticed.
class SourceDrawerButton extends StatelessWidget {
  const SourceDrawerButton({super.key});

  /// The button, or null where it has no job: the wide layout, which has no
  /// drawer, and a route that can pop, which shows a back button instead.
  static Widget? maybe(BuildContext context) {
    if (AppShell.scaffoldKey.currentState == null) return null;
    if (ModalRoute.of(context)?.canPop ?? false) return null;
    return const SourceDrawerButton();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('source-open-drawer'),
      tooltip: 'Menu',
      icon: const Icon(Icons.menu_rounded),
      onPressed: () => AppShell.scaffoldKey.currentState?.openDrawer(),
    );
  }
}
