/// A Mydia server's credentials, kept as JSON in its account token.
library;

import 'dart:convert';

import '../source.dart';
import '../store/source_records.dart';
import '../store/source_secrets.dart';
import 'mydia_credentials.dart';

/// Null when nothing is stored or the stored value is not credentials.
Future<MydiaCredentials?> readMydiaCredentials(
  SourceSecrets secrets,
  ProviderAccount account,
) async {
  final raw = await secrets.accountToken(account);
  if (raw == null) return null;
  try {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) return null;
    return MydiaCredentials.fromJson(json);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

Future<void> writeMydiaCredentials(
  SourceSecrets secrets,
  ProviderAccount account,
  MydiaCredentials c,
) =>
    secrets.writeAccountToken(account, jsonEncode(c.toJson()));

/// The stored Mydia account for the server named by any of [instanceId],
/// [nodeId] or [url], or null. A stored URL that cannot be normalized counts
/// as no match rather than failing the lookup.
Future<ProviderAccount?> findMatchingMydiaAccount(
  SourceSnapshot snapshot,
  SourceSecrets secrets, {
  String? instanceId,
  String? nodeId,
  String? url,
}) async {
  final wantedUrl = url == null ? null : _normalizedOrNull(url);
  for (final record in snapshot.accounts) {
    final account = record.account;
    if (account.kind != SourceKind.mydia) continue;
    final theirs = await readMydiaCredentials(secrets, account);
    if (theirs == null) continue;
    final theirUrl = theirs.serverUrl;
    final sameUrl = wantedUrl != null &&
        theirUrl != null &&
        _normalizedOrNull(theirUrl) == wantedUrl;
    if ((instanceId != null &&
            instanceId.isNotEmpty &&
            theirs.instanceId == instanceId) ||
        (nodeId != null && theirs.nodeId == nodeId) ||
        sameUrl) {
      return account;
    }
  }
  return null;
}

String? _normalizedOrNull(String url) {
  try {
    return normalizeMydiaUrl(url);
  } on FormatException {
    return null;
  }
}
