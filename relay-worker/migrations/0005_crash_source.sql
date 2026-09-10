-- Which client sent a crash: 'server' (Mydia.CrashReporter in the mydia
-- server) or 'player' (the Flutter player's CrashReporter). Every row written
-- before this migration came from a server, and so does every report from an
-- install that predates the field, which is why the default is 'server'
-- rather than NULL. src/crashes/ingest.ts's crashSourceOf is the only writer.
--
-- On `errors` it is the source of the report that first created the group.
-- Player frames are package:player/ URIs and server frames are lib/mydia/
-- paths, so a fingerprint never mixes the two in practice.
ALTER TABLE errors ADD COLUMN source TEXT NOT NULL DEFAULT 'server';
ALTER TABLE occurrences ADD COLUMN source TEXT NOT NULL DEFAULT 'server';
