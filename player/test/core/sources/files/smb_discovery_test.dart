import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/smb_discovery.dart';

BonsoirService _svc(String name, {String? hostname, int port = 445}) =>
    BonsoirService(
      name: name,
      type: '_smb._tcp',
      port: port,
      hostname: hostname,
    );

BonsoirDiscoveryEvent _resolved(String name, {String? hostname}) =>
    BonsoirDiscoveryServiceResolvedEvent(
        service: _svc(name, hostname: hostname));

void main() {
  late StreamController<BonsoirDiscoveryEvent> events;
  late int starts;
  late int stops;
  late List<String> resolveCalls;
  late BonsoirSmbDiscovery discovery;

  setUp(() {
    events = StreamController<BonsoirDiscoveryEvent>();
    starts = 0;
    stops = 0;
    resolveCalls = [];
    discovery = BonsoirSmbDiscovery.forTest(
      events.stream,
      start: () async => starts++,
      stop: () async => stops++,
      resolve: (s) => resolveCalls.add(s.name),
    );
  });

  tearDown(() => events.close());

  test('two resolves for the same host give one entry, first name wins',
      () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(_resolved('Nas B', hostname: 'nas.local.'));
    events.add(_resolved('Nas A', hostname: 'nas.local.'));
    await pumpEventQueue();
    expect(seen.last, [
      const DiscoveredSmbServer(name: 'Nas A', host: 'nas.local', port: 445),
    ]);
    await sub.cancel();
  });

  test('entries are sorted by name and a service without a host is ignored',
      () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(_resolved('Zed', hostname: 'z.local'));
    events.add(_resolved('Hostless'));
    events.add(_resolved('Alpha', hostname: 'a.local'));
    await pumpEventQueue();
    expect(seen.length, 2);
    expect(seen.last.map((s) => s.name), ['Alpha', 'Zed']);
    await sub.cancel();
  });

  test('a found event asks for a resolve', () async {
    final sub = discovery.browse().listen((_) {});
    await pumpEventQueue();
    events.add(BonsoirDiscoveryServiceFoundEvent(service: _svc('Nas')));
    await pumpEventQueue();
    expect(resolveCalls, ['Nas']);
    await sub.cancel();
  });

  test('a lost service removes it', () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(_resolved('Nas', hostname: 'nas.local'));
    await pumpEventQueue();
    expect(seen.last, hasLength(1));
    events.add(BonsoirDiscoveryServiceLostEvent(service: _svc('Nas')));
    await pumpEventQueue();
    expect(seen.last, isEmpty);
    await sub.cancel();
  });

  test('an error gives an empty list and is not thrown', () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add, onError: (_) {
      fail('error leaked to the listener');
    });
    await pumpEventQueue();
    events.add(_resolved('Nas', hostname: 'nas.local'));
    await pumpEventQueue();
    events.addError(StateError('local network denied'));
    await pumpEventQueue();
    expect(seen.last, isEmpty);
    await sub.cancel();
  });

  test('a failing start gives an empty list', () async {
    final failing = BonsoirSmbDiscovery.forTest(
      events.stream,
      start: () async => throw StateError('no multicast'),
    );
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = failing.browse().listen(seen.add);
    await pumpEventQueue();
    expect(seen, [isEmpty]);
    await sub.cancel();
  });

  test('cancelling the subscription stops the browse', () async {
    final sub = discovery.browse().listen((_) {});
    await pumpEventQueue();
    expect(starts, 1);
    expect(stops, 0);
    await sub.cancel();
    expect(stops, 1);
    expect(events.hasListener, isFalse);
  });
}
