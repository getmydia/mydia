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

For deployments requiring higher concurrency or existing PostgreSQL infrastructure. See [PostgreSQL Support](../how-to/postgresql.md) for image selection, configuration, and a Docker Compose example.

### Version Requirements

- PostgreSQL 12 or later recommended
- PostgreSQL 16 tested

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

SQLite performance is generally excellent for personal use. For very large libraries:

- Ensure database is on fast storage (SSD)
- Regular `VACUUM` operations (performed automatically)

See [PostgreSQL Support](../how-to/postgresql.md#performance-tuning) for PostgreSQL tuning and connection pool settings.
