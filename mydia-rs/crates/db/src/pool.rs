//! Connection pool selector and constructor.
//!
//! The `Db` enum stays the single handle every caller threads through
//! the app. Internally it dispatches to either `sqlx::SqlitePool` or
//! `sqlx::PgPool`. This is the runtime-select replacement for Phoenix's
//! compile-time `database_adapter` choice.

use std::time::Duration;

use sea_orm::{ConnectOptions, Database, DatabaseConnection, Statement};
use sqlx::postgres::PgPoolOptions;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::{PgPool, SqlitePool};

use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};

use crate::error::DbError;

/// Active connection pool plus the dialect it talks.
#[derive(Debug, Clone)]
pub enum Db {
    Sqlite(SqlitePool),
    Postgres(PgPool),
}

impl Db {
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
                // SQLite arm of a tier-(a) pair; byte-equal to the macro arm below.
                #[allow(clippy::disallowed_methods)]
                sqlx::query_scalar::<_, i32>("SELECT 1")
                    .fetch_one(p)
                    .await?
            }
            Self::Postgres(p) => sqlx::query_scalar!("SELECT 1")
                .fetch_one(p)
                .await?
                .unwrap_or(0),
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

/// Open a `SeaORM` [`DatabaseConnection`] from the loaded configuration.
///
/// Transitional Phase A entry point that lives alongside
/// [`connect_from_config`]. The two are independent — there is no
/// bridging seam between them. Phase B's U6 cutover deletes the legacy
/// path and renames this function to drop the `_seaorm` suffix.
///
/// PRAGMAs on `SQLite` flow through `ConnectOptions::map_sqlx_sqlite_opts`,
/// matching the `journal_mode` / `synchronous` / `busy_timeout` /
/// `cache_size` / `temp_store` / `foreign_keys` set the legacy path
/// configures on `SqliteConnectOptions`. Behavior parity with
/// [`connect_from_config`] is the design goal — the runtime should see
/// the same database modulo the API surface.
pub async fn connect_from_config_seaorm(config: &Config) -> Result<DatabaseConnection, DbError> {
    let cfg = &config.database;
    let url = build_seaorm_url(cfg)?;
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
    smoke_query_seaorm(&db).await?;
    Ok(db)
}

/// Cheap smoke query against a `SeaORM` connection. `SELECT 1` survives
/// dialect differences; runs via `query_one_raw` so we don't depend on
/// any application schema.
async fn smoke_query_seaorm(db: &DatabaseConnection) -> Result<(), DbError> {
    use sea_orm::ConnectionTrait;

    let backend = db.get_database_backend();
    let stmt = Statement::from_string(backend, "SELECT 1".to_string());
    db.query_one_raw(stmt).await?;
    Ok(())
}

fn build_seaorm_url(cfg: &DatabaseConfig) -> Result<String, DbError> {
    match cfg.db_type {
        DatabaseType::Sqlite => {
            let path = cfg
                .path
                .as_deref()
                .filter(|p| !p.is_empty())
                .ok_or(DbError::Misconfigured {
                    kind: "type",
                    required: "sqlite (database.path)",
                })?;
            // sqlx-sqlite accepts `sqlite::memory:` and `sqlite:filename`;
            // the legacy `open_sqlite` builds `SqliteConnectOptions` from
            // a bare filename, so passing the path verbatim through the
            // `sqlite:` scheme matches that behavior. `create_if_missing`
            // applies in the `map_sqlx_sqlite_opts` callback above.
            if path == ":memory:" {
                Ok("sqlite::memory:".to_string())
            } else {
                Ok(format!("sqlite:{path}"))
            }
        }
        DatabaseType::Postgres => {
            let url = cfg
                .url
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
