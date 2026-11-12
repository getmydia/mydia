import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/merged_roster.dart';
import 'package:player/core/remote/remote_roster.dart';
import 'package:player/core/sources/source.dart';

class _FakeRoster implements DeviceRoster {
  _FakeRoster(this.devices, {this.fails = false});

  final List<RemoteDeviceEntry> devices;
  final bool fails;

  @override
  Future<List<RemoteDeviceEntry>> entries() async {
    if (fails) throw StateError('roster down');
    return devices;
  }

  @override
  Future<List<RemoteDeviceEntry>> onlineEntries() async {
    if (fails) throw StateError('roster down');
    return devices;
  }

  @override
  Future<bool> allows(String peerNodeId) async {
    if (fails) throw StateError('roster down');
    return devices.any((d) => d.nodeId == peerNodeId);
  }
}

RemoteDeviceEntry _device(String id, String nodeId) => RemoteDeviceEntry(
      id: id,
      deviceName: 'Device $id',
      platform: 'linux',
      nodeId: nodeId,
    );

const _a = SourceId('mydia-a');
const _b = SourceId('mydia-b');

void main() {
  test('a device both instances know is listed once, by node id', () async {
    final merged = MergedRoster({
      _a: _FakeRoster([_device('a-1', 'N1')]),
      _b: _FakeRoster([_device('b-9', 'n1'), _device('b-2', 'N2')]),
    });

    final entries = await merged.entries();

    expect(entries.map((e) => e.nodeId.toLowerCase()), ['n1', 'n2']);
    expect(entries.first.id, 'a-1', reason: 'the first instance wins');
    expect(await merged.instancesOf('n1'), [_a, _b]);
    expect(await merged.instancesOf('N2'), [_b]);
    expect(await merged.instancesOf('other'), isEmpty);
  });

  test('a roster that throws contributes nothing', () async {
    final merged = MergedRoster({
      _a: _FakeRoster(const [], fails: true),
      _b: _FakeRoster([_device('b-1', 'N2')]),
    });

    expect((await merged.entries()).single.nodeId, 'N2');
    expect((await merged.onlineEntries()).single.nodeId, 'N2');
    expect(await merged.instancesOf('N2'), [_b]);
  });

  test('allows a peer any roster allows, and survives a failing one', () async {
    final merged = MergedRoster({
      _a: _FakeRoster(const [], fails: true),
      _b: _FakeRoster([_device('b-1', 'N2')]),
    });

    expect(await merged.allows('N2'), isTrue);
    expect(await merged.allows('stranger'), isFalse);
  });

  test('with no instances nothing is listed or allowed', () async {
    final merged = MergedRoster(const {});

    expect(await merged.entries(), isEmpty);
    expect(await merged.allows('N1'), isFalse);
  });

  test(
      'includes extra peer group roster in entries and allows without any mydia server',
      () async {
    final extraRoster = _FakeRoster([_device('extra-1', 'PEER-NODE-1')]);
    final merged = MergedRoster(const {}, extras: [extraRoster]);

    final entries = await merged.entries();
    expect(entries.map((e) => e.nodeId), ['PEER-NODE-1']);

    final online = await merged.onlineEntries();
    expect(online.map((e) => e.nodeId), ['PEER-NODE-1']);

    expect(await merged.allows('PEER-NODE-1'), isTrue);
    expect(await merged.allows('other'), isFalse);
    expect(await merged.instancesOf('PEER-NODE-1'), isEmpty,
        reason: 'instancesOf remains scoped to server rosters');
  });

  test(
      'deduplicates device present in both server roster and peer group roster',
      () async {
    final serverRoster = _FakeRoster([_device('srv-1', 'SHARED-NODE')]);
    final extraRoster = _FakeRoster([_device('extra-1', 'shared-node')]);

    final merged = MergedRoster(
      {_a: serverRoster},
      extras: [extraRoster],
    );

    final entries = await merged.entries();
    expect(entries.length, 1);
    expect(entries.first.id, 'srv-1',
        reason: 'server roster entry takes priority in deduplication');
    expect(entries.first.nodeId, 'SHARED-NODE');

    expect(await merged.instancesOf('shared-node'), [_a]);
    expect(await merged.allows('shared-node'), isTrue);
  });

  test('MergedRoster equality and hashCode include extras by identity', () {
    final r1 = _FakeRoster([_device('1', 'n1')]);
    final r2 = _FakeRoster([_device('2', 'n2')]);

    final m1 = MergedRoster({_a: r1}, extras: [r2]);
    final m2 = MergedRoster({_a: r1}, extras: [r2]);
    final r3 = _FakeRoster([_device('2', 'n2')]);
    final m3 = MergedRoster({_a: r1}, extras: [r3]);

    expect(m1 == m2, isTrue);
    expect(m1.hashCode, equals(m2.hashCode));
    expect(m1 == m3, isFalse);
  });
}
