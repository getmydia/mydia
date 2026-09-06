// Exercises DBusFlatpakPortal's actual D-Bus wiring: startMonitoring,
// update(), restartIntoLatest and close. flatpak_portal_test.dart only
// covers the pure decoders (FlatpakCommits.fromDict, FlatpakProgress.fromDict,
// flatpakByteString); this file covers the D-Bus plumbing around them.
//
// Why not mockito: DBusRemoteObjectSignalStream (which startMonitoring and
// update() both use to receive signals) subscribes by directly poking
// private DBusClient fields and methods (_signalStreams, _addMatch,
// _connect), defined in the dbus package's own dbus_client.dart. A
// Mockito-generated mock only implements DBusClient's *public* interface, so
// the moment production code calls `.listen()` on one of these signal
// streams, the real (unmockable) internals run against a mock object that
// has none of that private state, and the call fails before any stubbing
// could matter. `DBusRemoteObject.callMethod` alone would mock cleanly, but
// that only covers half of what this file needs to prove.
//
// Instead this uses the same technique the dbus package's own test suite
// (dbus_test.dart) uses to test DBusClient: a real, in-process DBusServer
// (a pure-Dart D-Bus daemon, no system bus involved) bound to a local unix
// socket, with a fake org.freedesktop.portal.Flatpak service registered on
// one connection and the real DBusFlatpakPortal-under-test talking to it
// through a second, genuine DBusClient connection. This is a real D-Bus
// session end to end -- real method dispatch, real signal delivery, real
// wire encoding -- just not the system's Flatpak portal.
import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/flatpak_portal.dart';

const _portalName = 'org.freedesktop.portal.Flatpak';
const _portalPath = '/org/freedesktop/portal/Flatpak';
const _monitorInterface = 'org.freedesktop.portal.Flatpak.UpdateMonitor';

/// What the fake portal object observed in a Spawn call.
class RecordedSpawn {
  RecordedSpawn({required this.cwd, required this.argv, required this.flags});

  final List<int> cwd;
  final List<List<int>> argv;
  final int flags;
}

/// The top-level portal object: CreateUpdateMonitor and Spawn.
class _FakeFlatpakPortal extends DBusObject {
  _FakeFlatpakPortal({required this.monitorPath})
      : super(DBusObjectPath(_portalPath));

  final DBusObjectPath monitorPath;

  /// Null until CreateUpdateMonitor is called; records which interface it
  /// arrived on so the test can prove the real portal interface was used.
  String? lastCreateMonitorInterface;
  RecordedSpawn? lastSpawn;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _portalName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'CreateUpdateMonitor':
        lastCreateMonitorInterface = methodCall.interface;
        return DBusMethodSuccessResponse([monitorPath]);
      case 'Spawn':
        lastSpawn = RecordedSpawn(
          cwd: methodCall.values[0].asByteArray().toList(),
          argv: methodCall.values[1]
              .asArray()
              .map((value) => value.asByteArray().toList())
              .toList(),
          flags: methodCall.values[4].asUint32(),
        );
        return DBusMethodSuccessResponse([const DBusUint32(9999)]);
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}

/// The update monitor object CreateUpdateMonitor hands back. Update's
/// response is configurable per test so the same fake can drive the success,
/// permission-denied and malformed-reply scenarios.
class _FakeUpdateMonitor extends DBusObject {
  _FakeUpdateMonitor(super.path);

  int updateCallCount = 0;
  bool closeCalled = false;
  Future<DBusMethodResponse> Function()? onUpdate;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _monitorInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'Update':
        updateCallCount++;
        final handler = onUpdate;
        return handler == null ? DBusMethodSuccessResponse() : await handler();
      case 'Close':
        closeCalled = true;
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  Future<void> emitUpdateAvailable(Map<String, DBusValue> info) => emitSignal(
        _monitorInterface,
        'UpdateAvailable',
        [DBusDict.stringVariant(info)],
      );

  Future<void> emitProgress(Map<String, DBusValue> info) => emitSignal(
        _monitorInterface,
        'Progress',
        [DBusDict.stringVariant(info)],
      );

  /// A Progress signal with the wrong payload shape: no values at all,
  /// so decoding `signal.values[0]` blows up instead of just producing a
  /// dict with missing keys.
  Future<void> emitMalformedProgress() =>
      emitSignal(_monitorInterface, 'Progress', const []);
}

/// A private in-process D-Bus bus: a fake org.freedesktop.portal.Flatpak
/// service on one connection, and the real client DBusFlatpakPortal talks to
/// on another.
class _FlatpakPortalHarness {
  _FlatpakPortalHarness._(
    this.server,
    this.serviceClient,
    this.testClient,
    this.portalObject,
    this.monitorObject,
  );

