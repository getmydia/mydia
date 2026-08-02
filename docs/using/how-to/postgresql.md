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

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_TYPE` | Set to `postgres` | `sqlite` |
| `DATABASE_HOST` | PostgreSQL hostname | `localhost` |
| `DATABASE_PORT` | PostgreSQL port | `5432` |
| `DATABASE_NAME` | Database name | `mydia` |
| `DATABASE_USER` | Database username | `postgres` |
| `DATABASE_PASSWORD` | Database password | - |
| `POOL_SIZE` | Connection pool size | `10` |

## Connection Pooling

Adjust pool size based on your workload:

```bash
POOL_SIZE=20
```

For high-traffic deployments, consider using PgBouncer.

## Backup & Restore

### Backup

```bash
pg_dump -h localhost -U mydia mydia > backup.sql
```

Or using Docker:

```bash
docker compose exec postgres pg_dump -U mydia mydia > backup.sql
```

### Restore

```bash
psql -h localhost -U mydia mydia < backup.sql
```

Or using Docker:

```bash
docker compose exec -T postgres psql -U mydia mydia < backup.sql
```

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

### Connection Settings

```bash
# Increase pool for high concurrency
POOL_SIZE=30
```

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

## Version Requirements

- PostgreSQL 12 or later recommended
- PostgreSQL 16 tested

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

## When to Use PostgreSQL

**Use PostgreSQL for:**

- High-concurrency environments
- Existing PostgreSQL infrastructure
- Advanced querying needs
- Horizontal scaling requirements

**Use SQLite for:**

- Personal/home use
- Simple deployments
- Single-user scenarios
- Minimal resource usage
