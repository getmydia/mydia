# mydia-rs known gotchas

Things any self-hoster will eventually hit. Skim this once before cutover; nothing here is a blocker, but most of them are easier to handle proactively than to debug later.

## Forced re-login at cutover

The cookie name is different (`mydia_rs_session` vs Phoenix's `_mydia_key`) and the session store is different too. Phoenix uses signed cookies with no server-side row; mydia-rs uses tower-sessions backed by a `mydia_rs_sessions` table in the same database. The two cookies do not interfere with each other and mydia-rs treats a Phoenix `_mydia_key` cookie as garbage (and the other way around).

What this means in practice: every browser logs in once when it first hits mydia-rs, and again if you ever roll back to Phoenix.

What survives, in case anyone asks:

- User passwords (mydia-rs verifies the same bcrypt hashes Phoenix wrote)
- API keys (same Argon2 hashes)
- Media tokens (shared JWT signing key, tokens issued by either backend verify on the other)
- Paired remote devices (persistent p2p keypair survives)
- OIDC issuer configuration (same `OIDC_*` env vars)
- Trakt OAuth tokens

Forced re-login is annoying but cheap. We do not port the signed-cookie scheme across because the engineering cost is real, the parity surface would be lossy, and most self-hosted instances have a small number of users.

## inotify watch limit on Linux

The library scanner today is periodic on both Phoenix and mydia-rs (a `walkdir` pass kicked off by the cron schedule), so the inotify watch limit does not bite the current code. It will once the live `notify` + `notify-debouncer-full` watcher lands on the mydia-rs side, and once you have it the default `fs.inotify.max_user_watches=8192` on most distros runs out around a few hundred recursive directory watches. When the limit is hit the watcher fails silently and stops noticing new files.

Set the sysctl now so future-you does not debug it later:

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
echo "fs.inotify.max_user_watches=524288" | sudo tee /etc/sysctl.d/40-mydia.conf
```

The limit is enforced per UID on the host, not per container, so the same sysctl applies whether you run bare-metal or in Docker.

## OIDC providers do not need to be re-registered

mydia-rs reads the same `OIDC_*` env vars Phoenix does:

- `OIDC_ISSUER`
- `OIDC_DISCOVERY_DOCUMENT_URI`
- `OIDC_CLIENT_ID`
- `OIDC_CLIENT_SECRET`
- `OIDC_REDIRECT_URI`
- `OIDC_DISABLE_PAR` (Authelia 4.39+ kill switch)
- `OIDC_DISABLE_REQUEST_PARAMETER` (Authelia 4.39+ kill switch)

The redirect URI path is `/auth/oidc/callback`, same as Phoenix. If your issuer was happy with the Phoenix client registration, it stays happy with mydia-rs.

PKCE state is per-flow, not persistent: anyone mid-OAuth-redirect when you cutover restarts the redirect. Same on rollback.

## Mutual-exclusion lock

mydia-rs refuses to boot if another mydia-rs is already running against the same database. The mechanism differs by engine:

- **Postgres**: `pg_try_advisory_lock(<constant key>)` on a dedicated connection. The lock releases automatically when the session ends, so a crash leaves nothing behind.
- **SQLite**: a row in `mydia_runtime_lock` with a 10-second heartbeat. mydia-rs creates the table on first boot via `CREATE TABLE IF NOT EXISTS`. This is the one and only schema mydia-rs writes, and only to a table Phoenix ignores. On clean shutdown, the row is deleted. After a hard crash, the row sits there until its `heartbeat_at` is more than 30 seconds old, then the next mydia-rs boot reclaims it.

If you see `another mydia or mydia-rs is running against this DB; refusing to start`:

1. Confirm there is no other container actually running (`docker ps`).
2. On SQLite, wait 30 seconds for the heartbeat to go stale, then retry.
3. On Postgres, the lock is tied to the session, so this only fires when another process is genuinely alive. If `docker ps` is clean, look for stray processes on the host.

The guard is currently one-way: mydia-rs refuses to start when Phoenix is up (because Phoenix holds the Postgres advisory key by running queries, and the SQLite lock table is mydia-rs's invention). Phoenix does not yet refuse to start when mydia-rs is alive. Operator discipline still matters: do not start both backends at once during the cutover window.

## Schema-drift detection at startup

At boot, mydia-rs reads the highest `schema_migrations.version` row and compares it to a build-time-embedded constant.

- If the database matches what the binary expects: boot proceeds quietly.
- If the database is **newer** than the binary expects (Phoenix shipped a migration mydia-rs has not been rebuilt to know about): mydia-rs logs a warning at `WARN` level and continues. Additive migrations are tolerated; column renames or drops will surface as query errors when a resolver hits the affected column. Pull a newer mydia-rs image to clear the warning.
- If the database is **older** than the binary expects: mydia-rs logs an error and refuses to start. Boot Phoenix once to apply the pending migrations, then try again. Phoenix retains migration ownership throughout the parallel window.

mydia-rs never writes to `schema_migrations`. The probe is a read.

## SQLite vs Postgres

A single image. Both sqlx drivers are linked in (SQLite via the bundled `libsqlite3-sys`, Postgres via the pure-Rust driver), and `MYDIA_DATABASE__TYPE` picks the engine at runtime. There is no `mydia/mydia-rs:latest-pg` tag; that split only exists on the Phoenix image because Ecto's adapter is compiled into the BEAM release.

Both engines are first-class. Round-trip tests run against both in CI: UUIDs encode as 36-character TEXT on SQLite (Ecto's `:binary_id_type = :string` default) and as native `uuid` on Postgres; datetimes encode as RFC3339 with trailing `Z` on SQLite (Ecto's `@default_datetime_type :iso8601` default) and as `TIMESTAMPTZ` on Postgres; Ecto `:map` columns are `JSONB` on Postgres and JSON-as-TEXT on SQLite; Ecto `:text`-carrying-Jason columns are TEXT on both, with `json_extract` / `->>` doing the right dialect-specific thing at query time.

If you currently run Phoenix on SQLite, run mydia-rs on SQLite. If you run Phoenix on Postgres, run mydia-rs on Postgres. There is no schema migration between the two; that is a separate workstream.

## Drain Oban before cutover

mydia-rs uses apalis with its own tables (`apalis_sql.jobs`). Phoenix uses Oban with `oban_jobs` and friends. They share zero tables.

In-flight Oban jobs at cutover are abandoned (stuck in `oban_jobs` until you roll back). Cron entries on whichever side is not running miss firing windows; the workers (`MovieSearch`, `TVShowSearch`, `MetadataRefresh`, `TraktSync`, etc.) are idempotent so nothing double-effects on rollback, but a downloaded release queued via Oban at cutover stays queued until Phoenix runs again.

Open `/admin/jobs` in Phoenix before cutover and wait for executing rows to drain. Cancel anything stuck for hours.

## Some pages are not in mydia-rs

A few Phoenix LiveViews are intentionally dropped from the rewrite:

- **Music, Books, Adult.** The corresponding library types still exist as configuration on the library-paths admin page, but there are no browse / detail / search pages for music albums, books, or adult content. Phoenix URLs like `/music`, `/books`, `/adult` resolve to 404 on mydia-rs. The music player widget no longer appears in the sidebar.
- **In-browser playback.** Phoenix's `/play/<id>` route is gone. The Flutter player is the only first-party playback surface; mydia-rs's web UI surfaces what is in your library but does not play it back in the browser.

If you actively used any of these features on Phoenix, hold off on cutover until you have a plan for replacing them (or stay on Phoenix indefinitely, the parallel window is open-ended).

## Some endpoints return 501

A handful of REST endpoints currently return `501 Not Implemented` with a `TODO` marker. The architectural gaps are documented in commit `b895e509`. The list:

- `POST /api/v1/hls/sessions` (start a session), `DELETE` (stop), session info endpoints. The U19 streaming pipeline that backs these is partially landed; the HLS controller side is wired up to `Option::None` for now.
- Download orchestration: `POST /api/v1/download`, retry, pause. The `DownloadService` analog of `Mydia.Downloads.*` is not in tree yet.
- `POST /api/v1/indexer/<id>/test`, `POST /api/v1/indexer/<id>/refresh`, `POST /api/v1/indexer/<id>/reset_failures`. List + create + delete work.
- `POST /api/v1/download_client/<id>/test`, `POST /api/v1/download_client/<id>/refresh`. List + create + delete work.
- `GET /api/player/v1/subtitle/show` (single-track extraction). The track index endpoint serves real data.

If the player or a paired device hits one of these, it sees a structured 501 with a `TODO` marker, not a 500. Phoenix still serves all of them. Wait for the gaps to close before cutover if any are load-bearing.

## Quality profiles admin is read-only

The `/admin/quality_profiles` page lists configured profiles but does not yet ship the cutoff-item editor. You can read profiles and see how files match them; you cannot create or edit a profile from the web UI yet. Profiles still drive download decisions, the underlying logic is in the database.

If you need to add or edit a profile during the parallel window, do it from Phoenix's UI (or by SQL, the schema is the same), then roll forward to mydia-rs again.

## The library import flow is a placeholder

`/import` exists, the sidebar links to it, but the page surfaces a "coming soon" card. The Phoenix counterpart is the largest LiveView in the codebase (a search to match to finalize three-step flow for unmatched files with custom grouping heuristics, season pickers, and rename previews). Porting it is on the U27 docket.

Use `/add` for now, which goes through the metadata-relay search to bring titles into your library. The library scanner picks up newly added files on its normal schedule.

## Enum-value drift is forbidden during the parallel window

The plan rule is that neither backend introduces a new enum value (in `users.role`, `download_clients.type`, etc.) that the other does not accept. Rollback would surface `Ecto.Enum` cast errors otherwise. As an operator this only matters if you start hand-editing rows: if you do, stick to the enum values both backends know.

## Tables tolerant of concurrent writes (in case the lock fails)

The mutual-exclusion lock is the primary defense, but a few tables are designed to be idempotent if both backends ever overlap:

- `playback_progress`: last-write-wins is fine, the user-visible cost is a slightly stale resume position.
- `media_files.analyzed_at`: double-analysis is wasteful but the result is the same.
- `library_paths`: admin operation, rare, last-write-wins is fine.

If you ever see evidence both backends ran at the same time (the lock guard exists precisely to prevent this), check these tables first and the worker queues second.
