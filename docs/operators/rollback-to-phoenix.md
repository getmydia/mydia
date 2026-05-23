# Rolling back from mydia-rs to Phoenix

Cutover to mydia-rs is reversible. Phoenix keeps shipping unchanged from the same repository for at least one minor release after the recommended tag flips, and both backends read the same database. Rolling back is the cutover steps in reverse plus another one-time browser re-login.

If you ran [the cutover](cutover-to-mydia-rs.md) recently, the diff is small and rollback should take five minutes.

## When to consider rolling back

Most rollback decisions fall into one of these:

- **Data looks corrupted.** Stop, do not write more. Restore from the backup you took during cutover, then investigate.
- **A critical feature is missing or broken.** Some endpoints currently return `501 Not Implemented` (see the [cutover doc's 501 list](cutover-to-mydia-rs.md#endpoints-that-return-501)). If one of them is load-bearing for your setup, Phoenix still has it.
- **Performance regression you cannot tune.** Roll back, file a bug with timing data.
- **You changed your mind.** That is allowed. The cutover doc is documentation, not a one-way door.

If you are unsure, take a fresh database backup before flipping the tag, so you have a snapshot of the last mydia-rs state. Tag your backup with the timestamp.

## Step by step

1. **Take a backup of the current state.** This captures any writes mydia-rs made since cutover.

    SQLite:
    ```bash
    sqlite3 /var/lib/mydia/mydia.db ".backup /var/lib/mydia/mydia-pre-rollback.db"
    ```

    Postgres:
    ```bash
    pg_dump -Fc -U mydia mydia > mydia-pre-rollback.dump
    ```

2. **Stop mydia-rs.**

    ```bash
    docker compose down mydia
    ```

    The mutual-exclusion lock releases automatically on a clean shutdown (Postgres advisory lock by session, SQLite `mydia_runtime_lock` row by `DELETE`). If the container was killed hard, the SQLite row goes stale after 30 seconds and Phoenix is unaffected either way.

3. **Edit `compose.yml`** back to the Phoenix image you ran before cutover. If you are on SQLite:

    ```diff
     services:
       mydia:
    -    image: ghcr.io/getmydia/mydia/mydia-rs:latest
    +    image: ghcr.io/getmydia/mydia:latest
         environment:
    -      MYDIA_DATABASE__TYPE: sqlite
    -      MYDIA_DATABASE__PATH: /var/lib/mydia/mydia.db
           # ...
    ```

    If you are on Postgres:

    ```diff
     services:
       mydia:
    -    image: ghcr.io/getmydia/mydia/mydia-rs:latest
    +    image: ghcr.io/getmydia/mydia:latest-pg
         environment:
    -      MYDIA_DATABASE__TYPE: postgres
    -      MYDIA_DATABASE__URL: postgres://mydia:CHANGE-ME@postgres:5432/mydia
           # ...
    ```

    Phoenix reads `DATABASE_URL` and the SQLite path from its own env vars (see [Reference > Environment Variables](../reference/environment-variables.md)), so the mydia-rs `MYDIA_DATABASE__*` lines can come out. Your `OIDC_*` block stays.

4. **Pull and restart.**

    ```bash
    docker compose pull mydia
    docker compose up -d mydia
    docker compose logs -f mydia
    ```

    Phoenix boots, runs Ecto's migration check (a no-op because the schema is current), starts Oban, and serves on the same port mydia-rs was using.

5. **Log in again.** Phoenix's session cookie (`_mydia_key`) is signed and unrelated to mydia-rs's server-side session. Every browser needs one fresh login.

6. **Walk through the same post-cutover checklist** ([Validation steps](cutover-to-mydia-rs.md#after-the-swap)), in reverse, to confirm Phoenix sees the data it should.

## What survives rollback

Everything that survived cutover survives rollback. Both directions are symmetric.

| What | Survives rollback? |
|---|---|
| Database schema and all rows | Yes, same database, no migrations either way |
| Media files on disk | Yes, nothing on disk changes |
| User passwords | Yes, bcrypt hashes verify on both sides |
| API keys | Yes, Argon2 hashes verify on both sides |
| Paired remote devices | Yes, persistent p2p keypair survives |
| Media tokens (JWTs) | Yes, shared signing key |
| Trakt OAuth tokens | Yes, stored in the database |
| OIDC issuer configuration | Yes, same `OIDC_*` env vars |
| Library scan history | Yes, in the database |
| Watch history, favorites, collections | Yes, in the database |
| Download history, release blacklist | Yes, in the database |

## What does not survive rollback

- **Browser session cookies.** Phoenix's `_mydia_key` is signed with a different secret than mydia-rs's `mydia_rs_session`, and the storage shapes differ. Re-login is one-shot per browser per direction.
- **In-flight OIDC PKCE state.** Anyone mid-OAuth-redirect when you flip the tag restarts the redirect.
- **In-flight apalis jobs.** Phoenix uses Oban with its own tables; jobs that were queued in apalis stay stranded in `apalis_sql.jobs` until you cutover to mydia-rs again. They do not corrupt anything, they just sit there. The Oban tables are untouched on the mydia-rs side, so Oban's cron resumes on its normal schedule.
- **In-flight HLS sessions.** Both backends clean their own temp directories on boot, so leftover segment dirs do not accumulate.
- **The `mydia_runtime_lock` table on SQLite.** This is the only schema mydia-rs writes, via `CREATE TABLE IF NOT EXISTS` on first boot. Phoenix ignores the table, so it sits there harmlessly. If you want to drop it after a permanent rollback, `DROP TABLE mydia_runtime_lock;` is safe (mydia-rs recreates it on next boot if you ever come back).

There is no "Phoenix to mydia-rs" data migration that needs to run, and no "mydia-rs to Phoenix" data unmigration. Both backends share the schema.

## After rollback

Phoenix's Oban resumes its cron schedule. If a cron-driven worker (movie search, TV show search, metadata refresh, Trakt sync) was supposed to fire while you were on mydia-rs, the next firing window catches up. The workers are idempotent, so nothing double-effects.

If you spotted a regression in mydia-rs, file a bug with the symptoms. Pointing at the specific endpoint that misbehaved, the input that triggered it, and what Phoenix did differently is enough to start triage. Logs from the mydia-rs container are useful; tracing output is structured and includes the request span.

## Fallback window

Phoenix's CI keeps building both `:latest` and `:latest-pg` for at least one minor release after the cutover documentation recommends mydia-rs. If you cannot pull the image you ran before, that is a release-process bug worth filing. The intent of the parallel window is exactly to make this rollback work.
