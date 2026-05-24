//! Runtime-dispatched apalis storage backed by the active
//! [`DatabaseConnection`].
//!
//! apalis 0.7's storage types ([`apalis_sql::sqlite::SqliteStorage`] and
//! [`apalis_sql::postgres::PostgresStorage`]) are concrete per backend
//! and own their own tables (`Jobs` on `SQLite`, `apalis.jobs` on
//! Postgres). The jobs crate extracts the underlying `sqlx` pool from
//! the SeaORM `DatabaseConnection` via
//! [`DatabaseConnection::get_sqlite_connection_pool`] /
//! [`DatabaseConnection::get_postgres_connection_pool`] and hands it
//! to the per-backend storage constructor. [`JobStorage`] mirrors the
//! shape so callers can enqueue and operate a queue without branching
//! on the backend at every call site.
//!
//! ## Post-U12 cutover
//!
//! The workspace's data API is `SeaORM`-only — the `Db` enum is gone.
//! The apalis tables remain managed by apalis itself (its `setup()`
//! runs the apalis-sql migration set); they're independent of any
//! `oban_jobs` row in the Phoenix-owned schema. Workers reach for
//! application tables through the SeaORM entities + `insert_active_model`
//! / `update_active_model` helpers, never raw sqlx.

use std::marker::PhantomData;

use apalis_sql::postgres::PostgresStorage;
use apalis_sql::sqlite::SqliteStorage;
use sea_orm::{DatabaseConnection, DbBackend};
use serde::{de::DeserializeOwned, Serialize};
use thiserror::Error;

/// Runtime-dispatched apalis storage for a single job type `T`.
///
/// Construct via [`Self::from_db`]; the variant is selected by the
/// underlying SeaORM backend, not by the caller. Callers that need to
/// inspect the backend (e.g., to apply a Postgres `LISTEN`
/// subscription for faster pickup) pattern-match on the enum.
#[derive(Debug, Clone)]
pub enum JobStorage<T> {
    Sqlite(SqliteStorage<T>),
    Postgres(PostgresStorage<T>),
}

