//! `SeaORM` connection bootstrap.
//!
//! [`connect_from_config`] is the single workspace entry point for
//! opening a database. It returns the `SeaORM`-native
//! [`DatabaseConnection`] directly — there is no `Db` enum, no
//! `from_sqlx_*_pool` bridging seam, and no per-engine accessor.
//! Downstream crates thread `&DatabaseConnection` everywhere; engine
//! awareness lives inside [`crate::types`] (wrapper write helpers and
//! `TryGetable` reads) and [`crate::insert_helper`] (`ActiveModel`
//! dispatch). Callers don't branch on backend at all unless they're
//! gating an engine-specific feature outright (e.g. `mydia_runtime_lock`
//! on `SQLite`-only).
//!
//! `SQLite` PRAGMAs (`journal_mode`, `synchronous`, `busy_timeout`,
//! `cache_size`, `temp_store`, `foreign_keys`) reach the underlying
//! sqlx-sqlite driver via `ConnectOptions::map_sqlx_sqlite_opts`. The
//! values match the legacy `pool.rs` set; behavior parity with the
//! pre-cutover pool was validated by the Phase A smoke tests in
//! `tests/seaorm_connect_smoke.rs`.

use std::time::Duration;

use sea_orm::sqlx::sqlite::{SqliteJournalMode, SqliteSynchronous};
use sea_orm::{ConnectOptions, ConnectionTrait, Database, DatabaseConnection, Statement};

use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};

use crate::error::DbError;

/// Open a `SeaORM` [`DatabaseConnection`] from the loaded configuration.
///
/// Dispatches on `database.db_type`: builds a `sqlite:` URL from
/// `database.path` for `SQLite`, or passes `database.url` through for
/// Postgres. `ConnectOptions` applies the shared pool tuning
/// (`max_connections`, `acquire_timeout`); `SQLite` additionally routes
/// PRAGMAs through `map_sqlx_sqlite_opts`.
///
/// Returns after a successful smoke query so the caller knows the
/// connection is live without requiring any application schema.
pub async fn connect_from_config(config: &Config) -> Result<DatabaseConnection, DbError> {
    let cfg = &config.database;
    let url = build_url(cfg)?;
    let mut opts = ConnectOptions::new(url);
    opts.max_connections(cfg.pool_size)
        .acquire_timeout(Duration::from_millis(u64::from(cfg.timeout_ms)))
        .sqlx_logging(false);

    if matches!(cfg.db_type, DatabaseType::Sqlite) {
        let cfg = cfg.clone();
        opts.map_sqlx_sqlite_opts(move |o| {
            o.create_if_missing(true)
                .journal_mode(map_journal_mode(cfg.journal_mode))
                .synchronous(map_synchronous(cfg.synchronous))
                .busy_timeout(Duration::from_millis(u64::from(cfg.busy_timeout_ms)))
                .pragma("cache_size", cfg.cache_size_kib.to_string())
                .pragma("temp_store", "memory")
                .pragma("foreign_keys", "ON")
        });
    }

    let db = Database::connect(opts).await?;
    smoke_query(&db).await?;
    Ok(db)
}

/// Cheap smoke query against a `SeaORM` connection. `SELECT 1` survives
/// dialect differences; runs via `query_one_raw` so we don't depend on
/// any application schema. Called from [`connect_from_config`] right
/// after opening.
pub async fn smoke_query(db: &DatabaseConnection) -> Result<(), DbError> {
    let backend = db.get_database_backend();
    let stmt = Statement::from_string(backend, "SELECT 1".to_string());
    db.query_one_raw(stmt).await?;
    Ok(())
}

fn build_url(cfg: &DatabaseConfig) -> Result<String, DbError> {
    match cfg.db_type {
        DatabaseType::Sqlite => {
            let path =
                cfg.path
                    .as_deref()
                    .filter(|p| !p.is_empty())
                    .ok_or(DbError::Misconfigured {
                        kind: "type",
                        required: "sqlite (database.path)",
                    })?;
            // sqlx-sqlite accepts `sqlite::memory:` and `sqlite:filename`;
            // `create_if_missing` applies via the `map_sqlx_sqlite_opts`
            // callback configured in [`connect_from_config`].
            if path == ":memory:" {
                Ok("sqlite::memory:".to_string())
            } else {
                Ok(format!("sqlite:{path}"))
            }
        }
        DatabaseType::Postgres => {
            let url =
                cfg.url
                    .as_deref()
                    .filter(|u| !u.is_empty())
                    .ok_or(DbError::Misconfigured {
                        kind: "type",
                        required: "postgres (database.url)",
                    })?;
            Ok(url.to_string())
        }
    }
}

fn map_journal_mode(mode: mydia_rs_config::SqliteJournalMode) -> SqliteJournalMode {
    use mydia_rs_config::SqliteJournalMode as Cfg;
    match mode {
        Cfg::Delete => SqliteJournalMode::Delete,
        Cfg::Truncate => SqliteJournalMode::Truncate,
        Cfg::Persist => SqliteJournalMode::Persist,
        Cfg::Memory => SqliteJournalMode::Memory,
        Cfg::Wal => SqliteJournalMode::Wal,
    }
}

fn map_synchronous(sync: mydia_rs_config::SqliteSynchronous) -> SqliteSynchronous {
    use mydia_rs_config::SqliteSynchronous as Cfg;
    match sync {
        Cfg::Off => SqliteSynchronous::Off,
        Cfg::Normal => SqliteSynchronous::Normal,
        Cfg::Full => SqliteSynchronous::Full,
        Cfg::Extra => SqliteSynchronous::Extra,
    }
}
