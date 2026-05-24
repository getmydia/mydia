// Opt this module into the disallowed-methods lint. The SQLite arm
// writes to `mydia_runtime_lock` — a table mydia-rs creates itself
// (the ONE schema write the rewrite is allowed to make per the plan's
// scope boundary). It doesn't exist in the Postgres prepare DB, so
// those queries can't go through `sqlx::query!`. They stay runtime
// with a documented `#[allow]` per call. The Postgres pg_advisory_lock
// queries DO go through the macros — those are tier (a).
#![warn(clippy::disallowed_methods)]

//! Boot-time mutual exclusion lock.
//!
//! Prevents two mydia-rs instances (or, once Phoenix grows the
//! symmetric mirror, a Phoenix + mydia-rs pair) from running against
//! the same database at the same time. Without this, the cutover and
//! parallel-window scenarios where an operator accidentally boots both
//! backends would result in cross-backend writes corrupting in-flight
//! state (orphaned HLS sessions, double-claimed pairing codes,
//! conflicting Oban-vs-apalis cron firings).
//!
//! - **Postgres**: `pg_try_advisory_lock(<LOCK_KEY>)` against a
//!   dedicated long-lived session. The lock releases automatically
//!   when the session ends, so no heartbeat is required. Phoenix
//!   doesn't take this advisory lock today, so the guard is one-way:
//!   mydia-rs refuses when another mydia-rs is alive, but does not
//!   yet refuse against a running Phoenix.
//!
//! - **`SQLite`**: `mydia_runtime_lock` table with a single row keyed
//!   on `LOCK_KEY_NAME`. INSERT-with-PRIMARY-KEY is the atomic claim;
//!   if it fails because the row exists, we check the recorded
//!   `heartbeat_at` against `STALE_AFTER` and either give up or
//!   reclaim. A background task heartbeats every `HEARTBEAT_EVERY`;
//!   on clean `release().await`, the row is `DELETEd`. This is the one
//!   schema write mydia-rs performs against the shared database, and
//!   only via `CREATE TABLE IF NOT EXISTS` (idempotent, doesn't
//!   collide with anything Phoenix owns).

use std::time::Duration;

use chrono::{DateTime, Utc};
use sqlx::pool::PoolConnection;
use sqlx::Postgres;
use tokio::task::JoinHandle;
use tokio::time::interval;

use mydia_rs_db::Db;

/// Postgres advisory-lock key. Constant so every mydia-rs build
/// competes for the same slot. The high bits are ASCII "`mydia_rs`"
/// for human readability in `pg_locks`.
const LOCK_KEY: i64 = 0x6d79_6469_615f_7273;

/// `SQLite` lock-row primary key.
const LOCK_KEY_NAME: &str = "mydia-rs-singleton";

/// Heartbeat cadence and staleness threshold. Three missed heartbeats
/// before a competitor reclaims, matching the plan's 30s window.
const HEARTBEAT_EVERY: Duration = Duration::from_secs(10);
const STALE_AFTER: Duration = Duration::from_secs(30);

#[derive(Debug, thiserror::Error)]
pub enum RuntimeLockError {
    #[error(
        "another mydia or mydia-rs instance is running against this database; refusing to start"
    )]
    Held,

    #[error("database error while acquiring runtime lock: {0}")]
    Sqlx(Box<sqlx::Error>),

    #[error("runtime lock failed: {0}")]
    Other(String),
}

impl From<sqlx::Error> for RuntimeLockError {
    fn from(err: sqlx::Error) -> Self {
        Self::Sqlx(Box::new(err))
    }
}

/// Handle owning the acquired lock. Holds the backing connection
/// (Postgres) or the heartbeat task (`SQLite`) until either
/// [`Self::release`] is awaited or it is dropped.
///
/// `release().await` is the clean path. On `Drop` we best-effort
/// abort the heartbeat task / drop the connection; the `SQLite` row
/// remains until the next process times it out via `STALE_AFTER`.
#[must_use = "lock is released on drop; bind it to a variable for the lifetime of the process"]
pub struct RuntimeLockHandle {
    inner: Inner,
}

