import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/models/remote_device.dart';

part 'devices_controller.g.dart';

/// One Mydia instance's device list and revocations.
@riverpod
class DevicesController extends _$DevicesController {
  @override
  Future<List<RemoteDevice>> build(SourceId sourceId) => _load();

  /// Resolved per call, so a rebuilt source object is picked up.
  RemoteTargets _targets() {
    final targets =
        ref.read(mediaSourceProvider(sourceId))?.as<RemoteTargets>();
    if (targets == null) throw Exception('No Mydia server');
    return targets;
  }

  Future<List<RemoteDevice>> _load() => _targets().devices();

  /// Refresh the devices list.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// Revoke a device by ID.
  Future<bool> revokeDevice(String deviceId) async {
    final success = await _targets().revokeDevice(deviceId);
    if (success) await refresh();
    return success;
  }
}
