import '../../../domain/models/available_update.dart';
import '../update_backend.dart';
import '../updaters/macos_updater.dart';

/// macOS. Sparkle owns checking, downloading, verifying and relaunching, and
/// shows its own native UI for all of it, so this backend never surfaces a
/// card of its own.
///
/// It exists so the two Platform.isMacOS special cases that used to sit
/// inline in UpdateNotifier live behind the same interface as everything
/// else.
class SparkleUpdateBackend implements UpdateBackend {
  SparkleUpdateBackend({Future<void> Function()? checkForUpdates})
      : _checkForUpdates = checkForUpdates ?? MacOSUpdater.checkForUpdates;

  final Future<void> Function() _checkForUpdates;

  @override
  Future<void> start() async {
    // Sparkle is already running inside the app bundle.
  }

  @override
  Stream<AvailableUpdate?> get availability => const Stream.empty();

  @override
  ManualCheckBehaviour get manualCheck =>
      ManualCheckBehaviour.delegatesToSparkle;

  @override
  bool get canUpdateInPlace => true;

  @override
  Future<void> refresh({bool force = false}) async {
    // Sparkle checks on launch by itself. A refresh here would open its
    // dialog unprompted.
  }

  @override
  Future<UpdateOutcome> requestUpdate({
    void Function(double progress)? onProgress,
  }) async {
    await _checkForUpdates();
    return const UpdateDeferred();
  }

  @override
  Future<void> dispose() async {}
}
