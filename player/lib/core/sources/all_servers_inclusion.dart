/// Which servers the All servers views read.
library;

import 'source.dart';

/// A stored choice, or the kind's default: every kind but Stash, whose
/// scenes have no movie or show identity to sit beside the others.
bool includedInAllServers(Source source, Map<SourceId, bool> choices) =>
    choices[source.id] ?? source.kind != SourceKind.stash;

/// The [sources] All servers reads: included by [choices], not locked away
/// ([gated]) and not waiting to sign in again.
List<Source> allServersIncluded(
  List<Source> sources,
  Map<SourceId, bool> choices,
  Set<SourceId> gated,
) =>
    [
      for (final s in sources)
        if (!s.account.needsReauth &&
            !gated.contains(s.id) &&
            includedInAllServers(s, choices))
          s,
    ];