  final DBusServer server;
  final DBusClient serviceClient;
  final DBusClient testClient;
  final _FakeFlatpakPortal portalObject;
  final _FakeUpdateMonitor monitorObject;

  static int _nextMonitorId = 0;

  static Future<_FlatpakPortalHarness> start() async {
    final server = DBusServer();
    final address =
        await server.listenAddress(DBusAddress.unix(dir: Directory.systemTemp));
    final serviceClient = DBusClient(address);
    final nameReply = await serviceClient.requestName(_portalName);
    if (nameReply != DBusRequestNameReply.primaryOwner) {
      throw StateError(
        'fake portal service could not claim $_portalName: $nameReply',
      );
    }

    final monitorPath = DBusObjectPath(
      '$_portalPath/update_monitor/u${_nextMonitorId++}',
    );
    final monitorObject = _FakeUpdateMonitor(monitorPath);
    await serviceClient.registerObject(monitorObject);

    final portalObject = _FakeFlatpakPortal(monitorPath: monitorPath);
    await serviceClient.registerObject(portalObject);

    final testClient = DBusClient(address);
    return _FlatpakPortalHarness._(
      server,
      serviceClient,
      testClient,
      portalObject,
      monitorObject,
    );
  }

  DBusFlatpakPortal makePortal({
    String executablePath = '/app/bin/mydia-player',
  }) =>
      DBusFlatpakPortal(client: testClient, executablePath: executablePath);

  /// Forces a full round trip on the same connection DBusFlatpakPortal uses.
  /// Signal subscriptions register their match rule with a fire-and-forget
  /// AddMatch call sent *before* this method returns, so awaiting it proves
  /// the server has already processed that AddMatch (D-Bus preserves
  /// per-connection message order) and any signal emitted afterwards will
  /// actually be routed to the subscriber instead of silently dropped.
  Future<void> settle() => testClient.ping();

  Future<void> dispose() async {
    try {
      await testClient.close();
    } catch (_) {
      // Already closed by the portal under test in some tests.
    }
    await serviceClient.close();
    await server.close();
  }
}

