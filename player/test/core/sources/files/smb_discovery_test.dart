import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/smb_discovery.dart';

BonsoirService _svc(
  String name, {
  String? hostname,
  List<String> addresses = const [],
  int port = 445,
}) =>
    BonsoirService(
      name: name,
      type: '_smb._tcp',
      port: port,
      hostname: hostname,
      hostAddresses: addresses,
    );

BonsoirDiscoveryEvent _resolved(
  String name, {
  String? hostname,
  List<String> addresses = const [],
}) =>
    BonsoirDiscoveryServiceResolvedEvent(
        service: _svc(name, hostname: hostname, addresses: addresses));

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
      resolve: (s) async => resolveCalls.add(s.name),
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
      const DiscoveredSmbServer(
        name: 'Nas A',
        host: 'nas.local',
        port: 445,
        hostname: 'nas.local',
      ),
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

  Future<String> hostFor(
      {String? hostname, List<String> addresses = const []}) async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(_resolved('Nas', hostname: hostname, addresses: addresses));
    await pumpEventQueue();
    await sub.cancel();
    return seen.last.single.host;
  }

  test('an IPv4 address is preferred over the .local hostname', () async {
    expect(
      await hostFor(
        hostname: 'nas.local.',
        addresses: ['fe80::1', '192.168.1.20', '10.0.0.5'],
      ),
      '192.168.1.20',
    );
  });

  test('a link-local-only IPv6 service falls back to the hostname', () async {
    expect(
      await hostFor(hostname: 'nas.local.', addresses: ['fe80::abcd']),
      'nas.local',
    );
  });

  test('resolved_service_exposes_hostname_alongside_addresses', () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(
        _resolved('Nas', hostname: 'NAS.local.', addresses: ['192.168.1.5']));
    await pumpEventQueue();
    await sub.cancel();
    final server = seen.last.single;
    expect(server.host, '192.168.1.5');
    expect(server.hostname, 'nas.local');
  });

  test('a global IPv6-only service uses that address', () async {
    expect(
      await hostFor(
        hostname: 'nas.local',
        addresses: ['fe80::abcd', '2001:db8::7'],
      ),
      '2001:db8::7',
    );
  });

  test('de-duplication keys on the chosen address', () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(_resolved('B', hostname: 'b.local', addresses: ['10.0.0.9']));
    events.add(_resolved('A', hostname: 'a.local', addresses: ['10.0.0.9']));
    await pumpEventQueue();
    expect(seen.last.map((s) => s.name), ['A']);
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

  test('every usable address is kept, best first', () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(_resolved('Nas', hostname: 'nas.local', addresses: [
      '2001:db8::7',
      '172.17.0.1',
      'fe80::1',
      '192.168.1.20',
    ]));
    await pumpEventQueue();
    final server = seen.last.single;
    expect(server.host, '172.17.0.1');
    expect(server.addresses, ['172.17.0.1', '192.168.1.20', '2001:db8::7']);
    await sub.cancel();
  });

  test('services on one host but different ports are both listed', () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(BonsoirDiscoveryServiceResolvedEvent(
        service: _svc('A', addresses: ['10.0.0.9'])));
    events.add(BonsoirDiscoveryServiceResolvedEvent(
        service: _svc('B', addresses: ['10.0.0.9'], port: 4455)));
    await pumpEventQueue();
    expect(seen.last.map((s) => (s.name, s.port)), [('A', 445), ('B', 4455)]);
    await sub.cancel();
  });

  test('servers sharing only their first address are both listed', () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(_resolved('A', addresses: ['172.17.0.1', '192.168.1.20']));
    events.add(_resolved('B', addresses: ['172.17.0.1', '192.168.1.30']));
    await pumpEventQueue();
    expect(seen.last.map((s) => '${s.name} ${s.addresses.join(',')}'), [
      'A 172.17.0.1,192.168.1.20',
      'B 172.17.0.1,192.168.1.30',
    ]);
    await sub.cancel();
  });

  test('servers told apart only by link-local IPv6 are both listed', () async {
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = discovery.browse().listen(seen.add);
    await pumpEventQueue();
    events.add(_resolved('A', addresses: ['172.17.0.1', 'fe80::a']));
    events.add(_resolved('B', addresses: ['172.17.0.1', 'fe80::b']));
    events.add(_resolved('A again', addresses: ['fe80::a', '172.17.0.1']));
    await pumpEventQueue();
    expect(seen.last.map((s) => '${s.name} ${s.addresses.join(',')}'), [
      'A 172.17.0.1',
      'B 172.17.0.1',
    ]);
    await sub.cancel();
  });

  test('a failed resolve is contained and the browse carries on', () async {
    final failing = BonsoirSmbDiscovery.forTest(
      events.stream,
      resolve: (s) async => throw StateError('avahi refused ${s.name}'),
    );
    final seen = <List<DiscoveredSmbServer>>[];
    final sub = failing.browse().listen(seen.add, onError: (_) {
      fail('error leaked to the listener');
    });
    await pumpEventQueue();
    events.add(_resolved('Other', hostname: 'other.local'));
    events.add(BonsoirDiscoveryServiceFoundEvent(service: _svc('Nas')));
    await pumpEventQueue();
    expect(seen.last.map((s) => s.name), ['Other']);
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
