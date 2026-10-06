/// The Mydia server instance id carried in account and source ids.
///
/// A Mydia account is `m<instanceId>` and its source is
/// `m<instanceId>:owner:<instanceId>` (see `lib/core/sources/README.md`), so
/// the instance id is recoverable from either without reading credentials.
library;

import '../source.dart';

const _mydiaAccountPrefix = 'm';

/// The instance id of Mydia account [accountId], or null when it is not one.
String? mydiaInstanceIdOfAccount(String? accountId) {
  if (accountId == null || !accountId.startsWith(_mydiaAccountPrefix)) {
    return null;
  }
  final id = accountId.substring(_mydiaAccountPrefix.length);
  return id.isEmpty ? null : id;
}

/// The instance id of the Mydia server [source] belongs to, or null when it
/// is not a Mydia source id.
String? mydiaInstanceIdOfSource(SourceId source) =>
    mydiaInstanceIdOfAccount(source.value.split(':').first);
