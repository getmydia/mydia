/// Which servers a Home shows: every included server, or one.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';

@immutable
sealed class HomeScope {
  const HomeScope();

  /// The servers in scope, in the switcher's order. Watches, so a server
  /// joining or leaving the set rebuilds the caller.
  List<MediaSource> sources(Ref ref);
}

/// Every server included in All servers.
final class AllServers extends HomeScope {
  const AllServers();

  @override
  List<MediaSource> sources(Ref ref) => ref.watch(allServersSourcesProvider);

  @override
  bool operator ==(Object other) => other is AllServers;

  @override
  int get hashCode => (AllServers).hashCode;
}

/// One server, whether or not All servers includes it.
final class OneServer extends HomeScope {
  const OneServer(this.id);

  final SourceId id;

  @override
  List<MediaSource> sources(Ref ref) => [
        if (ref.watch(mediaSourceProvider(id)) case final source?) source,
      ];

  @override
  bool operator ==(Object other) => other is OneServer && other.id == id;

  @override
  int get hashCode => Object.hash(OneServer, id);
}
