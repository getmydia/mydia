import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'airplay_service.dart';
import '../../domain/models/airplay_device.dart';

/// Provider for the AirPlayService singleton.
final airPlayServiceProvider = Provider<AirPlayService>((ref) {
  final service = AirPlayService();

  // Start discovery when service is created
  service.startDiscovery();

  // Clean up when provider is disposed
  ref.onDispose(() {
    service.stopDiscovery();
    service.dispose();
  });

  return service;
});

/// Provider for the stream of available AirPlay devices.
final availableAirPlayDevicesProvider =
    StreamProvider<List<AirPlayDevice>>((ref) {
  final service = ref.watch(airPlayServiceProvider);
  return service.devicesStream;
});

/// Provider for the current AirPlay session.
final airPlaySessionProvider = StreamProvider<AirPlaySession?>((ref) {
  final service = ref.watch(airPlayServiceProvider);
  return service.sessionStream;
});

/// Provider that returns true if actively using AirPlay.
final isAirPlayingProvider = Provider<bool>((ref) {
  final sessionAsync = ref.watch(airPlaySessionProvider);
  return sessionAsync.maybeWhen(
    data: (session) => session != null,
    orElse: () => false,
  );
});

/// Provider that returns the current AirPlay device, if any.
final currentAirPlayDeviceProvider = Provider<AirPlayDevice?>((ref) {
  final sessionAsync = ref.watch(airPlaySessionProvider);
  return sessionAsync.maybeWhen(
    data: (session) => session?.device,
    orElse: () => null,
  );
});

/// Provider for AirPlay media info.
final airPlayMediaInfoProvider = Provider<AirPlayMediaInfo?>((ref) {
  final sessionAsync = ref.watch(airPlaySessionProvider);
  return sessionAsync.maybeWhen(
    data: (session) => session?.mediaInfo,
    orElse: () => null,
  );
});

/// Provider for AirPlay playback state.
final airPlayPlaybackStateProvider = Provider<AirPlayPlaybackState>((ref) {
  final sessionAsync = ref.watch(airPlaySessionProvider);
  return sessionAsync.maybeWhen(
    data: (session) => session?.playbackState ?? AirPlayPlaybackState.idle,
    orElse: () => AirPlayPlaybackState.idle,
  );
});

/// Provider to check if AirPlay is available on this device.
final airPlayAvailableProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(airPlayServiceProvider);
  return service.isAvailable();
});
