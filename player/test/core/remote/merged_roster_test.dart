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
}
