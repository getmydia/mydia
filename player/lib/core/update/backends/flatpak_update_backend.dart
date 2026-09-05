import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../domain/models/available_update.dart';
import '../flatpak_portal.dart';
import '../update_backend.dart';

/// Updates through org.freedesktop.portal.Flatpak.
///
/// The portal is the only source of truth inside the sandbox. It reports
/// commits rather than versions, so nothing here names a version, and the
/// GitHub release client is never consulted.
class FlatpakUpdateBackend implements UpdateBackend {
  FlatpakUpdateBackend({
    required FlatpakPortal portal,
    required String releaseNotesUrl,
  })  : _portal = portal,
        _releaseNotesUrl = releaseNotesUrl;

  final FlatpakPortal _portal;
  final String _releaseNotesUrl;
  final _controller = StreamController<AvailableUpdate?>.broadcast();

  bool _monitoring = false;
  bool _awaitingRestart = false;
  bool _updateReady = false;
  StreamSubscription<FlatpakCommits>? _sub;
  Future<UpdateOutcome>? _inFlight;

  /// Creates the monitor. A portal that refuses leaves the backend alive but
  /// reporting no in-place update, which is what makes the settings row
  /// explain itself instead of vanishing.
  @override
  Future<void> start() async {
    // Callable more than once, because a dropped connection restarts it.
    // Without this the old subscription would leak and every signal would be
    // handled twice.
    await _sub?.cancel();
    _sub = null;

    try {
      await _portal.startMonitoring();
      _monitoring = true;
    } catch (e) {
      debugPrint('[FlatpakUpdateBackend] Portal unavailable: $e');
      return;
    }

    _sub = _portal.updatesAvailable.listen((commits) {
      // Independent booleans over the same three commits, not exclusive
      // states. Both are true when a newer remote lands while a previous
      // install is still waiting for a restart. Downloading first gets the
      // user to the newest build with one restart instead of two.
      _awaitingRestart = commits.awaitingRestart;
      _updateReady = commits.updateReady;

      if (commits.updateReady) {
        _publish(FlatpakRemoteUpdate(releaseNotesUrl: _releaseNotesUrl));
      } else if (commits.awaitingRestart) {
        _publish(FlatpakRemoteUpdate(
          releaseNotesUrl: _releaseNotesUrl,
          installedAwaitingRestart: true,
        ));
      } else {
        _publish(null);
      }
    });
  }

  void _publish(AvailableUpdate? update) {
    if (!_controller.isClosed) _controller.add(update);
  }

  @override
  Stream<AvailableUpdate?> get availability => _controller.stream;

  /// Unconditional, including when the portal never started. The row has to
  /// stay and route here, because requestUpdate is the only place that can
  /// tell the user why nothing is happening. A row that quietly changed
  /// behaviour would be a row that does nothing.
  @override
  ManualCheckBehaviour get manualCheck =>
      ManualCheckBehaviour.checksAndInstalls;

  @override
  bool get canUpdateInPlace => _monitoring;

  @override
  Future<void> refresh({bool force = false}) async {
    // Deliberately nothing. The portal polls on its own 30 minute timer and
    // exposes no way to ask for a check. requestUpdate is the only honest
    // on-demand path, because its transaction pulls fresh.
  }

  @override
  Future<UpdateOutcome> requestUpdate({
    void Function(double progress)? onProgress,
  }) {
    // Two overlapping presses would open two transactions against one monitor
    // object, and Progress is broadcast per monitor rather than per call, so
    // each would see the other's signals. The second caller gets the first
    // call's result. Its onProgress is deliberately dropped: there is one
    // transaction, and it already has a reporter.
    return _inFlight ??=
        _runUpdate(onProgress: onProgress).whenComplete(() => _inFlight = null);
  }

  Future<UpdateOutcome> _runUpdate({
    void Function(double progress)? onProgress,
  }) async {
    if (!_monitoring) {
      return const UpdateFailed(
        'Could not reach the Flatpak portal. Update from your software centre.',
      );
    }

    // Already deployed underneath us, and nothing newer waiting on the
    // remote. There is nothing to pull, and asking the portal would report an
    // empty transaction and read as "up to date" while the user is still
    // running the old build. When a newer remote has also landed,
    // _updateReady wins here so the transaction runs and the user reaches the
    // newest build with one restart instead of two.
    if (_awaitingRestart && !_updateReady) {
      return const UpdateInstalled(restartRequired: true);
    }

    try {
      await for (final progress in _portal.update()) {
        switch (progress.status) {
          case FlatpakProgressStatus.running:
            onProgress?.call(progress.progress / 100);
          case FlatpakProgressStatus.empty:
            return const AlreadyUpToDate();
          case FlatpakProgressStatus.done:
            onProgress?.call(1.0);
            _awaitingRestart = true;
            _updateReady = false;
            return const UpdateInstalled(restartRequired: true);
          case FlatpakProgressStatus.failed:
            // A permissions rejection can arrive on this signal rather than as
            // a synchronous NotSupported. That was confirmed against the live
            // portal, so classify on the error name instead of reporting every
            // async failure as generic.
            if (progress.errorName ==
                'org.freedesktop.DBus.Error.NotSupported') {
              return const UpdateUnsupported(
                'This update needs new permissions. Install it from your '
                'software centre.',
              );
            }
            return UpdateFailed(
              progress.errorMessage ?? 'The update failed.',
            );
        }
      }
      // The stream closed without a terminal status. Treating that as success
      // would send the user to restart into a build that may not exist.
      return const UpdateFailed('The update ended without reporting a result.');
    } on FlatpakUpdateNotPermitted {
      return const UpdateUnsupported(
        'This update needs new permissions. Install it from your software '
        'centre.',
      );
    } catch (e) {
      // The connection can drop mid-transaction, which leaves the monitor
      // dead. Rebuild it now so the next press is not doomed too, and report
      // this attempt as the failure it was.
      _monitoring = false;
      await start();
      return UpdateFailed(e.toString());
    }
  }

  /// Starts a fresh instance on the newest deployed commit. The caller exits
  /// afterwards.
  Future<void> restart() => _portal.restartIntoLatest();

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _portal.close();
    await _controller.close();
  }
}
