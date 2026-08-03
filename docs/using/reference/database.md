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

For why SQLite is the default, where its one-writer ceiling actually bites, and
when PostgreSQL is worth the extra moving part, see
[How Mydia Runs](../explanation/how-mydia-runs.md#sqlite-is-the-default-because-it-needs-nothing).

## PostgreSQL

For deployments requiring higher concurrency or existing PostgreSQL infrastructure. See [PostgreSQL Support](../how-to/postgresql.md) for image selection, configuration, and a Docker Compose example.

### Version Requirements

- PostgreSQL 12 or later recommended
- PostgreSQL 16 tested

## Database Schema

Mydia uses Ecto, and its migrations are the authoritative schema
(`priv/repo/migrations/`). The tables you are most likely to care about:

| Table | Holds |
|---|---|
| `media_items` | Movies **and** TV series, in one table |
| `episodes` | Individual episodes |
| `media_files` | File references and their technical metadata |
| `library_paths` | Configured libraries |
| `users` | Accounts and authentication |
| `downloads` | Download queue and history |
| `indexer_configs` | Indexer configurations |
| `download_client_configs` | Download client configurations |
| `quality_profiles` | Quality profile definitions |
| `config_settings` | Settings changed in the web UI |

Two shapes surprise people:

- **There is no movies table and no series table.** Both are rows in
  `media_items`, told apart by a `type` column. A query that filters on type is
  how you get one or the other.
- **There is no seasons table.** A season is not an entity. `episodes` carries a
  `season_number` column, and a season is whatever set of episodes shares one.

## Performance Tuning

SQLite performance is generally excellent for personal use. For very large libraries:

- Ensure database is on fast storage (SSD)
- Run `VACUUM` yourself if the file has grown after large deletions. Mydia never
  vacuums, on a schedule or otherwise. Stop the container, run
  `sqlite3 /config/mydia.db 'VACUUM;'`, and start it again.

See [PostgreSQL Support](../how-to/postgresql.md#performance-tuning) for PostgreSQL tuning and connection pool settings.
