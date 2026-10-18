import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cast_bar/cast_bar_state.dart';
import 'glass/glass_sheet.dart';
import 'cast_mini_controller.dart';
import 'nav/dock_glass.dart';

/// Opens the cast controls in a bottom sheet, for the native accessory,
/// which only has room for a title and play/pause.
///
/// The sheet hosts the same `CastMiniController` the floating bar uses, so
/// every control (scrubber, skip, subtitles, stop, pull, reconnect) behaves
/// exactly as it does there. There is no other full-screen remote.
Future<void> showCastControlsSheet(BuildContext context) =>
    showGlassSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CastControlsSheet(),
    );

class CastControlsSheet extends ConsumerWidget {
  const CastControlsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Casting ended while the sheet was open: an empty sheet is useless.
    // Remove this sheet's own route rather than popping the top one: a
    // confirm dialog from the controller may be open above it.
    final route = ModalRoute.of(context);
    ref.listen(castBarStateProvider, (previous, next) {
      if (next == null && route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    return const SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DockGlass.sideMargin,
          0,
          DockGlass.sideMargin,
          DockGlass.sideMargin,
        ),
        // Not floating over the screens, so it must not pad them.
        child: CastMiniController(reportsExtent: false),
      ),
    );
  }
}
