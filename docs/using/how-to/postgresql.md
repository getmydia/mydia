# PostgreSQL Support

Mydia provides separate Docker images for PostgreSQL users.

## Image Selection

| Image Tag | Database |
|-----------|----------|
| `latest` | SQLite |
| `latest-pg` | PostgreSQL |

!!! important "Image Compatibility"
    The database adapter is compiled into the image. SQLite and PostgreSQL images are **not interchangeable** at runtime.

## Quick Start

### Docker Compose

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
      DATABASE_PORT: 5432
      DATABASE_NAME: mydia
      DATABASE_USER: mydia
      DATABASE_PASSWORD: changeme
      SECRET_KEY_BASE: your-secret-key-base
      GUARDIAN_SECRET_KEY: your-guardian-secret
      PHX_HOST: localhost
      PORT: 4000
      MOVIES_PATH: /media/movies
      TV_PATH: /media/tv
    volumes:
      - ./config:/config
      - /path/to/media:/media
    ports:
      - "4000:4000"

volumes:
  postgres_data:
```

## Configuration

### Environment Variables

Every PostgreSQL variable is listed in [Environment variables](../reference/environment-variables.md#postgresql-configuration).

## Backup & Restore

See [Backing Up and Restoring Mydia](backup-restore.md#postgresql) for the PostgreSQL backup and restore procedure.

## Performance Tuning

### PostgreSQL Configuration

For better performance, tune PostgreSQL settings:

```sql
-- In postgresql.conf
shared_buffers = 256MB
effective_cache_size = 768MB
work_mem = 4MB
maintenance_work_mem = 64MB
wal_buffers = 8MB
```

### Connection Pooling

Adjust `POOL_SIZE` based on your workload:

```bash
POOL_SIZE=20
```

For very high concurrency, consider using PgBouncer in front of PostgreSQL.

## External PostgreSQL

To use an existing PostgreSQL server:

```bash
DATABASE_TYPE=postgres
DATABASE_HOST=your-postgres-server.example.com
DATABASE_PORT=5432
DATABASE_NAME=mydia
DATABASE_USER=mydia
DATABASE_PASSWORD=secure-password
```

Ensure:

- Network connectivity between Mydia and PostgreSQL
- Database and user exist
- User has appropriate permissions

## Migration from SQLite to PostgreSQL

!!! warning
    No automated migration tool is provided. Manual data migration is required.

1. Export data from SQLite
2. Deploy PostgreSQL instance
3. Import data to PostgreSQL
4. Switch to `latest-pg` image

## Troubleshooting

### Connection Refused

1. Verify PostgreSQL is running
2. Check hostname and port
3. Verify credentials
4. Check network connectivity

### Permission Denied

1. Verify database user exists
2. Check user permissions:

```sql
GRANT ALL PRIVILEGES ON DATABASE mydia TO mydia;
```

### Slow Queries

1. Check PostgreSQL logs
2. Run `ANALYZE` on tables
3. Review connection pool settings
4. Check server resources

### Database Errors

1. Check disk space
2. Verify database file permissions
3. Try [restoring from a backup](backup-restore.md)

## Next Steps

- [How Mydia Runs](../explanation/how-mydia-runs.md#when-postgresql-earns-its-keep) - When PostgreSQL is worth the extra service, and when SQLite is the better default
- [Database Reference](../reference/database.md) - Locations, versions, and schema
- [Backing Up and Restoring Mydia](backup-restore.md) - Backup procedures for both databases
