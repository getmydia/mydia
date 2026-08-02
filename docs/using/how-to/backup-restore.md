# Backing Up and Restoring Mydia

This guide covers automatic database backups, the manual backup and restore procedure for SQLite and PostgreSQL, and what to do about configuration files.

## Automatic Backups

Database migrations run automatically on startup. Before running them, Mydia creates an automatic backup:

- **SQLite:** a backup file is created alongside the database
- **PostgreSQL:** Mydia does not create an automatic backup; use an external backup solution (see below)

### Backup Location

SQLite backups are stored at:

```
/config/mydia_backup_YYYYMMDD_HHMMSS.db
```

Only the 10 most recent backups are kept.

### Disabling Backups

```bash
SKIP_BACKUPS=true
```

!!! warning
    Not recommended. Manual backups should be in place before disabling automatic ones.

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
docker compose exec postgres pg_dump -U mydia mydia > backup.sql

# Restore
docker compose exec -T postgres psql -U mydia mydia < backup.sql
```

## Configuration Backup

Database settings are included in automatic database backups. Environment variables and YAML configuration files live outside the database, so back them up separately as part of your infrastructure management.
