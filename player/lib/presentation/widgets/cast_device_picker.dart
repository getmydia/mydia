import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_backend.dart';
import '../../core/cast/cast_capabilities.dart';
import '../../core/cast/cast_providers.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/cast_device.dart';

/// Shows a dialog to pick a cast receiver.
///
/// Returns the selected device, or null if cancelled.
Future<CastDevice?> showCastDevicePicker(BuildContext context) {
  return showDialog<CastDevice>(
    context: context,
    builder: (context) => const CastDevicePickerDialog(),
  );
}

class CastDevicePickerDialog extends ConsumerWidget {
  /// Test seam: lets widget tests drive every async state directly.
  final AsyncValue<List<CastDevice>>? debugDevicesOverride;

  const CastDevicePickerDialog({super.key, this.debugDevicesOverride});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CastDevice>> devicesAsync =
        debugDevicesOverride ?? ref.watch(castDiscoveryProvider);
    final capabilities = ref.watch(castCapabilitiesProvider);
    final currentDevice = ref.watch(currentCastDeviceProvider);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.cast, size: 24),
          SizedBox(width: 12),
          Text('Cast to Device'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: devicesAsync.when(
          data: (devices) => _DeviceList(
            devices: devices,
            capabilities: capabilities,
            currentDeviceId: currentDevice?.id,
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _DiscoveryError(error: error),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _DeviceList extends StatelessWidget {
  final List<CastDevice> devices;
  final CastCapabilities capabilities;
  final String? currentDeviceId;

  const _DeviceList({
    required this.devices,
    required this.capabilities,
    required this.currentDeviceId,
  });

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Column(
        key: Key('cast-picker-searching'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search, size: 48, color: AppColors.textSecondary),
          SizedBox(height: 16),
          Text(
            'Searching for devices...',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          SizedBox(height: 16),
          CircularProgressIndicator(),
        ],
      );
    }

    final chromecast = devices
        .where((d) => d.protocol == CastProtocolKind.chromecast)
        .toList();
    final dlna =
        devices.where((d) => d.protocol == CastProtocolKind.dlna).toList();

    return ListView(
      shrinkWrap: true,
      children: [
        if (capabilities.chromecast && chromecast.isNotEmpty)
          _ProtocolGroup(
            key: const Key('cast-group-chromecast'),
            label: 'Chromecast',
            devices: chromecast,
            currentDeviceId: currentDeviceId,
          ),
        if (capabilities.dlna && dlna.isNotEmpty)
          _ProtocolGroup(
            key: const Key('cast-group-dlna'),
            label: 'DLNA / UPnP',
            devices: dlna,
            currentDeviceId: currentDeviceId,
          ),
      ],
    );
  }
}

class _ProtocolGroup extends StatelessWidget {
  final String label;
  final List<CastDevice> devices;
  final String? currentDeviceId;

  const _ProtocolGroup({
    super.key,
    required this.label,
    required this.devices,
    required this.currentDeviceId,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
        ),
        ...devices.map((device) {
          final isConnected = currentDeviceId == device.id;
          return ListTile(
            key: Key('cast-device-${device.id}'),
            leading: Icon(
              isConnected ? Icons.cast_connected : Icons.cast,
              color: isConnected ? AppColors.primary : AppColors.textSecondary,
            ),
            title: Text(device.name),
            subtitle: device.model != null ? Text(device.model!) : null,
            trailing: isConnected
                ? const Icon(Icons.check, color: AppColors.primary)
                : null,
            onTap: () => Navigator.of(context).pop(device),
          );
        }),
      ],
    );
  }
}

class _DiscoveryError extends StatelessWidget {
  final Object error;

  const _DiscoveryError({required this.error});

  @override
  Widget build(BuildContext context) {
    final denied = error is CastBackendException &&
        (error as CastBackendException).kind == CastFailureKind.discoveryDenied;

    if (denied) {
      return Column(
        key: const Key('cast-picker-permission-denied'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off, size: 48, color: AppColors.error),
          const SizedBox(height: 16),
          Text(
            'Mydia needs local network permission',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Enable local network access for Mydia in your system settings, '
            'then try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      );
    }

    return Column(
      key: const Key('cast-picker-error'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 48, color: AppColors.error),
        const SizedBox(height: 16),
        Text(
          'Failed to find devices',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          error.toString(),
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
