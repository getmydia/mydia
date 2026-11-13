/// Where each node of the Servers & devices diagram sits.
///
/// A fixed slot table rather than a computed ring: the same overview always
/// lands in the same places, so a server coming online or a device pairing
/// changes one node and never makes the rest jump.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'connections_overview.dart';

/// One node around this device in the diagram.
sealed class ConstellationNode {
  const ConstellationNode();
}

@immutable
final class ServerNode extends ConstellationNode {
  const ServerNode(this.server);
  final ConnectionServer server;

  @override
  bool operator ==(Object other) =>
      other is ServerNode && other.server == server;
  @override
  int get hashCode => Object.hash(ServerNode, server);
}

@immutable
final class DeviceNode extends ConstellationNode {
  const DeviceNode(this.device);
  final ConnectionDevice device;

  @override
  bool operator ==(Object other) =>
      other is DeviceNode && other.device == device;
  @override
  int get hashCode => Object.hash(DeviceNode, device);
}

/// Everything that did not get a slot of its own.
@immutable
final class MoreNode extends ConstellationNode {
  const MoreNode(this.count);
  final int count;

  @override
  bool operator ==(Object other) => other is MoreNode && other.count == count;
  @override
  int get hashCode => Object.hash(MoreNode, count);
}

/// The dashed "Add a server" placeholder.
final class GhostServerNode extends ConstellationNode {
  const GhostServerNode();
  @override
  bool operator ==(Object other) => other is GhostServerNode;
  @override
  int get hashCode => (GhostServerNode).hashCode;
}

/// The dashed "Pair a device" placeholder.
final class GhostDeviceNode extends ConstellationNode {
  const GhostDeviceNode();
  @override
  bool operator ==(Object other) => other is GhostDeviceNode;
  @override
  int get hashCode => (GhostDeviceNode).hashCode;
}

@immutable
class PlacedNode {
  const PlacedNode({required this.node, required this.center});

  final ConstellationNode node;

  /// In the diagram box's coordinates.
  final Offset center;

  @override
  bool operator ==(Object other) =>
      other is PlacedNode && other.node == node && other.center == center;
  @override
  int get hashCode => Object.hash(node, center);

  @override
  String toString() => 'PlacedNode(${node.runtimeType}, $center)';
}

/// This device, as a fraction of the diagram box.
const constellationCentre = Offset(0.5, 0.46);

const _serverSlots = [
  Offset(0.16, 0.21),
  Offset(0.84, 0.21),
  Offset(0.11, 0.68)
];
const _deviceSlots = [Offset(0.89, 0.68), Offset(0.5, 0.80)];

/// Places [servers] and [devices] in the slot table, scaled to [box].
///
/// Up to three servers and two devices get slots of their own, in table
/// order. Anything more collapses into one [MoreNode] in the last free slot
/// (server slots, then device slots); when none is free it takes the last
/// occupied one and counts what it displaced. With nothing to show, a ghost
/// node stands in: the server ghost only when [showServers].
List<PlacedNode> layoutConstellation({
  required List<ConnectionServer> servers,
  required List<ConnectionDevice> devices,
  required bool showServers,
  required Size box,
}) {
  final slots = [if (showServers) ..._serverSlots, ..._deviceSlots];
  final firstDevice = showServers ? _serverSlots.length : 0;
  final cells = List<ConstellationNode?>.filled(slots.length, null);
  var hidden = 0;

  if (showServers) {
    for (final (i, s) in servers.indexed) {
      if (i < _serverSlots.length) {
        cells[i] = ServerNode(s);
      } else {
        hidden++;
      }
    }
    if (servers.isEmpty) cells[0] = const GhostServerNode();
  }

  for (final (i, d) in devices.indexed) {
    if (i < _deviceSlots.length) {
      cells[firstDevice + i] = DeviceNode(d);
    } else {
      hidden++;
    }
  }
  if (devices.isEmpty) cells[firstDevice + 1] = const GhostDeviceNode();

  if (hidden > 0) {
    var at = cells.lastIndexWhere((c) => c == null);
    if (at < 0) {
      at = cells.length - 1;
      final displaced = cells[at];
      if (displaced is ServerNode || displaced is DeviceNode) hidden++;
    }
    cells[at] = MoreNode(hidden);
  }

  return [
    for (final (i, node) in cells.indexed)
      if (node != null)
        PlacedNode(
          node: node,
          center: Offset(slots[i].dx * box.width, slots[i].dy * box.height),
        ),
  ];
}
