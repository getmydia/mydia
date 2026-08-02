# Backing Up and Restoring Mydia

This guide covers the automatic pre-migration backup, the manual backup and restore procedure for SQLite and PostgreSQL, and what to do about configuration files.

!!! warning "The automatic backup is a safety net, not a backup strategy"
    Mydia snapshots its SQLite database before applying pending migrations, so an
    upgrade that goes wrong has something to restore from. That snapshot lands next
    to the database, on the same disk, and there is no equivalent on PostgreSQL. It
    will not survive a lost volume, a failed disk, or a deleted container. Keep
    taking your own backups, off the machine.

## What Mydia does for you

| Database | Pre-migration backup |
|---|---|
| SQLite | Yes. A snapshot is written before pending migrations run, in every deployment: Docker, NixOS, and the dev shell. |
| PostgreSQL | None. Mydia logs a warning instead. |

On SQLite, Mydia checks for pending migrations at startup, before the migrator
runs. If any are pending it writes `<database>_backup_YYYYMMDD_HHMMSS.db` beside
the original and keeps the 10 most recent. With nothing pending it writes
nothing, so an ordinary restart costs nothing.

The snapshot is taken with SQLite's own `VACUUM INTO`, not a file copy. This
matters more than it sounds. Mydia runs SQLite in write-ahead-log mode, so
recently committed data can still be sitting in the `mydia.db-wal` sidecar rather
than in `mydia.db` itself. Copying the main file alone would produce a backup
that looks complete and is quietly missing your most recent changes, which you
would only discover when you tried to restore it. `VACUUM INTO` reads through the
log, cannot produce a torn or half-written file, and compacts the result, so the
snapshot is usually smaller than the live database.

On PostgreSQL, Mydia takes no backup. `VACUUM INTO` has no PostgreSQL
equivalent, and Mydia deliberately does not shell out to `pg_dump`, which is not
guaranteed to be installed alongside the server. An unreliable backup is worse
than an honest absence of one. Mydia logs a warning naming the situation instead,
and you should take your own dump before every upgrade using the procedure below.

If the backup fails, and a full disk is the usual reason, Mydia logs the failure
at error level, names what went wrong, states plainly that it is about to migrate
unprotected, and starts anyway. Refusing to boot would lock you out of the
instance over a problem you cannot fix from inside it.

### Turning it off

Set `SKIP_BACKUPS=true` to disable the automatic backup. Snapshotting a
multi-gigabyte database on every upgrade costs time and disk, and if you already
snapshot the volume out of band you may not want a second copy. Mydia logs that
it is skipping the backup and migrates without one.

## Before you upgrade

Upgrades are the moment a backup matters, because a migration rewrites your
database in place and a failed one can leave it unusable. The automatic copy
covers the migration itself; it does not cover the disk it sits on. The routine
is:

1. Take a backup with the procedure below.
2. Confirm the backup file exists and is non-empty.
3. Pull the new image and start it.
4. Watch the logs for migration errors before you go and do something else.

See [Updating Mydia](update-mydia.md) for the upgrade itself.

## Manual Backup and Restore

### SQLite

**Backup:**

```bash
# Stop the container
docker compose stop mydia

# Copy the database file, with a timestamp so backups don't overwrite each other
cp /path/to/config/mydia.db /path/to/backup/mydia_$(date +%Y%m%d).db

# Start the container
docker compose start mydia
```

Stopping the container first is not optional. A running Mydia keeps recent
writes in `mydia.db-wal`, so copying `mydia.db` on its own from under a live
server gives you an incomplete database. A clean stop folds the log back in and
removes the sidecar. If you find `mydia.db-wal` or `mydia.db-shm` still present
after stopping, copy them alongside the database rather than leaving them behind.

**Restore:**

```bash
# Stop the container
docker compose stop mydia

# Replace the database file with the backup
cp /path/to/backup/mydia_20240101.db /path/to/config/mydia.db

# Remove any leftover write-ahead log, or SQLite will replay it over your restore
rm -f /path/to/config/mydia.db-wal /path/to/config/mydia.db-shm

# Start the container
docker compose start mydia
```

Restoring an automatic pre-migration backup works the same way. Those snapshots
sit beside the database as `mydia_backup_YYYYMMDD_HHMMSS.db`, so pick the newest
one from before the upgrade:

```bash
docker compose stop mydia
ls -t /path/to/config/mydia_backup_*.db | head
cp /path/to/config/mydia_backup_20240101_120000.db /path/to/config/mydia.db
rm -f /path/to/config/mydia.db-wal /path/to/config/mydia.db-shm
docker compose start mydia
```

Roll the image back to the version that wrote the backup at the same time.
Restoring an older database under a newer Mydia just replays the migration you
were trying to undo.

### PostgreSQL

```bash
# Backup
pg_dump -h localhost -U mydia mydia > backup.sql

# Restore
psql -h localhost -U mydia mydia < backup.sql
```

Running PostgreSQL inside the same Docker Compose stack as Mydia? Run the commands through the `postgres` service instead:

```bash
# Backup
docker compose exec -T postgres pg_dump -U mydia mydia > backup.sql

# Restore
docker compose exec -T postgres psql -U mydia mydia < backup.sql
```

## Configuration Backup

Settings you changed in the web UI live in the database, so a database backup
captures them. Environment variables and the YAML configuration file live outside
the database, so back them up separately as part of your infrastructure
management. See [How Configuration Works](../explanation/configuration-model.md)
for which settings land where.
