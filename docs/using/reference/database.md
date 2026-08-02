# Database Reference

Mydia supports SQLite (default) and PostgreSQL databases.

## SQLite (Default)

SQLite is the default database, providing a simple single-file setup.

### Location

The database file is stored at:

```
/config/mydia.db
```

Configure with:

```bash
DATABASE_PATH=/config/mydia.db
```

### Advantages

- Zero configuration
- Single file backup
- Perfect for personal/home use
- No external dependencies

### Limitations

- Single-writer at a time
- Not suitable for high-concurrency

## PostgreSQL

For deployments requiring higher concurrency or existing PostgreSQL infrastructure.

### Image Selection

Use the PostgreSQL-specific image:

```
ghcr.io/getmydia/mydia:latest-pg
```

!!! important "Image Selection"
    The database adapter is compiled into the image. SQLite and PostgreSQL images are **not interchangeable**.

### Configuration

```bash
DATABASE_TYPE=postgres
DATABASE_HOST=postgres
DATABASE_PORT=5432
DATABASE_NAME=mydia
DATABASE_USER=mydia
DATABASE_PASSWORD=your-password
POOL_SIZE=10
```

### Docker Compose Example

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: mydia
      POSTGRES_PASSWORD: changeme
      POSTGRES_DB: mydia
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mydia"]
      interval: 5s
      timeout: 5s
      retries: 5

  mydia:
    image: ghcr.io/getmydia/mydia:latest-pg
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_TYPE: postgres
      DATABASE_HOST: postgres
      DATABASE_NAME: mydia
      DATABASE_USER: mydia
      DATABASE_PASSWORD: changeme
      # ... other variables

volumes:
  postgres_data:
```

## Migrations

Database migrations run automatically on startup.

### Automatic Backups

Before running migrations, Mydia creates a backup:

- **SQLite:** Backup file created alongside database
- **PostgreSQL:** Recommend external backup solution

### Backup Location

```
/config/mydia_backup_YYYYMMDD_HHMMSS.db
```

Only the 10 most recent backups are kept.

### Disabling Backups

```bash
SKIP_BACKUPS=true
```

!!! warning
    Not recommended. Manual backups should be in place.

## Manual Backup & Restore

### SQLite

**Backup:**

```bash
# Stop container first
docker compose stop mydia

# Copy database file
cp /path/to/config/mydia.db /path/to/backup/
```

**Restore:**

```bash
# Stop container
docker compose stop mydia

# Replace database file
cp /path/to/backup/mydia.db /path/to/config/

# Start container
docker compose start mydia
```

### PostgreSQL

Use standard PostgreSQL backup tools:

```bash
# Backup
pg_dump -U mydia mydia > backup.sql

# Restore
psql -U mydia mydia < backup.sql
```

## Database Schema

Mydia uses Ecto for database management. The schema includes:

- **Users** - User accounts and authentication
- **Libraries** - Media library configurations
- **Movies** - Movie metadata and files
- **Series** - TV show metadata
- **Seasons** - TV show seasons
- **Episodes** - TV show episodes
- **MediaFiles** - File references and metadata
- **Downloads** - Download queue and history
- **Indexers** - Indexer configurations
- **DownloadClients** - Download client configurations
- **QualityProfiles** - Quality profile definitions

## Performance Tuning

### SQLite

SQLite performance is generally excellent for personal use. For very large libraries:

- Ensure database is on fast storage (SSD)
- Regular `VACUUM` operations (performed automatically)

### PostgreSQL

For high-performance deployments:

```bash
POOL_SIZE=20  # Increase connection pool
```

Configure PostgreSQL server settings:

```sql
-- In postgresql.conf
shared_buffers = 256MB
effective_cache_size = 768MB
work_mem = 4MB
```

## Migration from SQLite to PostgreSQL

!!! warning
    No automated migration tool is provided. Manual data migration is required.

1. Export data from SQLite
2. Deploy PostgreSQL instance
3. Import data to PostgreSQL
4. Switch to `latest-pg` image
