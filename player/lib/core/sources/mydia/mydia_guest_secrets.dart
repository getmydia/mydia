/// A guest Mydia's credentials, kept as JSON in its account token.
library;

import 'dart:convert';

import '../source.dart';
import '../store/source_secrets.dart';
import 'mydia_guest_credentials.dart';

/// A Mydia source other than the home login, which keeps its own storage.
bool isGuestMydia(Source s) =>
    s.kind == SourceKind.mydia && s.id != SourceId.legacyMydia;

/// Null when nothing is stored or the stored value is not credentials.
Future<MydiaGuestCredentials?> readGuestCredentials(
  SourceSecrets secrets,
  ProviderAccount account,
) async {
  final raw = await secrets.accountToken(account);
  if (raw == null) return null;
  try {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) return null;
    return MydiaGuestCredentials.fromJson(json);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

Future<void> writeGuestCredentials(
  SourceSecrets secrets,
  ProviderAccount account,
  MydiaGuestCredentials c,
) =>
    secrets.writeAccountToken(account, jsonEncode(c.toJson()));
