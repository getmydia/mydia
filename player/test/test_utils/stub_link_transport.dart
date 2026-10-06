import 'package:gql/language.dart' show parseString;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_gql_transport.dart';
import 'package:player/domain/sources/source_error.dart';

/// A [MydiaGqlTransport] that answers from a [StubLink], so a screen test that
/// scripts its server as a link also scripts what the bound `MydiaClient`
/// sends. Every request lands in `link.requests`.
class StubLinkTransport implements MydiaGqlTransport {
  StubLinkTransport(this.link);

  final Link link;

  @override
  SourceConnectionStatus get reachedVia => SourceConnectionStatus.remote;

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
  }) async {
    final request = Request(
      operation: Operation(document: parseString(query)),
      variables: variables,
    );
    final Response response;
    try {
      response = await link.request(request).first;
    } on Exception {
      throw const SourceException.unreachable();
    }
    final errors = response.errors;
    if (errors != null && errors.isNotEmpty) {
      throw SourceException.server(errors.first.message);
    }
    return response.data ?? const {};
  }
}
