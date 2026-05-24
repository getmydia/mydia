//! Connection pool selector and constructor.
//!
//! The `Db` enum stays the single handle every caller threads through
//! the app. Internally it dispatches to either `sqlx::SqlitePool` or
//! `sqlx::PgPool`. This is the runtime-select replacement for Phoenix's
//! compile-time `database_adapter` choice.

use std::time::Duration;

use sqlx::postgres::PgPoolOptions;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::{PgPool, SqlitePool};

use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};

use crate::dialect::Dialect;
use crate::error::DbError;

/// Active connection pool plus the dialect it talks.
#[derive(Debug, Clone)]
pub enum Db {
    Sqlite(SqlitePool),
    Postgres(PgPool),
}

impl Db {
    /// Dialect the pool talks. Use with [`crate::dialect`] helpers.
    pub fn dialect(&self) -> Dialect {
        match self {
            Self::Sqlite(_) => Dialect::Sqlite,
            Self::Postgres(_) => Dialect::Postgres,
        }
    }

    /// Borrow the `SQLite` pool. Returns `None` when the active backend is
    /// Postgres. Use this only in code paths that genuinely need the
    /// concrete `SqlitePool` (e.g. SQLite-specific PRAGMAs).
    pub fn as_sqlite(&self) -> Option<&SqlitePool> {
        match self {
            Self::Sqlite(p) => Some(p),
            Self::Postgres(_) => None,
        }
    }

    /// Borrow the Postgres pool. Returns `None` when the active backend
    /// is `SQLite`.
    pub fn as_postgres(&self) -> Option<&PgPool> {
        match self {
            Self::Postgres(p) => Some(p),
            Self::Sqlite(_) => None,
        }
    }

    /// Cheap smoke query: `SELECT 1`. Confirms the pool is wired up
    /// without depending on any application schema. Called from
    /// [`connect_from_config`] right after opening.
    pub async fn smoke_query(&self) -> Result<i32, DbError> {
        let value = match self {
            Self::Sqlite(p) => {
                // TODO(tier-a): portable shape, promotable in the db-promotion pass.
                #[allow(clippy::disallowed_methods)]
                sqlx::query_scalar::<_, i32>("SELECT 1")
                    .fetch_one(p)
                    .await?
            }
            Self::Postgres(p) => {
                // TODO(tier-a): portable shape, promotable in the db-promotion pass.
                #[allow(clippy::disallowed_methods)]
                sqlx::query_scalar::<_, i32>("SELECT 1")
                    .fetch_one(p)
                    .await?
            }
        };
        Ok(value)
    }
}

/// Open a pool from the loaded configuration. Validates the chosen
/// driver is compiled in, applies `SQLite` PRAGMAs matching the
/// Phoenix-side production tuning, runs the smoke query, and returns
/// the ready [`Db`].
pub async fn connect_from_config(config: &Config) -> Result<Db, DbError> {
    let db = open_pool(&config.database).await?;
    db.smoke_query().await?;
    Ok(db)
}

async fn open_pool(cfg: &DatabaseConfig) -> Result<Db, DbError> {
    match cfg.db_type {
        DatabaseType::Sqlite => open_sqlite(cfg).await,
        DatabaseType::Postgres => open_postgres(cfg).await,
    }
}

async fn open_sqlite(cfg: &DatabaseConfig) -> Result<Db, DbError> {
    let path = cfg
        .path
        .as_deref()
        .filter(|p| !p.is_empty())
        .ok_or(DbError::Misconfigured {
            kind: "type",
            required: "sqlite (database.path)",
        })?;

    let opts = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .journal_mode(map_journal_mode(cfg.journal_mode))
        .synchronous(map_synchronous(cfg.synchronous))
        .busy_timeout(Duration::from_millis(u64::from(cfg.busy_timeout_ms)))
        .pragma("cache_size", cfg.cache_size_kib.to_string())
        .pragma("temp_store", "memory")
        .pragma("foreign_keys", "ON");

    let pool = SqlitePoolOptions::new()
        .max_connections(cfg.pool_size)
        .acquire_timeout(Duration::from_millis(u64::from(cfg.timeout_ms)))
        .connect_with(opts)
        .await?;

    Ok(Db::Sqlite(pool))
}

async fn open_postgres(cfg: &DatabaseConfig) -> Result<Db, DbError> {
    let url = cfg
        .url
        .as_deref()
        .filter(|u| !u.is_empty())
        .ok_or(DbError::Misconfigured {
            kind: "type",
            required: "postgres (database.url)",
        })?;

    let pool = PgPoolOptions::new()
        .max_connections(cfg.pool_size)
        .acquire_timeout(Duration::from_millis(u64::from(cfg.timeout_ms)))
        .connect(url)
        .await?;

    Ok(Db::Postgres(pool))
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