impl std::fmt::Debug for RuntimeLockHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.inner {
            Inner::Postgres(_) => f
                .debug_struct("RuntimeLockHandle")
                .field("backend", &"postgres")
                .finish(),
            Inner::Sqlite { released, .. } => f
                .debug_struct("RuntimeLockHandle")
                .field("backend", &"sqlite")
                .field("released", released)
                .finish(),
        }
    }
}

enum Inner {
    Postgres(Option<PoolConnection<Postgres>>),
    Sqlite {
        heartbeat: Option<JoinHandle<()>>,
        pool: sqlx::SqlitePool,
        released: bool,
    },
}

impl RuntimeLockHandle {
    /// Cleanly release the lock. Heartbeats stop, the lock row (sqlite)
    /// or session (postgres) is dropped, and any backing connection
    /// returns to the pool. Idempotent.
    pub async fn release(mut self) -> Result<(), RuntimeLockError> {
        match &mut self.inner {
            Inner::Postgres(conn) => {
                if let Some(mut c) = conn.take() {
                    // pg_advisory_unlock is best-effort; closing the
                    // connection releases the lock unconditionally.
                    // `SELECT pg_advisory_unlock(...)` is treated as a
                    // row-returning query by the macro, so use
                    // `fetch_optional` (we don't care about the bool).
                    let _ = sqlx::query_scalar!("SELECT pg_advisory_unlock($1)", LOCK_KEY)
                        .fetch_optional(&mut *c)
                        .await;
                }
            }
            Inner::Sqlite {
                heartbeat,
                pool,
                released,
            } => {
                if let Some(handle) = heartbeat.take() {
                    handle.abort();
                }
                if !*released {
                    // SQLite-only table; not in PG prepare schema so can't
                    // be macro-checked. Runtime form is the only option.
                    #[allow(clippy::disallowed_methods)]
                    sqlx::query("DELETE FROM mydia_runtime_lock WHERE lock_key = ?")
                        .bind(LOCK_KEY_NAME)
                        .execute(&*pool)
                        .await?;
                    *released = true;
                }
            }
        }
        Ok(())
    }
}

impl Drop for RuntimeLockHandle {
    fn drop(&mut self) {
        if let Inner::Sqlite { heartbeat, .. } = &mut self.inner {
            if let Some(handle) = heartbeat.take() {
                handle.abort();
            }
        }
    }
}

/// Try to acquire the singleton runtime lock for the lifetime of the
/// returned handle. Returns [`RuntimeLockError::Held`] when another
/// instance already holds it.
pub async fn acquire(db: &Db) -> Result<RuntimeLockHandle, RuntimeLockError> {
    match db {
        Db::Postgres(pool) => acquire_postgres(pool.clone()).await,
        Db::Sqlite(pool) => acquire_sqlite(pool.clone()).await,
    }
}

async fn acquire_postgres(pool: sqlx::PgPool) -> Result<RuntimeLockHandle, RuntimeLockError> {
    let mut conn = pool.acquire().await?;
    let got: Option<bool> = sqlx::query_scalar!("SELECT pg_try_advisory_lock($1)", LOCK_KEY)
        .fetch_one(&mut *conn)
        .await?;

    if !got.unwrap_or(false) {
        return Err(RuntimeLockError::Held);
    }

    tracing::info!(lock_key = LOCK_KEY, "acquired postgres advisory lock");
    Ok(RuntimeLockHandle {
        inner: Inner::Postgres(Some(conn)),
    })
}

async fn acquire_sqlite(pool: sqlx::SqlitePool) -> Result<RuntimeLockHandle, RuntimeLockError> {
    ensure_lock_table(&pool).await?;
    let now = Utc::now();
    sweep_stale(&pool, now).await?;
    insert_claim(&pool, now).await?;

    let heartbeat = spawn_heartbeat(pool.clone());

    tracing::info!("acquired sqlite runtime lock");
    Ok(RuntimeLockHandle {
        inner: Inner::Sqlite {
            heartbeat: Some(heartbeat),
            pool,
            released: false,
        },
    })
}

