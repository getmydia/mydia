import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../graphql/queries/server_compatibility.graphql.dart';
import 'compatibility_verdict.dart';

/// Asks the connected server what player versions it supports.
///
/// The query rides the ordinary GraphQL client, which already routes over HTTP
/// or the p2p tunnel depending on the connection. That is why this is a GraphQL
/// query and not a REST call: `/health` would publish the same numbers but
/// cannot traverse p2p, and remote sessions are the ones most likely to be
/// running a stale player.
///
/// Every failure returns null. Callers turn that into
/// [CompatibilityVerdict.unknown] and render nothing.
class CompatibilityService {
  final GraphQLClient? _client;

  const CompatibilityService(this._client);

  /// Fetches the server's compatibility declaration, or null if we cannot tell.
  ///
  /// Null covers all of: no client yet, a transport failure, and a GraphQL
  /// validation error. That last one is how a server released before this
  /// feature answers, since GraphQL rejects an entire document that names an
  /// unknown field.
  Future<ServerCompatibilityInfo?> fetch() async {
    final client = _client;
    if (client == null) return null;

    try {
      final result = await client.query(
        QueryOptions(
          document: documentNodeQueryServerCompatibility,
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      if (result.hasException) {
        debugPrint('[CompatibilityService] ${result.exception}');
        return null;
      }

      final data = result.data;
      if (data == null) return null;

      final compat =
          Query$ServerCompatibility.fromJson(data).serverCompatibility;
      if (compat == null) return null;

      return ServerCompatibilityInfo(
        version: compat.version,
        minPlayerVersion: compat.minPlayerVersion,
        recommendedPlayerVersion: compat.recommendedPlayerVersion,
      );
    } catch (e) {
      debugPrint('[CompatibilityService] fetch failed: $e');
      return null;
    }
  }
}
