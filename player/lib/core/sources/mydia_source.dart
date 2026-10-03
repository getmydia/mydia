/// The Mydia login `AuthService` already holds, as a [MediaSource].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_status.dart';
import 'media_source.dart';
import 'source.dart';

class MydiaSource extends MediaSource {
  const MydiaSource({required this.source, required this.auth});

  @override
  final Source source;

  final AsyncValue<AuthStatus> auth;

  /// Empty on purpose. Mydia's screens predate this layer and consult
  /// nothing here; capabilities are declared as its controllers move
  /// behind [MediaSource].
  @override
  Set<SourceCapability> get capabilities => const {};

  /// Reachable Mydia reports [SourceConnectionStatus.remote]: the existing
  /// connection layer does not distinguish a LAN route from a remote one.
  @override
  SourceConnectionStatus get connection => switch (auth) {
        AsyncData(value: AuthStatus.authenticated) =>
          SourceConnectionStatus.remote,
        AsyncData() => SourceConnectionStatus.unreachable,
        AsyncError() => SourceConnectionStatus.unreachable,
        _ => SourceConnectionStatus.connecting,
      };

  @override
  T? as<T extends Object>() => null;
}
