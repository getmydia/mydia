import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/cast/cast_providers.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/cast_device.dart';

/// Shows a dialog to pick a Chromecast device to cast to.
///
/// Returns the selected device, or null if cancelled.
Future<CastDevice?> showCastDevicePicker(BuildContext context) async {
  return showDialog<CastDevice>(
    context: context,
    builder: (context) => const CastDevicePickerDialog(),
  );
}

/// Dialog for selecting a Chromecast device.
class CastDevicePickerDialog extends ConsumerWidget {
  const CastDevicePickerDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesAsync = ref.watch(availableDevicesProvider);
    final currentDevice = ref.watch(currentCastDeviceProvider);
    final castService = ref.read(castServiceProvider);

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
          data: (devices) {
            if (devices.isEmpty) {
              return const Column(
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

            return ListView.builder(
              shrinkWrap: true,
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                final isConnected = currentDevice?.id == device.id;

                return ListTile(
                  leading: Icon(
                    isConnected ? Icons.cast_connected : Icons.cast,
                    color: isConnected
                        ? AppColors.primary
                        : AppColors.textSecondary,
                  ),
                  title: Text(device.name),
                  subtitle: device.model != null ? Text(device.model!) : null,
                  trailing: isConnected
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () async {
                    if (isConnected) {
                      // Disconnect from current device
                      await castService.disconnect();
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    } else {
                      // Connect to new device
                      await castService.connect(device);
                      if (context.mounted) {
                        Navigator.of(context).pop(device);
                      }
                    }
                  },
                );
              },
            );
          },
          loading: () => const Center(
            child: CircularProgressIndicator(),
          ),
          error: (error, stack) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 48, color: AppColors.error),
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
            ),
          ),
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
