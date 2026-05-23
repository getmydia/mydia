# Cutting over from Phoenix to mydia-rs

This page walks through switching a running Phoenix deployment to mydia-rs. Both backends read the same database, the same on-disk media, and the same metadata-relay, so the cutover is a Docker tag change plus a one-time re-login on every browser. If anything looks wrong afterwards, [Rolling back to Phoenix](rollback-to-phoenix.md) is one tag swap away.

Read [the known gotchas](mydia-rs-known-gotchas.md) before you start. Most of them only need a sysctl tweak or a heads-up, but two of them (inotify watch limits, Oban drain) are worth handling before flipping the image.

## Before you start

1. **Back up your database.** This is the cheapest insurance policy. mydia-rs does not delete or rewrite any Phoenix rows, but a backup makes rollback boring.

    SQLite:
    ```bash
    sqlite3 /var/lib/mydia/mydia.db ".backup /var/lib/mydia/mydia-pre-cutover.db"
    ```

    Postgres:
    ```bash
    pg_dump -Fc -U mydia mydia > mydia-pre-cutover.dump
    ```

2. **Drain Oban.** mydia-rs uses apalis with its own tables; in-flight Oban jobs are abandoned at cutover and only resume if you roll back. Open `/admin/jobs` in the Phoenix UI and wait for the pending and executing rows to drain. Cancel anything that has been stuck for hours. The cron entries (movie search, TV show search, metadata refresh, Trakt sync) will miss their next firing window on whichever side you aren't running, that's fine, those workers are idempotent.

3. **Let HLS sessions finish.** Active transcoding sessions are torn down at cutover. Either wait for the players to disconnect, or accept that anyone watching right now will need to restart playback after the image swap. Both backends clean up their own stale HLS temp directories on boot, so leftover segments will not pile up.

4. **Bump `fs.inotify.max_user_watches` on Linux** if you have a large library. The default of 8192 is not enough for a few hundred media files. Once the library watcher lands, mydia-rs will exhaust that quietly and stop noticing new files. Set it now:

    ```bash
    sudo sysctl -w fs.inotify.max_user_watches=524288
    echo "fs.inotify.max_user_watches=524288" | sudo tee /etc/sysctl.d/40-mydia.conf
    ```

5. **Note your current image tag.** You will use it again when you roll back.

    ```bash
    docker compose config | grep image:
    ```

## Cutover

Edit `compose.yml` and change the mydia image. If you are on SQLite:

```diff
 services:
   mydia:
-    image: ghcr.io/getmydia/mydia:latest
+    image: ghcr.io/getmydia/mydia/mydia-rs:latest
     environment:
+      MYDIA_DATABASE__TYPE: sqlite
+      MYDIA_DATABASE__PATH: /var/lib/mydia/mydia.db
       # ...
```

If you are on Postgres:

```diff
 services:
   mydia:
-    image: ghcr.io/getmydia/mydia:latest-pg
+    image: ghcr.io/getmydia/mydia/mydia-rs:latest
     environment:
+      MYDIA_DATABASE__TYPE: postgres
+      MYDIA_DATABASE__URL: postgres://mydia:CHANGE-ME@postgres:5432/mydia
       # ...
```

There is no `mydia/mydia-rs:latest-pg` tag. The same image links both sqlx drivers (SQLite via the bundled `libsqlite3-sys`, Postgres via the pure-Rust driver) and picks at runtime based on `MYDIA_DATABASE__TYPE`. Your existing volumes mount unchanged. Your `OIDC_*` block carries over unchanged. Your data directory keeps everything it already has.

Then restart:

```bash
docker compose down mydia
docker compose pull mydia
docker compose up -d mydia
docker compose logs -f mydia
```

In the boot logs you should see:

- `schema_migrations probe passed` (or a warning that Phoenix has migrated past this binary, see below)
- `acquired runtime lock` (Postgres advisory lock or SQLite `mydia_runtime_lock` row)
- `tracing` initialized, server listening on the port you configured (default 4001)
- p2p host booting if you have remote access enabled

If you see `DB is older than this mydia-rs build expects`, mydia-rs has refused to start because Phoenix never applied a migration the binary depends on. Roll back, boot Phoenix once so it migrates, then redo the cutover.

