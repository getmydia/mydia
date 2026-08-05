import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_providers.dart';
import 'cast_visuals.dart';

/// The cast affordance, shown in app bars and as the shell overlay.
///
/// Renders nothing when the current build has no cast capability at all
/// (e.g. web), so unsupported builds show no dead affordance.
///
/// Every visual comes from [castVisualsFor]. Glyphs are the bare Material
/// family, which is what the app bars this sits in use; the playback chrome's
/// own affordance is `CastChromeIcon`, which draws the `_rounded` family
/// instead.
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
    final visuals = castVisualsFor(connection, device?.name ?? 'device');
    final glyph = visuals.connected ? Icons.cast_connected : Icons.cast;

    return IconButton(
      key: const Key('cast-button'),
      icon: connection == CastConnection.connecting
          ? Stack(
              alignment: Alignment.center,
              children: [
                Icon(glyph, color: visuals.color, size: 16),
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
          : Icon(glyph, color: visuals.color),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
      ),
      tooltip: visuals.tooltip,
    );
  }
}
