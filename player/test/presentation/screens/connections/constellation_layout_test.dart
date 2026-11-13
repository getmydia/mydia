import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';
import 'package:player/presentation/screens/connections/constellation_layout.dart';

const _box = Size(320, 250);

ConnectionServer _server(String id) => ConnectionServer(
      record: SourceAccountRecord(
        account: ProviderAccount(
          id: id,
          kind: SourceKind.mydia,
          displayName: 'Home Mydia',
          storageNamespace: 'source/$id',
          activeProfileId: 'owner',
        ),
        profiles: const [],
        servers: const [],
        addedAtMs: 0,
      ),
      kind: SourceKind.mydia,
      name: 'Home Mydia $id',
      host: null,
      serverCount: 1,
      status: ConnectionStatus.online,
      locked: false,
      inAllServers: true,
    );

ConnectionDevice _device(String id) => ConnectionDevice(
    nodeId: id, name: 'Pixel phone', platform: 'android', lastSyncedAt: null);

Offset _at(double x, double y) => Offset(x * _box.width, y * _box.height);

void main() {
  test('empty shows both ghosts', () {
    final placed = layoutConstellation(
        servers: const [], devices: const [], showServers: true, box: _box);
    expect(placed, hasLength(2));
    expect(placed[0].node, isA<GhostServerNode>());
    expect(placed[0].center, _at(0.16, 0.21));
    expect(placed[1].node, isA<GhostDeviceNode>());
    expect(placed[1].center, _at(0.5, 0.80));
  });

  test('two servers one device use slots in order', () {
    final a = _server('a');
    final b = _server('b');
    final d = _device('d');
    final placed = layoutConstellation(
        servers: [a, b], devices: [d], showServers: true, box: _box);
    expect(placed.map((p) => p.node), [
      ServerNode(a),
      ServerNode(b),
      DeviceNode(d),
    ]);
    expect(placed.map((p) => p.center), [
      _at(0.16, 0.21),
      _at(0.84, 0.21),
      _at(0.89, 0.68),
    ]);
  });

  test('overflow collapses into a single +N node', () {
    final servers = [for (var i = 0; i < 5; i++) _server('s$i')];
    final devices = [for (var i = 0; i < 3; i++) _device('d$i')];
    final placed = layoutConstellation(
        servers: servers, devices: devices, showServers: true, box: _box);
    expect(placed, hasLength(5));
    expect(placed.where((p) => p.node is ServerNode), hasLength(3));
    expect(placed.where((p) => p.node is DeviceNode), hasLength(1));
    final more = placed.singleWhere((p) => p.node is MoreNode);
    expect(more.node, const MoreNode(4));
    expect(more.center, _at(0.5, 0.80));
  });

  test('no two nodes share a centre', () {
    for (var s = 0; s <= 5; s++) {
      for (var d = 0; d <= 4; d++) {
        for (final show in [true, false]) {
          final placed = layoutConstellation(
            servers: [for (var i = 0; i < s; i++) _server('s$i')],
            devices: [for (var i = 0; i < d; i++) _device('d$i')],
            showServers: show,
            box: _box,
          );
          final centres = placed.map((p) => p.center).toList();
          expect(centres.toSet(), hasLength(centres.length),
              reason: '$s servers, $d devices, showServers $show');
          expect(centres, isNot(contains(_at(0.5, 0.46))), // the centre node
              reason: '$s servers, $d devices, showServers $show');
        }
      }
    }
  });

  test('showServers false places devices only and no server ghost', () {
    final placed = layoutConstellation(
        servers: [_server('a'), _server('b')],
        devices: [_device('d')],
        showServers: false,
        box: _box);
    expect(placed.map((p) => p.node), [DeviceNode(_device('d'))]);
    expect(placed.single.center, _at(0.89, 0.68));

    final empty = layoutConstellation(
        servers: const [], devices: const [], showServers: false, box: _box);
    expect(empty.map((p) => p.node), [const GhostDeviceNode()]);
  });
}
