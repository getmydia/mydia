/// A Mydia server's requests, with its own token refresh.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gql/ast.dart' show DocumentNode, OperationDefinitionNode;
import 'package:gql/language.dart' show printNode;

import '../../../domain/sources/source_error.dart';
import '../../../graphql/mutations/refresh_access_token.graphql.dart';
import '../../../graphql/mutations/refresh_media_token.graphql.dart';
import '../../../graphql/queries/server_compatibility.graphql.dart';
import '../../compatibility/compatibility_verdict.dart';
import '../../player/device_profile.dart';
import '../media_source.dart';
import 'mydia_credentials.dart';
import 'mydia_gql_transport.dart';
import 'schema_downgrade.dart';

typedef GetDeviceProfile = FutureOr<DeviceProfile?> Function();

class MydiaClient {
  MydiaClient({
    required MydiaGqlTransport transport,
    required Future<MydiaCredentials> Function() load,
    required Future<void> Function(MydiaCredentials) save,
    required void Function() onUnauthorized,
    GetDeviceProfile? getDeviceProfile,
  })  : _transport = transport,
        _load = load,
        _save = save,
        _onUnauthorized = onUnauthorized,
        _getDeviceProfile = getDeviceProfile;

  final MydiaGqlTransport _transport;
  final Future<MydiaCredentials> Function() _load;
  final Future<void> Function(MydiaCredentials) _save;
  final void Function() _onUnauthorized;
  final GetDeviceProfile? _getDeviceProfile;
  MydiaCredentials? _credentials;
  Future<MydiaCredentials>? _loading;
  Future<String?>? _refreshing;
  Future<String?>? _mediaTokenRefreshing;

  static const mediaTokenRefreshThresholdSeconds = 3600;

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
    final profile = await _getDeviceProfile?.call();
    final headerValue = profile?.toHeaderValue();
    try {
      return await _send(query, variables, sentWith,
          deviceProfile: headerValue);
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
        rethrow;
      }
      try {
        return await _send(query, variables, fresh, deviceProfile: headerValue);
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

  /// Ensures that a valid media token exists, proactively refreshing it if it
  /// is within 1 hour of expiry.
  Future<String?> ensureValidMediaToken() async {
    final current = await credentials();
    final mediaToken = current.mediaToken;
    if (mediaToken == null) return null;

    final expiry = current.mediaTokenExpiry;
    final needsRefresh = expiry == null ||
        expiry.difference(DateTime.now()).inSeconds <=
            mediaTokenRefreshThresholdSeconds;

    if (!needsRefresh) {
      return mediaToken;
    }

    final inFlight = _mediaTokenRefreshing;
    if (inFlight != null) return inFlight;

    return _mediaTokenRefreshing =
        _refreshMediaToken(current, mediaToken, expiry)
            .whenComplete(() => _mediaTokenRefreshing = null);
  }

  /// Build a media URL with authentication query parameter if a media token
  /// exists.
  Future<String> buildMediaUrl(String baseUrl, String path) async {
    final token = await ensureValidMediaToken();
    if (token == null) {
      return '$baseUrl$path';
    }
    final separator = path.contains('?') ? '&' : '?';
    return '$baseUrl$path${separator}token=$token';
  }

  /// Fetches the server's compatibility declaration, or null if we cannot tell.
  ///
  /// Returns null on older servers predating this feature, an absent declaration,
  /// or any transport/parsing failure.
  Future<ServerCompatibilityInfo?> fetchCompatibility() async {
    try {
      final data = await request(documentNodeQueryServerCompatibility);
      final rawCompat = data['serverCompatibility'];
      if (rawCompat is! Map) return null;

      final compatMap = Map<String, dynamic>.from(rawCompat);
      final payload = <String, dynamic>{
        '__typename': data['__typename'] ?? 'RootQueryType',
        'serverCompatibility': {
          '__typename': 'ServerCompatibility',
          ...compatMap,
        },
      };

      final compat =
          Query$ServerCompatibility.fromJson(payload).serverCompatibility;
      if (compat == null) return null;

      return ServerCompatibilityInfo(
        version: compat.version,
        minPlayerVersion: compat.minPlayerVersion,
        recommendedPlayerVersion: compat.recommendedPlayerVersion,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _send(
    String query,
    Map<String, dynamic> variables,
    String? token, {
    String? deviceProfile,
  }) async {
    try {
      final data = await _transport.send(query, variables,
          token: token, deviceProfile: deviceProfile);
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
    if (deviceToken == null) {
      _onUnauthorized();
      return null;
    }
    final Map<String, dynamic> data;
    try {
      data = await _send(
        printNode(documentNodeMutationRefreshAccessToken),
        Variables$Mutation$RefreshAccessToken(deviceToken: deviceToken)
            .toJson(),
        null,
      );
    } on SourceException catch (e) {
      // The server answers a revoked or unknown device token with a plain
      // GraphQL error, so any answer other than "could not reach it" means
      // this device cannot re-authenticate.
      if (e.kind == SourceErrorKind.unreachable) rethrow;
      _onUnauthorized();
      return null;
    }
    final token = (data['refreshAccessToken'] as Map?)?['token'];
    if (token is! String || token.isEmpty) {
      _onUnauthorized();
      return null;
    }
    final next = current.copyWith(accessToken: token);
    _credentials = next;
    await _save(next);
    return token;
  }

  Future<String?> _refreshMediaToken(
    MydiaCredentials current,
    String mediaToken,
    DateTime? expiry,
  ) async {
    try {
      final data = await request(
        documentNodeMutationRefreshMediaToken,
        Variables$Mutation$RefreshMediaToken(token: mediaToken).toJson(),
      );
      final payload = data['__typename'] != null
          ? data
          : {...data, '__typename': 'RootMutationType'};
      final refreshed =
          Mutation$RefreshMediaToken.fromJson(payload).refreshMediaToken;
      if (refreshed != null) {
        final expiresAt = DateTime.tryParse(refreshed.expiresAt);
        final latest = _credentials ?? await credentials();
        final next = latest.copyWith(
          mediaToken: refreshed.token,
          mediaTokenExpiry: expiresAt,
        );
        _credentials = next;
        await _save(next);
        return refreshed.token;
      }
    } catch (_) {
      // If mutation fails or throws, returns existing token if not expired, or null.
    }

    if (expiry == null || expiry.isAfter(DateTime.now())) {
      return mediaToken;
    }
    return null;
  }

  void dispose() => _status.dispose();
}
