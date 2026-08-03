import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_providers.dart';

/// The cast affordance, shown in app bars and as the shell overlay.
///
/// Renders nothing when the current build has no cast capability at all
/// (e.g. web), so unsupported builds show no dead affordance.
///
/// Every visual comes from [castConnectionProvider]. `Icons.cast_connected` is
/// the platform's "this app owns that receiver" glyph, so it appears only when
/// a connection is genuinely live — a device that has merely been chosen gets
/// the hollow `Icons.cast` in the same blue.
class CastButton extends ConsumerWidget {
  final VoidCallback onPressed;

  const CastButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(castCapabilitiesProvider).any) {
      return const SizedBox.shrink();
    }

    final connection = ref.watch(castConnectionProvider);
    final device = ref.watch(castDisplayDeviceProvider);
    final name = device?.name ?? 'device';

    final (IconData glyph, Color color, String tooltip) = switch (connection) {
      CastConnection.none => (Icons.cast, Colors.white, 'Cast to device'),
      CastConnection.connecting => (
          Icons.cast,
          Colors.blue,
          'Connecting to $name…',
        ),
      CastConnection.connectedIdle => (
          Icons.cast_connected,
          Colors.blue,
          'Connected to $name',
        ),
      CastConnection.casting => (
          Icons.cast_connected,
          Colors.blue,
          'Casting to $name',
        ),
      CastConnection.chosenOffline => (
          Icons.cast,
          Colors.blue,
          '$name — not connected',
        ),
    };

    return IconButton(
      key: const Key('cast-button'),
      icon: connection == CastConnection.connecting
          ? Stack(
              alignment: Alignment.center,
              children: [
                Icon(glyph, color: color, size: 16),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.blue,
                  ),
                ),
              ],
            )
          : Icon(glyph, color: color),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
      ),
      tooltip: tooltip,
    );
  }
}
