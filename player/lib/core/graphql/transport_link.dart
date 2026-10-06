/// The legacy GraphQLClient's only link until stage 2: every operation goes
/// through one Mydia instance's MydiaClient, which owns the token, refresh,
/// device-profile header and transport.
library;

import 'package:graphql/client.dart';

import '../../domain/sources/source_error.dart';
import '../sources/mydia/mydia_client.dart';

class TransportLink extends Link {
  TransportLink(this._client);

  final Future<MydiaClient?> Function() _client;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    final client = await _client();
    if (client == null) {
      throw const ServerException(
          originalException: SourceException.unreachable());
    }
    try {
      final data =
          await client.request(request.operation.document, request.variables);
      yield Response(data: data, response: {'data': data});
    } on SourceException catch (e) {
      switch (e.kind) {
        case SourceErrorKind.unreachable:
          throw ServerException(originalException: e);
        case _:
          final message = e.message ?? e.viewerMessage;
          yield Response(
            errors: [GraphQLError(message: message)],
            response: {
              'errors': [
                {'message': message},
              ],
            },
          );
      }
    }
  }
}
