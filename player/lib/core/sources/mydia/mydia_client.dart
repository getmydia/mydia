/// A Mydia server's requests, with its own token refresh.
library;

import 'package:flutter/foundation.dart';
import 'package:gql/ast.dart' show DocumentNode, OperationDefinitionNode;
import 'package:gql/language.dart' show printNode;

import '../../../domain/sources/source_error.dart';
import '../media_source.dart';
import 'mydia_credentials.dart';
import 'mydia_gql_transport.dart';
import 'schema_downgrade.dart';

/// Unauthenticated on the server on purpose: the device token is the proof.
const _refreshMutation = r'''
mutation RefreshAccessToken($deviceToken: String!) {
  refreshAccessToken(deviceToken: $deviceToken) {
    token
    expiresAt
  }
}
''';

class MydiaClient {
  MydiaClient({
    required MydiaGqlTransport transport,
    required Future<MydiaCredentials> Function() load,
    required Future<void> Function(MydiaCredentials) save,
    required void Function() onUnauthorized,
  })  : _transport = transport,
        _load = load,
        _save = save,
        _onUnauthorized = onUnauthorized;

  final MydiaGqlTransport _transport;
  final Future<MydiaCredentials> Function() _load;
  final Future<void> Function(MydiaCredentials) _save;
  final void Function() _onUnauthorized;
  MydiaCredentials? _credentials;
  Future<MydiaCredentials>? _loading;
  Future<String?>? _refreshing;

  final ValueNotifier<SourceConnectionStatus> _status =
      ValueNotifier(SourceConnectionStatus.connecting);

  ValueListenable<SourceConnectionStatus> get status => _status;

  /// The current credentials, read from storage once. A failed read is not
  /// cached.
  Future<MydiaCredentials> credentials() async {
    final known = _credentials;
    if (known != null) return known;
    final loading = _loading ??= _load().whenComplete(() => _loading = null);
    return _credentials = await loading;
  }

  Future<Map<String, dynamic>> request(
    DocumentNode document, [
    Map<String, dynamic> variables = const {},
  ]) async {
    final query = printNode(document);
    final sentWith = (await credentials()).accessToken;
    try {
      return await _send(query, variables, sentWith);
    } on SourceException catch (e) {
      if (e.kind != SourceErrorKind.unauthorized) rethrow;
      // A refresh may have finished while this request was in flight.
      final latest = _credentials?.accessToken;
      final String? fresh;
      if (latest != null && latest != sentWith) {
        fresh = latest;
      } else {
        fresh = await (_refreshing ??=
            _refresh().whenComplete(() => _refreshing = null));
      }
      if (fresh == null) {
        _onUnauthorized();
        rethrow;
      }
      try {
        return await _send(query, variables, fresh);
      } on SourceException catch (retry) {
        if (retry.kind == SourceErrorKind.unauthorized) _onUnauthorized();
        rethrow;
      }
    }
  }

  final Set<String> _downgradedOps = {};

  Future<Map<String, dynamic>> query(
    DocumentNode document, {
    DocumentNode? fallback,
    Map<String, dynamic> variables = const {},
  }) async {
    final opName = _operationName(document);
    if (fallback != null && opName != null && _downgradedOps.contains(opName)) {
      return request(fallback, variables);
    }

    try {
      return await request(document, variables);
    } catch (e) {
      if (fallback != null && isUnknownFieldError(e)) {
        if (opName != null) _downgradedOps.add(opName);
        return request(fallback, variables);
      }
      rethrow;
    }
  }

  static String? _operationName(DocumentNode document) {
    return document.definitions
        .whereType<OperationDefinitionNode>()
        .firstOrNull
        ?.name
        ?.value;
  }

  Future<Map<String, dynamic>> _send(
      String query, Map<String, dynamic> variables, String? token) async {
    try {
      final data = await _transport.send(query, variables, token: token);
      _status.value = _transport.reachedVia;
      return data;
    } on SourceException catch (e) {
      if (e.kind == SourceErrorKind.unreachable) {
        _status.value = SourceConnectionStatus.unreachable;
      }
      rethrow;
    }
  }

  /// A fresh access token, or null when this device cannot re-authenticate
  /// (no device token, the server refused it, or it answered with no token).
  /// An unreachable server propagates, so a flaky network never flags the
  /// account.
  Future<String?> _refresh() async {
    final current = await credentials();
    final deviceToken = current.deviceToken;
    if (deviceToken == null) return null;
    final Map<String, dynamic> data;
    try {
      data = await _send(_refreshMutation, {'deviceToken': deviceToken}, null);
    } on SourceException catch (e) {
      // The server answers a revoked or unknown device token with a plain
      // GraphQL error, so any answer other than "could not reach it" means
      // this device cannot re-authenticate.
      if (e.kind == SourceErrorKind.unreachable) rethrow;
      return null;
    }
    final token = (data['refreshAccessToken'] as Map?)?['token'];
    if (token is! String || token.isEmpty) return null;
    final next = current.copyWith(accessToken: token);
    _credentials = next;
    await _save(next);
    return token;
  }

  void dispose() => _status.dispose();
}
