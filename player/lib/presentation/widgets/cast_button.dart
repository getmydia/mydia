import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_providers.dart';

/// Cast button for the player's top bar.
///
/// Renders nothing when the current build has no cast capability at all
/// (e.g. web), so unsupported builds show no dead affordance.
class CastButton extends ConsumerWidget {
  final VoidCallback onPressed;

  const CastButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(castCapabilitiesProvider).any) {
      return const SizedBox.shrink();
    }

    final isCasting = ref.watch(isCastingProvider);
    final castDevice = ref.watch(currentCastDeviceProvider);

    return IconButton(
      key: const Key('cast-button'),
      icon: Icon(
        isCasting ? Icons.cast_connected : Icons.cast,
        color: isCasting ? Colors.blue : Colors.white,
      ),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
      ),
      tooltip: isCasting && castDevice != null
          ? 'Casting to ${castDevice.name}'
          : 'Cast to device',
    );
  }
}
