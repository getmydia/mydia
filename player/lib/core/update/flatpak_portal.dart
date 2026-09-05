import 'dart:async';
import 'dart:convert';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// D-Bus names, kept together so a typo is visible in one place.
const _portalName = 'org.freedesktop.portal.Flatpak';
const _portalPath = '/org/freedesktop/portal/Flatpak';
const _monitorInterface = 'org.freedesktop.portal.Flatpak.UpdateMonitor';

/// Spawn using the newest deployed commit rather than the running one.
/// FLATPAK_SPAWN_FLAGS_LATEST_VERSION, verified working from inside the
/// sandbox with no extra finish-args.
const _spawnLatestVersion = 2;

/// A GVariant bytestring: UTF-8 followed by the terminating NUL.
///
/// The portal's Spawn takes cwd_path and argv as bytestrings. gdbus writes
/// these as b'/app' and includes the terminator; omitting it here sends a
/// path the portal does not recognise.
List<int> flatpakByteString(String value) => [...utf8.encode(value), 0];

/// The three commits the portal reports in UpdateAvailable.
class FlatpakCommits {
  final String? running;
  final String? local;
  final String? remote;

  const FlatpakCommits({this.running, this.local, this.remote});

  factory FlatpakCommits.fromDict(Map<String, DBusValue> info) =>
      FlatpakCommits(
        running: info['running-commit']?.asString(),
        local: info['local-commit']?.asString(),
        remote: info['remote-commit']?.asString(),
      );

  /// The remote carries something the machine has not downloaded.
  bool get updateReady => remote != null && local != null && remote != local;

  /// Already downloaded and deployed; only this process is behind.
  bool get awaitingRestart =>
      local != null && running != null && local != running;
}

enum FlatpakProgressStatus { running, empty, done, failed }

/// One Progress signal from an in-flight update.
class FlatpakProgress {
  final int progress;
  final FlatpakProgressStatus status;
  final String? errorMessage;

  /// The D-Bus error name, e.g. 'org.freedesktop.DBus.Error.NotSupported'.
  ///
  /// A permissions rejection can arrive here instead of as a synchronous
  /// call failure (confirmed against the live portal: a NotSupported update
  /// was reported through this signal, not thrown from Update()). A caller
  /// that needs to classify the failure should match on this stable
  /// identifier rather than parsing [errorMessage], which is prose meant for
  /// a person and carries no compatibility guarantee.
  final String? errorName;

  const FlatpakProgress({
    required this.progress,
    required this.status,
    this.errorMessage,
    this.errorName,
  });

  factory FlatpakProgress.fromDict(Map<String, DBusValue> info) =>
      FlatpakProgress(
        progress: info['progress']?.asUint32() ?? 0,
        status: switch (info['status']?.asUint32()) {
          0 => FlatpakProgressStatus.running,
          1 => FlatpakProgressStatus.empty,
          2 => FlatpakProgressStatus.done,
          // Anything unrecognised is a failure. Guessing success would tell
          // the user to restart into a build that was never installed.
          _ => FlatpakProgressStatus.failed,
        },
        errorMessage: info['error_message']?.asString(),
        errorName: info['error']?.asString(),
      );
}

/// The portal refused because the new build asks for permissions the
/// installed one does not have. Nothing in-app can resolve this.
class FlatpakUpdateNotPermitted implements Exception {
  @override
  String toString() => 'FlatpakUpdateNotPermitted';
}

/// The portal operations this app needs, with no policy in them.
abstract interface class FlatpakPortal {
  /// Creates the update monitor. Must be awaited before [updatesAvailable]
  /// yields anything.
  Future<void> startMonitoring();

  /// Fires when the portal's own poll finds something. The portal polls on a
  /// 30 minute timer and offers no way to ask for a check, so a short session
  /// may never see an event.
  Stream<FlatpakCommits> get updatesAvailable;

  /// Asks the portal to pull and install. It builds its own transaction, so
  /// this doubles as an on-demand check and reports an empty status when
  /// there is nothing to do.
  ///
  /// Throws [FlatpakUpdateNotPermitted] when the portal refuses.
  Stream<FlatpakProgress> update();

  /// Starts a fresh instance on the newest deployed commit.
  Future<void> restartIntoLatest();

  Future<void> close();
}

class DBusFlatpakPortal implements FlatpakPortal {
  DBusFlatpakPortal({
    DBusClient? client,
    String executablePath = '/app/bin/mydia-player',
  })  : _client = client ?? DBusClient.session(),
        _executablePath = executablePath;

