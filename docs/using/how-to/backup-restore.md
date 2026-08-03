# Backing Up and Restoring Mydia

This guide covers the manual backup and restore procedure for SQLite and PostgreSQL, and what to do about configuration files.

!!! danger "Your container does not back itself up before migrating"
    Mydia applies pending database migrations automatically on startup, from the
    supervision tree, with **no backup step**. There is no automatic pre-migration
    backup in a container deployment, on either SQLite or PostgreSQL.

    Take a backup yourself before every upgrade, using the procedure below. Nothing
    else will do it for you.

## What Mydia actually does

| Environment | Pre-migration backup |
|---|---|
| Docker, Docker Compose, or any release build | **None.** Migrations run on boot, unbacked. |
| Local development via `./dev` | Yes, SQLite only, before a pending migration runs. |

The automatic backup is a **development-environment** feature. It is a devenv task
(`mix mydia.backup_before_migrate`) that runs when you enter the dev shell and a
migration is pending. It copies the SQLite file to
`<database>_backup_YYYYMMDD_HHMMSS.db` next to the database and keeps the 10 most
recent copies. Nothing invokes it in a release build, so it never runs in your
container.

There is no environment variable that turns automatic backups on for a container,
and none that turns them off.

## Before you upgrade

Upgrades are the moment a backup matters, because a migration rewrites your
database in place and a failed one can leave it unusable. The routine is:

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

**Restore:**

```bash
# Stop the container
docker compose stop mydia

# Replace the database file with the backup
cp /path/to/backup/mydia_20240101.db /path/to/config/mydia.db

# Start the container
docker compose start mydia
```

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
