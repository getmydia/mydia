//! Runtime-dispatched apalis storage backed by the active [`Db`] pool.
//!
//! apalis 0.7's storage types ([`apalis_sql::sqlite::SqliteStorage`] and
//! [`apalis_sql::postgres::PostgresStorage`]) are concrete per backend.
//! The crate-level [`Db`] enum already runtime-selects sqlx pools;
//! [`JobStorage`] mirrors that shape so callers can enqueue and operate
//! a queue without branching on the backend at every call site.
//!
//! ## Scope at U15
//!
//! Only the enqueue + setup surface lands here. Worker dispatch — the
//! `monitor.run()` / `WorkerBuilder` integration — comes with the
//! actual worker structs in U17, when there's something to dispatch.
//! The shape of the per-backend `WorkerBuilder` differs enough that
//! abstracting it without a concrete worker is premature; U17 wires
//! each worker type once and uses `match db { ... }` at the wiring
//! site.

use std::marker::PhantomData;

use apalis_sql::postgres::PostgresStorage;
use apalis_sql::sqlite::SqliteStorage;
use mydia_rs_db::Db;
use serde::{de::DeserializeOwned, Serialize};
use thiserror::Error;

/// Runtime-dispatched apalis storage for a single job type `T`.
///
/// Construct via [`Self::from_db`]; the variant is selected by the
/// underlying pool, not by the caller. Callers that need to inspect
/// the backend (e.g., to apply a Postgres `LISTEN` subscription for
/// faster pickup) pattern-match on the enum.
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
}

impl<T> JobStorage<T>
where
    T: Serialize + DeserializeOwned + Send + Sync + Unpin + 'static,
{
    /// Build a storage for `T` against the active [`Db`] backend. The
    /// returned storage is ready to `push()` jobs; the backing table
    /// (`Jobs` on `SQLite`, `apalis.jobs` on Postgres) must already exist
    /// — call [`setup`] once at app boot before any workers attach.
    #[must_use]
    pub fn from_db(db: &Db) -> Self {
        match db {
            Db::Sqlite(pool) => Self::Sqlite(SqliteStorage::new(pool.clone())),
            Db::Postgres(pool) => Self::Postgres(PostgresStorage::new(pool.clone())),
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

/// Run the apalis-sql migration set against the active [`Db`]. Idempotent
/// — re-running creates no rows. Must be called once at boot, before
/// the first push.
///
/// Phoenix's Oban tables (`oban_jobs`, `oban_peers`, `oban_producers`)
/// are independent — apalis writes to its own tables (`Jobs` on
/// `SQLite`, `apalis.jobs` on Postgres) and never touches Oban's. The two
/// can coexist in the same DB during the parallel window. See the
/// "apalis vs Oban table coexistence" section in the rewrite plan for
/// the full reasoning.
pub async fn setup(db: &Db) -> Result<(), JobsError> {
    // The type parameter is irrelevant for the migration; we use `()`
    // to satisfy the generics on the bare `setup` constructor.
    match db {
        Db::Sqlite(pool) => {
            SqliteStorage::setup(pool).await.map_err(JobsError::Setup)?;
        }
        Db::Postgres(pool) => {
            PostgresStorage::setup(pool)
                .await
                .map_err(JobsError::Setup)?;
        }
    }
    Ok(())
}

/// Type-erased handle used in registries that want to keep storages
/// for multiple job types side-by-side without naming each `T`. Mostly
/// useful as a future seam — U17's supervision-tree code builds a
/// vector of trait objects to iterate over for shutdown / metrics.
///
/// Currently unimplemented at U15 (no workers exist yet); kept as a
/// shape declaration so U17 can fill it in without renaming.
#[allow(dead_code)]
struct _Erased<T> {
    _phantom: PhantomData<T>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use mydia_rs_db::Db;
    use serde::Deserialize;
    use sqlx::sqlite::SqlitePoolOptions;

    #[derive(Debug, Clone, Serialize, Deserialize)]
    struct TestJob {
        payload: String,
    }

    async fn sqlite_db() -> Db {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("open in-memory sqlite");
        Db::Sqlite(pool)
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
