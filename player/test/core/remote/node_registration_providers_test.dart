import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/core/remote/remote_roster.dart' show DeviceRoster;
import 'package:player/domain/models/remote_device.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';

import '../../presentation/screens/sources/fake_media_source.dart';

/// A Mydia instance's registration seam: records every node id it is asked to
/// publish and answers [result].
class _RemoteSource extends FakeMediaSource implements RemoteTargets {
  _RemoteSource(SourceId id, this.registered, {this.result = true})
      : super(id: id);

  final List<String> registered;
  final bool result;

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.remoteTargets};

  @override
  Future<bool> registerNode(String nodeId) async {
    registered.add(nodeId);
    return result;
  }

  @override
  DeviceRoster get roster => throw UnimplementedError();

  @override
  Future<List<RemoteDevice>> devices() async => const [];

  @override
  Future<bool> revokeDevice(String deviceId) async => true;
}

SourceAccountRecord _record(String account, {bool needsReauth = false}) =>
    SourceAccountRecord(
      account: ProviderAccount(
        id: account,
        kind: SourceKind.mydia,
        displayName: 'Instance $account',
        storageNamespace: 'source/$account',
        activeProfileId: 'owner',
        needsReauth: needsReauth,
      ),
      profiles: [
        SourceProfile(
            id: 'owner', accountId: account, name: 'Owner', isOwner: true),
      ],
      servers: [
        SourceServer(
            id: 'inst', accountId: account, profileId: 'owner', name: account),
      ],
      addedAtMs: account.codeUnitAt(0),
    );

class _Records extends SourceRecordsNotifier {
  _Records(this._initial);
  final List<SourceAccountRecord> _initial;

  @override
  Future<SourceSnapshot> build() async => SourceSnapshot(accounts: _initial);

  void emit(List<SourceAccountRecord> next) =>
      state = AsyncData(SourceSnapshot(accounts: next));
}

/// Bumped to make the source objects get rebuilt, the way a credentials save
/// does.
class _Generation extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state += 1;
}

final _generation = NotifierProvider<_Generation, int>(_Generation.new);

