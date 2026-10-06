/// What the Mydia session reads to set up streaming: the screen's
/// providers, passed as closures so the session stays testable without a
/// widget.
library;

import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../../core/connection/connection_provider.dart' as conn;
import '../../../../core/p2p/media_proxy.dart';
import '../../../../core/sources/mydia/mydia_client.dart';

class MydiaStreamingDeps {
  const MydiaStreamingDeps({
    required this.serverUrl,
    required this.authToken,
    required this.connection,
    required this.mediaProxy,
    required this.mediaToken,
    required this.adoptClient,
    required this.boundClient,
  });

  /// The bound Mydia instance's client, which progress reports go through.
  final MydiaClient? Function() boundClient;

  final Future<String?> Function() serverUrl;
  final Future<String?> Function() authToken;
  final conn.ConnectionState Function() connection;
  final MediaProxy Function() mediaProxy;
  final Future<String?> Function() mediaToken;

  /// Hands the resolved client to the screen, which must hold it before a
  /// session starts so `dispose` can end what it started.
  final void Function(GraphQLClient client) adoptClient;
}
