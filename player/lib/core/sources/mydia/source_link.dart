/// How a Mydia source is reached, read from the source's own credentials.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/sources/source_error.dart';
import '../source.dart';
import '../sources_providers.dart';
import 'mydia_credentials.dart';
import 'mydia_source.dart';

/// The credentials of Mydia source [id], or null for a third-party source, a
/// missing one, or credentials that cannot be read.
Future<MydiaCredentials?> _credentialsOf(Ref ref, SourceId id) async {
  final source = ref.watch(mediaSourceProvider(id));
  if (source is! MydiaSource) return null;
  try {
    return await source.client.credentials();
  } on SourceException {
    return null;
  }
}

/// Whether Mydia source [id] is reached over p2p. False for a third-party
/// source, a missing one, or unreadable credentials.
final sourceViaP2pProvider =
    FutureProvider.family<bool, SourceId>((ref, id) async {
  return (await _credentialsOf(ref, id))?.isP2p ?? false;
});

/// The direct URL of Mydia source [id], for diagnostics. Null over p2p.
final sourceServerUrlProvider =
    FutureProvider.family<String?, SourceId>((ref, id) async {
  return (await _credentialsOf(ref, id))?.serverUrl;
});