If you see `another mydia or mydia-rs is running against this DB`, two backends are racing for the same database. Confirm Phoenix is fully stopped (`docker compose ps`) and retry. If a previous mydia-rs crashed without cleaning up, the lock row goes stale after 30 seconds (see [Known Gotchas](mydia-rs-known-gotchas.md#mutual-exclusion-lock)).

## After the swap

Walk through enough of the UI to feel confident the parity is real. The order below covers the surfaces most likely to surface a regression:

1. **Log in.** You will be sent to the login page because your Phoenix session cookie does not work against mydia-rs. The cookie name is different (`mydia_rs_session` vs Phoenix's `_mydia_key`) and the session store is server-side. Your password verifies against the same bcrypt hash Phoenix wrote.

2. **Pair a Flutter player session.** Open the player, hit the existing pairing flow (or use a paired device's stored claim). The persistent p2p keypair is in your data volume and survives the cutover, so existing pairings reconnect. Media tokens issued by Phoenix are still valid (shared JWT signing key), so any tab with a pre-issued token keeps working.

3. **Check `/admin/library_paths`.** Verify the configured library paths show up. Add one and confirm it persists; remove it and confirm the row disappears from the database.

4. **Check `/admin/jobs`.** Apalis's queue and recent job history should be empty for now (apalis tables are fresh). The `jobs:status` pubsub feed populates as workers fire. Cron-driven jobs (movie search, TV show search, metadata refresh, Trakt sync) start firing on their normal schedule.

5. **Check `/admin/users`.** Your users are all here, role assignments preserved. API keys still verify against the same Argon2 hashes.

6. **Check `/admin/devices`.** Paired remote devices are present. Revoking a device synchronously evicts its cached media tokens (no five-minute TTL gap).

7. **Play something through the Flutter player.** End-to-end exercises the GraphQL contract, the REST `/api/v1/stream/<token>` byte-range endpoint, the HLS pipeline (if the player picks transcode), and the p2p connection (if you pair over WAN). The player is the integration test that matters most.

8. **Open the dashboard, movies, TV, calendar.** The reads are GraphQL parity territory. If something looks empty that shouldn't be, the database wasn't the problem, file a bug.

In the first hour, keep an eye on:

- **Background workers.** The job feed should show activity from `library_scanner` (if files changed), `metadata_refresh` (on schedule), `trakt_sync` (if Trakt is wired). The 24-worker list is documented in [mydia-rs/crates/jobs/src/workers](https://github.com/getmydia/mydia/tree/master/mydia-rs/crates/jobs/src/workers).
- **Transcode jobs.** Anyone playing media through the player will likely trigger a transcode session. Watch `/admin/transcodes` and look for sessions that start but never finish.
- **p2p connectivity.** If you have remote access enabled, mDNS announcements on the LAN and DHT presence on the WAN should both come up within a minute. Check `/admin/remote_access` for the node status.
- **OIDC.** If you log in with an OIDC provider, the first OAuth round-trip after cutover exercises the new handler. mydia-rs reads the same `OIDC_*` env vars Phoenix does and uses the same `/auth/oidc/callback` redirect URI, so the issuer does not need to be re-registered.

## Endpoints that return 501

A handful of REST endpoints currently return `501 Not Implemented` with a `TODO` marker. The architectural gaps are documented in the commit history (search for `b895e509`). If any of these are load-bearing for your setup, hold off on cutover:

- HLS session lifecycle (`/api/v1/hls/sessions/*`)
- Download orchestration (`POST /api/v1/download`, retry, pause)
- Indexer test, refresh, reset-failures
- Download-client test, refresh
- Single-track subtitle extraction

Byte-range streaming, thumbnails, the operator config endpoint, the player's range fetch, the indexer + download-client list paths, and subtitle indexing all serve real responses today.

## When something looks wrong

If a page renders but data is missing, screenshot it and open a bug. If the binary refuses to start, log shipping is your friend, mydia-rs writes structured tracing output. If a regression is bad enough that you'd rather have Phoenix back, follow [Rolling back to Phoenix](rollback-to-phoenix.md). The data does not move; you can flip the tag back and forth as many times as you need.

The rollback window is at least one minor Phoenix release after the cutover documentation lands. Phoenix CI keeps publishing `ghcr.io/getmydia/mydia:latest` and `:latest-pg` throughout. If you cannot pull the image you ran before, that is a release-process bug, file it.
