import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/sources/source_error.dart';
import '../../graphql/mutations/register_device_node.graphql.dart';
import '../sources/mydia/mydia_client.dart';

/// Tells the server which iroh node ID this device is currently reachable at.
///
/// Runs on every app start rather than only at pairing. A device that
/// regenerated its keypair would otherwise sit in the roster under an address
/// nobody can reach, which reads to a controller as permanently offline.
class NodeRegistration {
  final MydiaClient _client;
  final Future<String?> Function() _nodeId;

  NodeRegistration({
    required MydiaClient client,
    required Future<String?> Function() nodeId,
  })  : _client = client,
        _nodeId = nodeId;

  /// Whether the server now knows where to reach this device.
  ///
  /// Never throws. A player that cannot register is merely uncontrollable,
  /// which is a normal state for the web build and for anyone who turned the
  /// setting off, so it must not take down startup.
  Future<bool> register() async {
    try {
      final id = await _nodeId();
      if (id == null || id.isEmpty) return false;

      final data = await _client.request(
        documentNodeMutationRegisterDeviceNode,
        Variables$Mutation$RegisterDeviceNode(nodeId: id).toJson(),
      );

      final registered = data['registerDeviceNode'] as Map<String, Object?>?;
      return registered?['nodeId'] == id;
    } on SourceException catch (error) {
      debugPrint('[NodeRegistration] failed: $error');
      return false;
    } catch (error) {
      debugPrint('[NodeRegistration] threw: $error');
      return false;
    }
  }
}
