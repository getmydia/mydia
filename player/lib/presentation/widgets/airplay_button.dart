import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/airplay/airplay_providers.dart';
import '../../core/player/platform_features.dart';
import '../../l10n/l10n.dart';

/// Button widget to trigger AirPlay route picker on iOS.
///
/// This button is only shown on iOS devices and uses the native
/// AirPlay route picker to select output devices.
class AirPlayButton extends ConsumerWidget {
  const AirPlayButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only show on iOS
    if (!PlatformFeatures.isIOS) {
      return const SizedBox.shrink();
    }

    final isAirPlaying = ref.watch(isAirPlayingProvider);
    final airPlayDevice = ref.watch(currentAirPlayDeviceProvider);
    final airPlayService = ref.read(airPlayServiceProvider);

    return IconButton(
      icon: Icon(
        isAirPlaying ? Icons.airplay : Icons.airplay,
        color: isAirPlaying ? Colors.blue : Colors.white,
      ),
      onPressed: () async {
        // Show native AirPlay route picker
        await airPlayService.showRoutePicker();
      },
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
      ),
      tooltip: isAirPlaying && airPlayDevice != null
          ? context.l10n.airplayTooltipDevice(airPlayDevice.name)
          : 'AirPlay', // l10n-ignore: product name
    );
  }
}