void main() {
  late _FlatpakPortalHarness harness;

  setUp(() async {
    harness = await _FlatpakPortalHarness.start();
  });

  tearDown(() => harness.dispose());

  group('startMonitoring', () {
    test('calls CreateUpdateMonitor on the Flatpak portal interface', () async {
      final portal = harness.makePortal();
      await portal.startMonitoring();

      expect(harness.portalObject.lastCreateMonitorInterface, _portalName);
    });

    test(
        'an UpdateAvailable signal on the returned monitor path decodes to '
        'FlatpakCommits', () async {
      final portal = harness.makePortal();
      await portal.startMonitoring();
      await harness.settle();

      final future = portal.updatesAvailable.first;
      await harness.monitorObject.emitUpdateAvailable({
        'running-commit': const DBusString('aaa'),
        'local-commit': const DBusString('bbb'),
        'remote-commit': const DBusString('bbb'),
      });

      final commits = await future.timeout(const Duration(seconds: 5));
      expect(commits.running, 'aaa');
      expect(commits.local, 'bbb');
      expect(commits.remote, 'bbb');
      expect(commits.awaitingRestart, isTrue);
    });
  });

  group('update', () {
    test('invokes Update on the UpdateMonitor interface', () async {
      final updateReceived = Completer<void>();
      harness.monitorObject.onUpdate = () async {
        if (!updateReceived.isCompleted) updateReceived.complete();
        return DBusMethodSuccessResponse();
      };

      final portal = harness.makePortal();
      await portal.startMonitoring();

      final stream = portal.update();
      final sub = stream.listen((_) {}, onError: (_) {});
      addTearDown(sub.cancel);

      await updateReceived.future.timeout(const Duration(seconds: 5));
      expect(harness.monitorObject.updateCallCount, 1);
    });

    test('Progress signals surface as decoded FlatpakProgress', () async {
      final updateReceived = Completer<void>();
      harness.monitorObject.onUpdate = () async {
        if (!updateReceived.isCompleted) updateReceived.complete();
        return DBusMethodSuccessResponse();
      };

      final portal = harness.makePortal();
      await portal.startMonitoring();

      final firstProgress = portal.update().first;

      await updateReceived.future.timeout(const Duration(seconds: 5));
      await harness.monitorObject.emitProgress({
        'progress': const DBusUint32(50),
        'status': const DBusUint32(0),
      });

      final progress = await firstProgress.timeout(const Duration(seconds: 5));
      expect(progress.progress, 50);
      expect(progress.status, FlatpakProgressStatus.running);
    });

    test('a terminal Progress status closes the stream', () async {
      final updateReceived = Completer<void>();
      harness.monitorObject.onUpdate = () async {
        if (!updateReceived.isCompleted) updateReceived.complete();
        return DBusMethodSuccessResponse();
      };

      final portal = harness.makePortal();
      await portal.startMonitoring();

      final stream = portal.update();
      final expectation = expectLater(
        stream,
        emitsInOrder([
          predicate<FlatpakProgress>(
            (p) => p.status == FlatpakProgressStatus.done,
          ),
          emitsDone,
        ]),
      );

      await updateReceived.future.timeout(const Duration(seconds: 5));
      await harness.monitorObject.emitProgress({
        'status': const DBusUint32(2),
      });

      await expectation;
    });

    test('NotSupported from Update surfaces as FlatpakUpdateNotPermitted',
        () async {
      harness.monitorObject.onUpdate =
          () async => DBusMethodErrorResponse.notSupported();

      final portal = harness.makePortal();
      await portal.startMonitoring();

      await expectLater(
        portal.update(),
        emitsInOrder([emitsError(isA<FlatpakUpdateNotPermitted>()), emitsDone]),
      );
    });

    test(
        'a different D-Bus error surfaces as itself, not '
        'FlatpakUpdateNotPermitted', () async {
      harness.monitorObject.onUpdate = () async =>
          DBusMethodErrorResponse('org.freedesktop.DBus.Error.AccessDenied');

      final portal = harness.makePortal();
      await portal.startMonitoring();

      await expectLater(
        portal.update(),
        emitsInOrder([
          emitsError(
            isA<DBusMethodResponseException>().having(
              (e) => e.errorName,
              'errorName',
              'org.freedesktop.DBus.Error.AccessDenied',
            ),
          ),
          emitsDone,
        ]),
      );
    });

    test(
        'a non-DBusMethodResponseException from Update still closes the '
        'stream instead of hanging', () async {
      // A success reply with the wrong signature makes the *client* throw
      // DBusReplySignatureException: a real dbus-package exception, but not
      // a DBusMethodResponseException, so production code must fall through
      // its generic catch clause rather than mistranslating this as
      // FlatpakUpdateNotPermitted, or (the actual regression class this
      // guards against) leaving the stream open forever.
      harness.monitorObject.onUpdate =
          () async => DBusMethodSuccessResponse([const DBusString('surprise')]);

      final portal = harness.makePortal();
      await portal.startMonitoring();

      await expectLater(
        portal.update(),
        emitsInOrder(
            [emitsError(isA<DBusReplySignatureException>()), emitsDone]),
      );
    });

    test(
        'a malformed Progress signal does not escape as an unhandled zone '
        'error and still closes the stream', () async {
      final updateReceived = Completer<void>();
      harness.monitorObject.onUpdate = () async {
        if (!updateReceived.isCompleted) updateReceived.complete();
        return DBusMethodSuccessResponse();
      };

      final portal = harness.makePortal();
      await portal.startMonitoring();

      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final stream = portal.update();
        final expectation = expectLater(
          stream,
          emitsInOrder([emitsError(isA<RangeError>()), emitsDone]),
        );

        await updateReceived.future.timeout(const Duration(seconds: 5));
        await harness.monitorObject.emitMalformedProgress();

        await expectation;
      }, (error, stack) => zoneErrors.add(error));

      expect(zoneErrors, isEmpty);
    });
  });

  group('restartIntoLatest', () {
    test('issues Spawn with flags 2, cwd /app and a NUL-terminated argv',
        () async {
      final portal =
          harness.makePortal(executablePath: '/app/bin/mydia-player');
      await portal.restartIntoLatest();

      final spawn = harness.portalObject.lastSpawn;
      expect(spawn, isNotNull);
      expect(spawn!.flags, 2);
      expect(spawn.cwd, [...'/app'.codeUnits, 0]);
      expect(spawn.argv, hasLength(1));
      expect(spawn.argv.first, [...'/app/bin/mydia-player'.codeUnits, 0]);
    });
  });

  group('close', () {
    // NOTE on coverage: close() both cancels _availableSub and closes
    // _client. Only the client-close half is independently provable here.
    // Once _client.close() runs, its socket teardown alone stops any further
    // UpdateAvailable delivery, so a black-box test that emits a signal
    // around close() cannot tell "the subscription was cancelled" apart from
    // "the socket died anyway" -- mutating away the `_availableSub?.cancel()`
    // call (with the emit racing concurrently with close(), and with the
    // emit sent strictly after close() returns) produced no observable
    // difference in either case. Proving that line specifically would need a
    // seam (e.g. exposing whether the subscription is still active).
    test('calls Close on the monitor and closes the client', () async {
      final portal = harness.makePortal();
      await portal.startMonitoring();

      await portal.close();

      expect(harness.monitorObject.closeCalled, isTrue);
      await expectLater(harness.testClient.ping(), throwsA(anything));
    });
  });
}