#[derive(Debug, Error)]
pub enum JobsError {
    /// The apalis-sql migration set failed to apply against the active
    /// pool. Most commonly: insufficient permissions in the configured
    /// Postgres role, or a read-only `SQLite` file.
    #[error("apalis storage setup failed: {0}")]
    Setup(#[source] sqlx::Error),

    /// Enqueue / fetch / update against the storage failed.
    #[error("apalis storage operation failed: {0}")]
    Storage(#[source] sqlx::Error),

    /// A row required by the worker (library path, media item, ...)
    /// could not be found. Mirrors Phoenix's `Ecto.NoResultsError`
    /// rescue at every worker entry point.
    #[error("required record not found: {0}")]
    NotFound(String),

    /// SeaORM error surfaced from a worker's DB call (not from the
    /// apalis storage). Distinct from `Storage` so callers can tell
    /// whether the job machinery or the worker's business logic
    /// broke.
    #[error("worker database error: {0}")]
    Db(#[from] sea_orm::DbErr),

    /// Per-worker business error wrapped as a string. Workers wrap
    /// `IntegrationError`, `IndexerError`, etc. into this when they
    /// don't care to preserve the inner type for the supervisor.
    #[error("worker error: {0}")]
    WorkerError(String),

    /// The worker requested apalis-style retry-with-backoff. apalis
    /// 0.7's `Retry` layer handles this transparently when the worker
    /// `Result::Err`s; this variant is a clearer call site for
    /// "transient — retry, don't error-page the operator".
    #[error("transient worker error (retryable): {0}")]
    Retryable(String),
}

impl<T> JobStorage<T>
where
    T: Serialize + DeserializeOwned + Send + Sync + Unpin + 'static,
{
    /// Build a storage for `T` against the active SeaORM connection.
    /// The returned storage is ready to `push()` jobs; the backing
    /// table (`Jobs` on `SQLite`, `apalis.jobs` on Postgres) must
    /// already exist — call [`setup`] once at app boot before any
    /// workers attach.
    #[must_use]
    pub fn from_db(db: &DatabaseConnection) -> Self {
        match db.get_database_backend() {
            DbBackend::Sqlite => {
                let pool = db.get_sqlite_connection_pool().clone();
                Self::Sqlite(SqliteStorage::new(pool))
            }
            DbBackend::Postgres => {
                let pool = db.get_postgres_connection_pool().clone();
                Self::Postgres(PostgresStorage::new(pool))
            }
            other => {
                panic!("unsupported backend for mydia-rs job storage: {other:?}");
            }
        }
    }

    /// Push a job onto the queue. Returns the `task_id` apalis
    /// generated for it (a `UUIDv4` in apalis 0.7) so callers can
    /// correlate enqueue with later status events.
    pub async fn push(&mut self, job: T) -> Result<String, JobsError> {
        use apalis::prelude::Storage;
        match self {
            Self::Sqlite(s) => {
                let parts = s.push(job).await.map_err(JobsError::Storage)?;
                Ok(parts.task_id.to_string())
            }
            Self::Postgres(s) => {
                let parts = s.push(job).await.map_err(JobsError::Storage)?;
                Ok(parts.task_id.to_string())
            }
        }
    }

    /// Current pending count. Useful for the admin Jobs page and the
    /// pre-cutover "drain Oban" / "drain apalis" checklist in U30.
    pub async fn len(&mut self) -> Result<i64, JobsError> {
        use apalis::prelude::Storage;
        match self {
            Self::Sqlite(s) => s.len().await.map_err(JobsError::Storage),
            Self::Postgres(s) => s.len().await.map_err(JobsError::Storage),
        }
    }

    /// Convenience wrapper around [`Self::len`] returning whether the
    /// queue is currently drained.
    pub async fn is_empty(&mut self) -> Result<bool, JobsError> {
        Ok(self.len().await? == 0)
    }
}

/// Run the apalis-sql migration set against the active connection.
/// Idempotent — re-running creates no rows. Must be called once at
/// boot, before the first push.
///
/// Phoenix's Oban tables (`oban_jobs`, `oban_peers`, `oban_producers`)
/// are independent — apalis writes to its own tables (`Jobs` on
/// `SQLite`, `apalis.jobs` on Postgres) and never touches Oban's. The
/// two can coexist in the same DB during the parallel window. See the
/// "apalis vs Oban table coexistence" section in the rewrite plan for
/// the full reasoning.
pub async fn setup(db: &DatabaseConnection) -> Result<(), JobsError> {
    // The type parameter is irrelevant for the migration; we use the
    // bare `setup` constructor on each storage type.
    match db.get_database_backend() {
        DbBackend::Sqlite => {
            let pool = db.get_sqlite_connection_pool();
            SqliteStorage::setup(pool).await.map_err(JobsError::Setup)?;
        }
        DbBackend::Postgres => {
            let pool = db.get_postgres_connection_pool();
            PostgresStorage::setup(pool)
                .await
                .map_err(JobsError::Setup)?;
        }
        other => {
            panic!("unsupported backend for mydia-rs job storage: {other:?}");
        }
    }
    Ok(())
}

/// Type-erased handle used in registries that want to keep storages
/// for multiple job types side-by-side without naming each `T`. Mostly
/// useful as a future seam — U17's supervision-tree code builds a
/// vector of trait objects to iterate over for shutdown / metrics.
///
/// Currently unimplemented (no workers exist yet); kept as a shape
/// declaration so the supervisor can fill it in without renaming.
#[allow(dead_code)]
struct _Erased<T> {
    _phantom: PhantomData<T>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use sea_orm::Database;
    use serde::Deserialize;

    #[derive(Debug, Clone, Serialize, Deserialize)]
    struct TestJob {
        payload: String,
    }

    async fn sqlite_db() -> DatabaseConnection {
        Database::connect("sqlite::memory:")
            .await
            .expect("open in-memory sqlite")
    }

    #[tokio::test]
    async fn from_db_dispatches_on_backend() {
        let db = sqlite_db().await;
        let storage: JobStorage<TestJob> = JobStorage::from_db(&db);
        assert!(matches!(storage, JobStorage::Sqlite(_)));
    }

    #[tokio::test]
    async fn setup_and_push_round_trip_sqlite() {
        let db = sqlite_db().await;
        setup(&db).await.expect("setup apalis migrations");

        let mut storage: JobStorage<TestJob> = JobStorage::from_db(&db);
        let len_before = storage.len().await.expect("len 0");
        assert_eq!(len_before, 0);

        let job = TestJob {
            payload: "hello".to_owned(),
        };
        let task_id = storage.push(job).await.expect("push job");
        assert!(!task_id.is_empty(), "task_id non-empty");

        let len_after = storage.len().await.expect("len 1");
        assert_eq!(len_after, 1);
    }
}
