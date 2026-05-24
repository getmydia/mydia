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
//! **Engine scope:** `SQLite`-only. The `mydia_runtime_lock` table is
//! the one schema write mydia-rs performs against the shared database,
//! and only via `CREATE TABLE IF NOT EXISTS` (idempotent, doesn't
//! collide with anything Phoenix owns). On Postgres, mutual exclusion
//! is delegated to Phoenix's own advisory-lock surface; the mydia-rs
//! boot path guards `acquire` behind a `db.get_database_backend() ==
//! DbBackend::Sqlite` check at the call site (the one allowed runtime
//! backend check in the codebase, gating an entire feature).
//!
//! **Mechanism (`SQLite`):** `mydia_runtime_lock` table with a single
//! row keyed on `LOCK_KEY_NAME`. INSERT-with-PRIMARY-KEY is the atomic
//! claim; if it fails because the row exists, we check the recorded
//! `heartbeat_at` against `STALE_AFTER` and either give up or reclaim.
//! A background task heartbeats every `HEARTBEAT_EVERY`; on clean
//! `release().await`, the row is `DELETEd`.

use std::time::Duration;

use chrono::{DateTime, Utc};
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{
    ColumnTrait, ConnectionTrait, DatabaseConnection, DbBackend, DbErr, EntityTrait, QueryFilter,
    Set, Statement,
};
use tokio::task::JoinHandle;
use tokio::time::interval;

use mydia_rs_db::types::DateTimeSecs;
use mydia_rs_entities::mydia_runtime_lock;

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
    Db(Box<DbErr>),

    #[error("runtime lock failed: {0}")]
    Other(String),
}

impl From<DbErr> for RuntimeLockError {
    fn from(err: DbErr) -> Self {
        Self::Db(Box::new(err))
    }
}

/// Handle owning the acquired `SQLite` lock. Holds the heartbeat task
/// until either [`Self::release`] is awaited or it is dropped.
///
/// `release().await` is the clean path. On `Drop` we best-effort
/// abort the heartbeat task; the `SQLite` row remains until the next
/// process times it out via `STALE_AFTER`.
#[must_use = "lock is released on drop; bind it to a variable for the lifetime of the process"]
pub struct RuntimeLockHandle {
    heartbeat: Option<JoinHandle<()>>,
    db: DatabaseConnection,
    released: bool,
}

impl std::fmt::Debug for RuntimeLockHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RuntimeLockHandle")
            .field("backend", &"sqlite")
            .field("released", &self.released)
            .finish()
    }
}

impl RuntimeLockHandle {
    /// Cleanly release the lock. The heartbeat stops and the lock row is
    /// deleted. Idempotent.
    pub async fn release(mut self) -> Result<(), RuntimeLockError> {
        if let Some(handle) = self.heartbeat.take() {
            handle.abort();
        }
        if !self.released {
            mydia_runtime_lock::Entity::delete_many()
                .filter(mydia_runtime_lock::Column::LockKey.eq(LOCK_KEY_NAME))
                .exec(&self.db)
                .await?;
            self.released = true;
        }
        Ok(())
    }
}

impl Drop for RuntimeLockHandle {
    fn drop(&mut self) {
        if let Some(handle) = self.heartbeat.take() {
            handle.abort();
        }
    }
}

/// Try to acquire the singleton runtime lock for the lifetime of the
/// returned handle. Returns [`RuntimeLockError::Held`] when another
/// instance already holds it.
///
/// **Caller responsibility:** this function is `SQLite`-only. The
/// caller (currently `mydia-rs-app::main::bootstrap`) gates the call
/// with `db.get_database_backend() == DbBackend::Sqlite` — the one
/// allowed runtime backend check in the codebase, gating the entire
/// feature rather than constructing per-engine SQL. Invoking on
/// Postgres returns [`RuntimeLockError::Other`].
pub async fn acquire(db: &DatabaseConnection) -> Result<RuntimeLockHandle, RuntimeLockError> {
    if db.get_database_backend() != DbBackend::Sqlite {
        return Err(RuntimeLockError::Other(
            "runtime_lock is SQLite-only; caller must gate on db.get_database_backend()".into(),
        ));
    }

    ensure_lock_table(db).await?;
    let now = Utc::now();
    sweep_stale(db, now).await?;
    insert_claim(db, now).await?;

    let heartbeat = spawn_heartbeat(db.clone());

    tracing::info!("acquired sqlite runtime lock");
    Ok(RuntimeLockHandle {
        heartbeat: Some(heartbeat),
        db: db.clone(),
        released: false,
    })
}

