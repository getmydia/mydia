import '../../../domain/models/available_update.dart';
import '../update_backend.dart';
import '../update_track.dart';
import '../updaters/macos_updater.dart';

/// macOS. Sparkle owns checking, downloading, verifying and relaunching, and
/// shows its own native UI for all of it, so this backend never surfaces a
/// card of its own.
///
/// It exists so the two Platform.isMacOS special cases that used to sit
/// inline in UpdateNotifier live behind the same interface as everything
/// else.
class SparkleUpdateBackend implements UpdateBackend {
  SparkleUpdateBackend({
    Future<void> Function()? checkForUpdates,
    Future<UpdateTrack> Function()? readTrack,
    Future<bool> Function(UpdateTrack track)? writeTrack,
  })  : _checkForUpdates = checkForUpdates ?? MacOSUpdater.checkForUpdates,
        _readTrack = readTrack ?? MacOSUpdater.currentTrack,
        _writeTrack = writeTrack ?? MacOSUpdater.setTrack;

  final Future<void> Function() _checkForUpdates;
  final Future<UpdateTrack> Function() _readTrack;
  final Future<bool> Function(UpdateTrack track) _writeTrack;
  UpdateTrack _track = UpdateTrack.stable;

  @override
  Future<void> start() async {
    // Sparkle is already running inside the app bundle. The one thing to
    // fetch is the channel the Swift side holds, which owns the value
    // because allowedChannels(for:) is answered synchronously, outside any
    // Dart frame.
    _track = await _readTrack();
  }

  @override
  Stream<AvailableUpdate?> get availability => const Stream.empty();

  @override
  ManualCheckBehaviour get manualCheck =>
      ManualCheckBehaviour.delegatesToSparkle;

  @override
  bool get canUpdateInPlace => true;

  @override
  Set<UpdateTrack> get availableTracks =>
      // No macOS dev builds are published yet. Offering the track would put a
      // choice in the picker that resolves to nothing.
      const {UpdateTrack.stable, UpdateTrack.beta};

  @override
  UpdateTrack get currentTrack => _track;

  @override
  Future<TrackSwitchOutcome> selectTrack(UpdateTrack track) async {
    if (!availableTracks.contains(track)) {
      return TrackSwitchUnsupported(
        '${track.label} builds are not published for macOS yet.',
      );
    }
    if (!await _writeTrack(track)) {
      return const TrackSwitchUnsupported(
        'macOS would not save that choice. Try again.',
      );
    }
    _track = track;
    return const TrackSwitchApplied();
  }

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
