/// Features learned about the connected server.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/connection_provider.dart';

class ServerFeatures {
  bool heightCap = true;
}

/// Learned capabilities belong to one connection, rather than this app's
/// root provider scope. A reconnect creates a fresh feature set so it can
/// negotiate the current server's caps and playlist mode again.
final serverFeaturesProvider = Provider<ServerFeatures>((ref) {
  ref.watch(connectionProvider);
  return ServerFeatures();
});