async fn ensure_lock_table(pool: &sqlx::SqlitePool) -> Result<(), RuntimeLockError> {
    // DDL — sqlx macros cannot validate this regardless of dialect.
    // Plus the table is SQLite-only (Phoenix uses pg_advisory_lock on PG).
    #[allow(clippy::disallowed_methods)]
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS mydia_runtime_lock (
            lock_key TEXT PRIMARY KEY,
            pid INTEGER NOT NULL,
            hostname TEXT,
            backend TEXT NOT NULL,
            started_at TEXT NOT NULL,
            heartbeat_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await?;
    Ok(())
}

async fn sweep_stale(pool: &sqlx::SqlitePool, now: DateTime<Utc>) -> Result<(), RuntimeLockError> {
    let cutoff = now - chrono::Duration::from_std(STALE_AFTER).expect("stale threshold fits");
    // SQLite-only table; can't macro-check.
    #[allow(clippy::disallowed_methods)]
    sqlx::query("DELETE FROM mydia_runtime_lock WHERE lock_key = ? AND heartbeat_at < ?")
        .bind(LOCK_KEY_NAME)
        .bind(cutoff.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
        .execute(pool)
        .await?;
    Ok(())
}

async fn insert_claim(pool: &sqlx::SqlitePool, now: DateTime<Utc>) -> Result<(), RuntimeLockError> {
    let now_iso = now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let pid = i64::from(std::process::id());
    let hostname = hostname();

    // SQLite-only table; can't macro-check.
    #[allow(clippy::disallowed_methods)]
    let result = sqlx::query(
        "INSERT INTO mydia_runtime_lock
            (lock_key, pid, hostname, backend, started_at, heartbeat_at)
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(LOCK_KEY_NAME)
    .bind(pid)
    .bind(hostname.as_deref())
    .bind("mydia-rs")
    .bind(&now_iso)
    .bind(&now_iso)
    .execute(pool)
    .await;

    match result {
        Ok(_) => Ok(()),
        Err(sqlx::Error::Database(dberr)) => {
            // SQLite raises a UNIQUE / PRIMARY KEY violation when the
            // row already exists. That's exactly the "another process
            // holds the lock and it isn't stale enough to sweep" path.
            if dberr
                .code()
                .as_deref()
                .is_some_and(|c| c.starts_with("2067") || c.starts_with("1555"))
                || dberr.message().contains("UNIQUE")
                || dberr.message().contains("PRIMARY KEY")
            {
                Err(RuntimeLockError::Held)
            } else {
                Err(RuntimeLockError::Sqlx(Box::new(sqlx::Error::Database(
                    dberr,
                ))))
            }
        }
        Err(err) => Err(RuntimeLockError::Sqlx(Box::new(err))),
    }
}

fn spawn_heartbeat(pool: sqlx::SqlitePool) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = interval(HEARTBEAT_EVERY);
        // First tick fires immediately; skip it so we don't UPDATE
        // the row we just inserted.
        ticker.tick().await;
        loop {
            ticker.tick().await;
            let now_iso = Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
            // SQLite-only table; can't macro-check.
            #[allow(clippy::disallowed_methods)]
            let res =
                sqlx::query("UPDATE mydia_runtime_lock SET heartbeat_at = ? WHERE lock_key = ?")
                    .bind(&now_iso)
                    .bind(LOCK_KEY_NAME)
                    .execute(&pool)
                    .await;
            if let Err(err) = res {
                tracing::warn!(%err, "runtime-lock heartbeat update failed");
            }
        }
    })
}

fn hostname() -> Option<String> {
    // Best-effort: HOSTNAME is reliable on the Linux container and dev
    // platforms mydia-rs targets. We don't pull in a uname crate just
    // for the lock row.
    std::env::var("HOSTNAME").ok().filter(|s| !s.is_empty())
}
