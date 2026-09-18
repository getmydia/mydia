import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../domain/models/available_update.dart';
import '../android_installer.dart';
import '../platform_updater.dart';
import '../update_backend.dart';
import '../update_service.dart';
import '../update_track.dart';
import '../update_track_store.dart';

/// Updates from a GitHub release asset: the Windows installer and the Linux
/// tarball. Wraps the existing UpdateService and PlatformUpdater unchanged.
class ReleaseUpdateBackend implements UpdateBackend {
  ReleaseUpdateBackend({
    required PlatformUpdater updater,
    required String currentVersion,
    UpdateService? service,
    UpdateTrackStore? trackStore,
    Set<UpdateTrack> availableTracks = const {
      UpdateTrack.stable,
      UpdateTrack.beta,
      UpdateTrack.dev,
    },
  })  : _updater = updater,
        _currentVersion = currentVersion,
        _service = service ?? UpdateService(),
        _trackStore = trackStore ?? UpdateTrackStore(),
        _availableTracks = availableTracks;

  final PlatformUpdater _updater;
  final String _currentVersion;
  final UpdateService _service;
  final UpdateTrackStore _trackStore;
  final Set<UpdateTrack> _availableTracks;
  final _controller = StreamController<AvailableUpdate?>.broadcast();

  AppUpdate? _latest;
  UpdateTrack _track = UpdateTrack.stable;

  @override
  Future<void> start() async {
    // The stored track, read once. UpdateService is stateless and owns its
    // own rate limiting, so there is nothing else to open.
    _track = await _trackStore.read();
  }

  @override
  Stream<AvailableUpdate?> get availability => _controller.stream;

  @override
  ManualCheckBehaviour get manualCheck => ManualCheckBehaviour.checksOnly;

  @override
  bool get canUpdateInPlace => _updater.canUpdateInPlace;

  @override
  Set<UpdateTrack> get availableTracks => _availableTracks;

  @override
  UpdateTrack get currentTrack => _track;

  @override
  Future<TrackSwitchOutcome> selectTrack(UpdateTrack track) async {
    if (!_availableTracks.contains(track)) {
      return TrackSwitchUnsupported(
        '${track.label} builds are not published for this platform yet.',
      );
    }

    try {
      await _trackStore.write(track);
    } catch (e) {
      return TrackSwitchUnsupported('Could not save that choice: $e');
    }

    _track = track;
    // Look immediately rather than waiting for the next scheduled check, so
    // the choice visibly does something. The switch itself already
    // succeeded by this point, so a failed look does not undo it: catch
    // rather than let it escape, the same contract selectTrack owes its
    // caller everywhere else.
    try {
      await refresh(force: true);
    } catch (e) {
      debugPrint('[ReleaseUpdateBackend] Post-switch refresh failed: $e');
    }
    return const TrackSwitchApplied();
  }

  @override
  Future<void> refresh({bool force = false}) async {
    _latest = await _service.checkForUpdate(
      currentVersion: _currentVersion,
      track: _track,
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
      // nothing further for it to do. Android is the exception: its updater
      // sets handsOffUnconfirmed because a committed install session opens
      // Android's own confirmation dialog and returns before the user has
      // answered it, so this reports that as deferred instead.
      if (_updater.handsOffUnconfirmed) return const UpdateDeferred();
      return const UpdateInstalled();
    } on InstallerPermissionDenied catch (e) {
      // Not a failure to retry: the user has to grant the permission, and the
      // updater has already opened the screen where they do it.
      return UpdateUnsupported(e.toString());
    } on InstallerUnavailable catch (e) {
      return UpdateUnsupported(e.toString());
    } catch (e) {
      return UpdateFailed(e.toString());
    }
  }

  @override
  Future<void> dispose() => _controller.close();
}
