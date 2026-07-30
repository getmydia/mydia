import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_providers.dart';
import '../../core/cast/cast_target.dart';

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
    final target = ref.watch(castTargetProvider);
    final active = isCasting || target != null;

    final String tooltip;
    if (isCasting && castDevice != null) {
      tooltip = 'Casting to ${castDevice.name}';
    } else if (target != null) {
      tooltip = 'Will play on ${target.name}';
    } else {
      tooltip = 'Cast to device';
    }

    return IconButton(
      key: const Key('cast-button'),
      icon: Icon(
        active ? Icons.cast_connected : Icons.cast,
        color: active ? Colors.blue : Colors.white,
      ),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
      ),
      tooltip: tooltip,
    );
  }
}
