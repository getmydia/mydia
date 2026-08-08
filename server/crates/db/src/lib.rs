//! SQLite storage for Mydia Server.
//!
//! This crate is the only one that writes application SQL. Background job
//! queue tables are managed by apalis in a later slice.

pub mod devices;
pub mod episodes;
pub mod library_paths;
pub mod media_items;
pub mod pool;
pub mod users;

/// A connection pool plus the invariant that migrations have been run.
#[derive(Clone, Debug)]
pub struct Db {
    pool: sqlx::SqlitePool,
}

#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error("could not connect to the database: {0}")]
    Connect(#[source] sqlx::Error),

    #[error("could not run migrations: {0}")]
    Migrate(#[source] sqlx::migrate::MigrateError),

    #[error("query failed: {0}")]
    Query(#[from] sqlx::Error),

    #[error("could not create a temporary directory: {0}")]
    TempDir(#[source] std::io::Error),

    #[error("`{value}` is not a library type; use movies, series or mixed")]
    InvalidLibraryType { value: String },
}