  final DBusClient _client;
  final String _executablePath;

  final _available = StreamController<FlatpakCommits>.broadcast();
  DBusRemoteObject? _monitor;
  StreamSubscription<DBusSignal>? _availableSub;

  DBusRemoteObject get _portal => DBusRemoteObject(
        _client,
        name: _portalName,
        path: DBusObjectPath(_portalPath),
      );

  @override
  Stream<FlatpakCommits> get updatesAvailable => _available.stream;

  @override
  Future<void> startMonitoring() async {
    final reply = await _portal.callMethod(
      _portalName,
      'CreateUpdateMonitor',
      [DBusDict.stringVariant({})],
      replySignature: DBusSignature('o'),
    );

    final monitor = DBusRemoteObject(
      _client,
      name: _portalName,
      path: reply.returnValues[0].asObjectPath(),
    );
    _monitor = monitor;

    _availableSub = DBusRemoteObjectSignalStream(
      object: monitor,
      interface: _monitorInterface,
      name: 'UpdateAvailable',
    ).listen((signal) {
      _available.add(
        FlatpakCommits.fromDict(signal.values[0].asStringVariantDict()),
      );
    });
  }

  @override
  Stream<FlatpakProgress> update() {
    final monitor = _monitor;
    if (monitor == null) {
      return Stream.error(StateError('startMonitoring was not called'));
    }

    final controller = StreamController<FlatpakProgress>();
    StreamSubscription<DBusSignal>? progressSub;

    // Every failure path has to reach here. An error that escapes instead
    // leaves the controller open, so the caller's await never returns and the
    // progress bar on this stream spins forever. Closing the controller is
    // also what cancels progressSub, by way of onCancel.
    Future<void> fail(Object error) async {
      if (controller.isClosed) return;
      controller.addError(error);
      await controller.close();
    }

    controller.onListen = () async {
      try {
        progressSub = DBusRemoteObjectSignalStream(
          object: monitor,
          interface: _monitorInterface,
          name: 'Progress',
        ).listen(
          (signal) {
            try {
              final progress = FlatpakProgress.fromDict(
                signal.values[0].asStringVariantDict(),
              );
              controller.add(progress);
              if (progress.status != FlatpakProgressStatus.running) {
                controller.close();
              }
            } catch (e) {
              // A malformed signal must not escape to the zone. Unhandled
              // there it would leave this stream running forever.
              fail(e);
            }
          },
          onError: fail,
        );

        await monitor.callMethod(
          _monitorInterface,
          'Update',
          [const DBusString(''), DBusDict.stringVariant({})],
          replySignature: DBusSignature(''),
        );
      } on DBusMethodResponseException catch (e) {
        await fail(
          e.response.errorName == 'org.freedesktop.DBus.Error.NotSupported'
              ? FlatpakUpdateNotPermitted()
              : e,
        );
      } catch (e) {
        // A dropped connection, a bad reply signature, anything at all.
        // Without this the throw escapes the async onListen closure and the
        // stream never terminates.
        await fail(e);
      }
    };

    controller.onCancel = () => progressSub?.cancel();
    return controller.stream;
  }

  @override
  Future<void> restartIntoLatest() async {
    await _portal.callMethod(
      _portalName,
      'Spawn',
      [
        DBusArray.byte(flatpakByteString('/app')),
        DBusArray(DBusSignature('ay'), [
          DBusArray.byte(flatpakByteString(_executablePath)),
        ]),
        DBusDict(DBusSignature('u'), DBusSignature('h'), {}),
        DBusDict(DBusSignature('s'), DBusSignature('s'), {}),
        const DBusUint32(_spawnLatestVersion),
        DBusDict.stringVariant({}),
      ],
      replySignature: DBusSignature('u'),
    );
  }

  @override
  Future<void> close() async {
    await _availableSub?.cancel();
    final monitor = _monitor;
    if (monitor != null) {
      try {
        await monitor.callMethod(
          _monitorInterface,
          'Close',
          [],
          replySignature: DBusSignature(''),
        );
      } catch (e) {
        debugPrint('[DBusFlatpakPortal] Close failed: $e');
      }
    }
    await _available.close();
    // Also tears down progressSub from an in-flight update(), if any: closing
    // the client ends its signal stream, which the listen() callback above
    // never explicitly cancels on this path.
    await _client.close();
  }
}
