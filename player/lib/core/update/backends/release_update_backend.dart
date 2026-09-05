import 'dart:async';

import '../../../domain/models/available_update.dart';
import '../platform_updater.dart';
import '../update_backend.dart';
import '../update_service.dart';

/// Updates from a GitHub release asset: the Windows installer and the Linux
/// tarball. Wraps the existing UpdateService and PlatformUpdater unchanged.
class ReleaseUpdateBackend implements UpdateBackend {
  ReleaseUpdateBackend({
    required PlatformUpdater updater,
    required String currentVersion,
    UpdateService? service,
  })  : _updater = updater,
        _currentVersion = currentVersion,
        _service = service ?? UpdateService();

  final PlatformUpdater _updater;
  final String _currentVersion;
  final UpdateService _service;
  final _controller = StreamController<AvailableUpdate?>.broadcast();

  AppUpdate? _latest;

  @override
  Future<void> start() async {
    // Nothing to open. The GitHub client is stateless and UpdateService owns
    // its own rate limiting.
  }

  @override
  Stream<AvailableUpdate?> get availability => _controller.stream;

  @override
  ManualCheckBehaviour get manualCheck => ManualCheckBehaviour.checksOnly;

  @override
  bool get canUpdateInPlace => _updater.canUpdateInPlace;

  @override
  Future<void> refresh({bool force = false}) async {
    _latest = await _service.checkForUpdate(
      currentVersion: _currentVersion,
      force: force,
    );
    if (!_controller.isClosed) _controller.add(_latest);
  }

  @override
  Future<UpdateOutcome> requestUpdate({
    void Function(double progress)? onProgress,
  }) async {
    final update = _latest;
    if (update == null) return const AlreadyUpToDate();

    try {
      await _updater.applyUpdate(update, onProgress: onProgress);
      // On the archive platforms a successful apply calls exit(0), so this
      // line is only reached when the updater handed off without replacing
      // anything, which is what the browser fallback does. Reporting it as
      // installed is still right from this screen's point of view: there is
      // nothing further for it to do.
      return const UpdateInstalled();
    } catch (e) {
      return UpdateFailed(e.toString());
    }
  }

  @override
  Future<void> dispose() => _controller.close();
}
