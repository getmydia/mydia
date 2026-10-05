/// A Mydia server's credentials, kept as JSON in its account token.
library;

import 'dart:convert';

import '../source.dart';
import '../store/source_secrets.dart';
import 'mydia_credentials.dart';

/// A Mydia source other than the home login, which keeps its own storage.
bool isStandaloneMydia(Source s) =>
    s.kind == SourceKind.mydia && s.id != SourceId.legacyMydia;

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
