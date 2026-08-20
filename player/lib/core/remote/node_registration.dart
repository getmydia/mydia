import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';

/// Tells the server which iroh node ID this device is currently reachable at.
///
/// Runs on every app start rather than only at pairing. A device that
/// regenerated its keypair would otherwise sit in the roster under an address
/// nobody can reach, which reads to a controller as permanently offline.
class NodeRegistration {
  final GraphQLClient _client;
  final Future<String?> Function() _nodeId;

  NodeRegistration({
    required GraphQLClient client,
    required Future<String?> Function() nodeId,
  })  : _client = client,
        _nodeId = nodeId;

  static const _mutation = r'''
    mutation RegisterDeviceNode($nodeId: String!) {
      registerDeviceNode(nodeId: $nodeId) {
        __typename
        id
        nodeId
      }
    }
  ''';

  /// Whether the server now knows where to reach this device.
  ///
  /// Never throws. A player that cannot register is merely uncontrollable,
  /// which is a normal state for the web build and for anyone who turned the
  /// setting off, so it must not take down startup.
  Future<bool> register() async {
    final id = await _nodeId();
    if (id == null || id.isEmpty) return false;

    try {
      final result = await _client.mutate(
        MutationOptions(
          document: gql(_mutation),
          variables: {'nodeId': id},
          fetchPolicy: FetchPolicy.noCache,
        ),
      );

      if (result.hasException) {
        debugPrint('[NodeRegistration] failed: ${result.exception}');
        return false;
      }

      return result.data?['registerDeviceNode']?['nodeId'] == id;
    } catch (error) {
      debugPrint('[NodeRegistration] threw: $error');
      return false;
    }
  }
}