async fn ensure_lock_table(db: &DatabaseConnection) -> Result<(), RuntimeLockError> {
    // TODO(U18): replace this raw DDL with
    // `Schema::create_table_from_entity(mydia_runtime_lock::Entity)`.
    // U9 deliberately leaves the CREATE TABLE in raw form so the
    // SeaORM-native DDL emission lands as one focused unit alongside
    // the tower-sessions table conversion. Until then, the schema
    // shape is mirrored by hand against the entity in
    // `mydia-rs-entities/src/mydia_runtime_lock.rs`.
    let stmt = Statement::from_string(
        DbBackend::Sqlite,
        "CREATE TABLE IF NOT EXISTS mydia_runtime_lock (
            lock_key TEXT PRIMARY KEY,
            pid INTEGER NOT NULL,
            hostname TEXT,
            backend TEXT NOT NULL,
            started_at TEXT NOT NULL,
            heartbeat_at TEXT NOT NULL
        )"
        .to_string(),
    );
    db.execute(stmt).await?;
    Ok(())
}

async fn sweep_stale(db: &DatabaseConnection, now: DateTime<Utc>) -> Result<(), RuntimeLockError> {
    let cutoff = now - chrono::Duration::from_std(STALE_AFTER).expect("stale threshold fits");
    let cutoff_wrapper = DateTimeSecs::from(cutoff);
    let backend = db.get_database_backend();
    mydia_runtime_lock::Entity::delete_many()
        .filter(mydia_runtime_lock::Column::LockKey.eq(LOCK_KEY_NAME))
        .filter(
            Expr::col(mydia_runtime_lock::Column::HeartbeatAt)
                .lt(cutoff_wrapper.into_simple_expr(backend)),
        )
        .exec(db)
        .await?;
    Ok(())
}

async fn insert_claim(db: &DatabaseConnection, now: DateTime<Utc>) -> Result<(), RuntimeLockError> {
    let now_wrapper = DateTimeSecs::from(now);
    let pid = i32::try_from(std::process::id()).unwrap_or(i32::MAX);
    let hostname_value = hostname();

    let am = mydia_runtime_lock::ActiveModel {
        lock_key: Set(LOCK_KEY_NAME.to_owned()),
        pid: Set(pid),
        hostname: Set(hostname_value),
        backend: Set("mydia-rs".to_owned()),
        started_at: Set(now_wrapper),
        heartbeat_at: Set(now_wrapper),
    };

    match mydia_rs_db::insert_active_model(am, db).await {
        Ok(_) => Ok(()),
        Err(err) => {
            // SQLite raises a UNIQUE / PRIMARY KEY violation when the
            // row already exists. That's exactly the "another process
            // holds the lock and it isn't stale enough to sweep" path.
            // SeaORM bubbles the sqlx error message through `DbErr::Exec`
            // / `DbErr::Query`, so we sniff the rendered string for the
            // SQLite-specific markers.
            if is_unique_violation(&err) {
                Err(RuntimeLockError::Held)
            } else {
                Err(RuntimeLockError::Db(Box::new(err)))
            }
        }
    }
}

fn is_unique_violation(err: &DbErr) -> bool {
    let msg = err.to_string();
    msg.contains("UNIQUE")
        || msg.contains("PRIMARY KEY")
        // SQLite error codes 2067 (SQLITE_CONSTRAINT_UNIQUE) and
        // 1555 (SQLITE_CONSTRAINT_PRIMARYKEY) — surfaced via sqlx's
        // `code` propagation when present.
        || msg.contains("2067")
        || msg.contains("1555")
}

fn spawn_heartbeat(db: DatabaseConnection) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = interval(HEARTBEAT_EVERY);
        // First tick fires immediately; skip it so we don't UPDATE
        // the row we just inserted.
        ticker.tick().await;
        loop {
            ticker.tick().await;
            let backend = db.get_database_backend();
            let now_wrapper = DateTimeSecs::from(Utc::now());
            let res = mydia_runtime_lock::Entity::update_many()
                .col_expr(
                    mydia_runtime_lock::Column::HeartbeatAt,
                    now_wrapper.into_simple_expr(backend),
                )
                .filter(mydia_runtime_lock::Column::LockKey.eq(LOCK_KEY_NAME))
                .exec(&db)
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
