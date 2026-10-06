/// Home Mydia's GraphQL as a [MydiaGqlTransport], for the All servers views.
/// Home's own client adds the token and refreshes it, so [send] ignores the
/// token it is handed.
library;

import 'package:graphql/client.dart';

import '../../../domain/sources/source_error.dart';
import '../media_source.dart';
import 'mydia_gql_transport.dart';

class HomeMydiaTransport implements MydiaGqlTransport {
  HomeMydiaTransport(this._client);

  final Future<GraphQLClient> Function() _client;

  @override
  SourceConnectionStatus get reachedVia => SourceConnectionStatus.remote;

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
  }) async {
    final GraphQLClient client;
    try {
      client = await _client();
    } catch (_) {
      // Signed out or still connecting: nothing to reach yet.
      throw const SourceException.unreachable();
    }
    final document = gql(query);
    final result = query.trimLeft().startsWith('mutation')
        ? await client.mutate(MutationOptions(
            document: document,
            variables: variables,
            fetchPolicy: FetchPolicy.noCache))
        : await client.query(QueryOptions(
            document: document,
            variables: variables,
            fetchPolicy: FetchPolicy.noCache));
    final exception = result.exception;
    if (exception != null) {
      if (exception.linkException != null) {
        throw const SourceException.unreachable();
      }
      final message = exception.graphqlErrors.firstOrNull?.message ?? '';
      if (isMydiaAuthError(message)) throw const SourceException.unauthorized();
      throw SourceException.server(message);
    }
    final data = result.data;
    if (data == null) {
      throw const SourceException.server('The server sent no data.');
    }
    return data;
  }
}
