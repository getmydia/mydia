/// Which servers the All servers views read.
library;

import 'source.dart';

/// A stored choice, or the kind's default: every kind but Stash, whose
/// scenes have no movie or show identity to sit beside the others.
bool includedInAllServers(Source source, Map<SourceId, bool> choices) =>
    choices[source.id] ?? source.kind != SourceKind.stash;