void main() {
  late _FakeP2pStatus p2p;
  late Map<String, List<String>> sent;
  late bool result;
  late ProviderContainer container;
  late _Records records;

  SourceId idOf(String account) => mydiaSourceIdOf(_record(account));

  Future<void> start({
    List<String> accounts = const ['a', 'b'],
    Future<bool>? controllable,
  }) async {
    p2p = _FakeP2pStatus();
    sent = {
      for (final a in ['a', 'b']) a: <String>[]
    };
    records = _Records([for (final a in accounts) _record(a)]);
    container = ProviderContainer(overrides: [
      p2pStatusNotifierProvider.overrideWith(() => p2p),
      remoteControlEnabledProvider
          .overrideWith((ref) => controllable ?? Future.value(true)),
      sourceRecordsProvider.overrideWith(() => records),
      mediaSourceProvider.overrideWith((ref, id) {
        ref.watch(_generation);
        for (final a in ['a', 'b']) {
          if (id == idOf(a)) return _RemoteSource(id, sent[a]!, result: result);
        }
        return null;
      }),
    ]);
    addTearDown(container.dispose);
    container.listen(nodeRegistrationsProvider, (_, __) {});
    await container.read(sourceRecordsProvider.future);
    await pumpEventQueue();
  }

  setUp(() => result = true);

  test('registers with every Mydia instance', () async {
    await start();
    p2p.publish('n' * 64);
    await pumpEventQueue();

    expect(sent['a'], ['n' * 64]);
    expect(sent['b'], ['n' * 64]);
    final states = container.read(nodeRegistrationsProvider);
    expect(states.keys, {idOf('a'), idOf('b')});
    expect(states.values, everyElement(isA<RegistrationSucceeded>()));
  });

  test('removing an instance drops only its registration', () async {
    await start();
    p2p.publish('n' * 64);
    await pumpEventQueue();

    records.emit([_record('a')]);
    await pumpEventQueue();

    expect(container.read(nodeRegistrationsProvider).keys, {idOf('a')});
    expect(sent['a'], hasLength(1));
    expect(sent['b'], hasLength(1));
  });

  test('a token refresh does not register again', () async {
    await start();
    p2p.publish('n' * 64);
    await pumpEventQueue();

    container.read(_generation.notifier).bump();
    await pumpEventQueue();

    expect(sent['a'], hasLength(1));
    expect(sent['b'], hasLength(1));
  });

  test('signing in again registers again', () async {
    await start();
    p2p.publish('n' * 64);
    await pumpEventQueue();

    records.emit([_record('a', needsReauth: true), _record('b')]);
    await pumpEventQueue();
    expect(sent['a'], hasLength(1), reason: 'not ready while signed out');
    expect(container.read(nodeRegistrationsProvider)[idOf('a')],
        isA<RegistrationWaiting>());

    records.emit([_record('a'), _record('b')]);
    await pumpEventQueue();

    expect(sent['a'], hasLength(2));
    expect(sent['b'], hasLength(1));
  });

  test('retryAll retries only the instances that are not registered', () async {
    result = false;
    await start();
    p2p.publish('n' * 64);
    await pumpEventQueue();
    expect(container.read(nodeRegistrationsProvider).values,
        everyElement(isA<RegistrationFailed>()));
    final before = sent['a']!.length;

    container.read(nodeRegistrationsProvider.notifier).retryAll();
    await pumpEventQueue();

    expect(sent['a']!.length, greaterThan(before));
    expect(sent['b']!.length, greaterThan(before));
  });

  test('retry retries one instance and leaves the others alone', () async {
    result = false;
    await start();
    p2p.publish('n' * 64);
    await pumpEventQueue();
    final beforeA = sent['a']!.length;
    final beforeB = sent['b']!.length;

    container.read(nodeRegistrationsProvider.notifier).retry(idOf('a'));
    await pumpEventQueue();

    expect(sent['a']!.length, greaterThan(beforeA));
    expect(sent['b']!.length, beforeB);
  });

  test('waits for the node id, then registers', () async {
    await start();
    expect(container.read(nodeRegistrationsProvider).values,
        everyElement(isA<RegistrationWaiting>()));
    expect(sent['a'], isEmpty);

    p2p.publish('n' * 64);
    await pumpEventQueue();

    expect(sent['a'], ['n' * 64]);
  });

  test('a setting that has not resolved is waiting, then idle when off',
      () async {
    final setting = Completer<bool>();
    await start(controllable: setting.future);
    p2p.publish('n' * 64);
    await pumpEventQueue();

    expect(sent['a'], isEmpty);
    expect(container.read(nodeRegistrationsProvider).values,
        everyElement(isA<RegistrationWaiting>()));

    setting.complete(false);
    await pumpEventQueue();

    expect(sent['a'], isEmpty);
    expect(container.read(nodeRegistrationsProvider).values,
        everyElement(isA<RegistrationIdle>()));
  });

  group('worstRegistrationStatus', () {
    final at = DateTime(2026);
    test('orders Failed over Waiting over InFlight over Succeeded over Idle',
        () {
      const failed = RegistrationFailed('x', 1, null);
      const waiting = RegistrationWaiting('y');
      const inFlight = RegistrationInFlight('n', 1);
      final ok = RegistrationSucceeded('n', at);
      const idle = RegistrationIdle();

      expect(worstRegistrationStatus([idle, ok, inFlight, waiting, failed]),
          failed);
      expect(worstRegistrationStatus([idle, ok, inFlight, waiting]), waiting);
      expect(worstRegistrationStatus([idle, ok, inFlight]), inFlight);
      expect(worstRegistrationStatus([idle, ok]), ok);
      expect(worstRegistrationStatus([idle]), idle);
      expect(worstRegistrationStatus(const []), isA<RegistrationIdle>());
    });
  });
}

class _FakeP2pStatus extends P2pStatusNotifier {
  @override
  P2pStatus build() => const P2pStatus.initial();

  void publish(String nodeId) {
    state = const P2pStatus.initial().copyWith(
      isInitialized: true,
      nodeId: nodeId,
    );
  }
}
