/// One guest Mydia's requests, with its own token refresh.
library;

import 'package:flutter/foundation.dart';
import 'package:gql/ast.dart' show DocumentNode;
import 'package:gql/language.dart' show printNode;

import '../../../domain/sources/source_error.dart';
import '../media_source.dart';
import 'mydia_gql_transport.dart';
import 'mydia_guest_credentials.dart';

/// Unauthenticated on the server on purpose: the device token is the proof.
const _refreshMutation = r'''
mutation RefreshAccessToken($deviceToken: String!) {
  refreshAccessToken(deviceToken: $deviceToken) {
    token
    expiresAt
  }
}
''';

class MydiaGuestClient {
  MydiaGuestClient({
    required MydiaGqlTransport transport,
    required Future<MydiaGuestCredentials> Function() load,
    required Future<void> Function(MydiaGuestCredentials) save,
    required void Function() onUnauthorized,
  })  : _transport = transport,
        _load = load,
        _save = save,
        _onUnauthorized = onUnauthorized;

  final MydiaGqlTransport _transport;
  final Future<MydiaGuestCredentials> Function() _load;
  final Future<void> Function(MydiaGuestCredentials) _save;
  final void Function() _onUnauthorized;
  MydiaGuestCredentials? _credentials;
  Future<MydiaGuestCredentials>? _loading;
  Future<String?>? _refreshing;

  final ValueNotifier<SourceConnectionStatus> _status =
      ValueNotifier(SourceConnectionStatus.connecting);

  ValueListenable<SourceConnectionStatus> get status => _status;

  /// The current credentials, read from storage once. A failed read is not
  /// cached.
  Future<MydiaGuestCredentials> credentials() async {
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
    final current = await credentials();
    try {
      return await _send(query, variables, current.accessToken);
    } on SourceException catch (e) {
      if (e.kind != SourceErrorKind.unauthorized) rethrow;
      final fresh = await (_refreshing ??=
          _refresh().whenComplete(() => _refreshing = null));
      if (fresh == null) {
        _onUnauthorized();
        rethrow;
      }
      return _send(query, variables, fresh);
    }
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

  /// A fresh access token, or null when this device cannot get one itself.
  Future<String?> _refresh() async {
    final current = await credentials();
    final deviceToken = current.deviceToken;
    if (deviceToken == null) return null;
    try {
      final data =
          await _transport.send(_refreshMutation, {'deviceToken': deviceToken});
      final token = (data['refreshAccessToken'] as Map?)?['token'];
      if (token is! String || token.isEmpty) return null;
      final next = current.copyWith(accessToken: token);
      _credentials = next;
      await _save(next);
      return token;
    } on SourceException {
      return null;
    }
  }

  void dispose() => _status.dispose();
}
