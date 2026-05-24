//! Supervision tree wire-up helpers.
//!
//! Owns the apalis [`Monitor`] that hosts every worker. Three rules:
//!
//! 1. **One storage per worker type.** Each worker's args type is a
//!    distinct `T`; apalis-sql parameterizes [`JobStorage`] by `T`,
//!    so each worker type owns its own storage. They all share the
//!    same underlying [`Db`] pool.
//! 2. **Per-queue concurrency.** [`Queue::concurrency`] is forwarded
//!    to `WorkerBuilder::concurrency(n)`; the cap matches Oban's
//!    queue config so cross-backend behavior at cutover stays
//!    identical.
//! 3. **Cron entries register dedicated workers.** Each
//!    [`crate::cron::CronEntry`] becomes a
//!    [`apalis_cron::CronStream::new(schedule)`] backend paired with
//!    the matching worker fn. apalis schedules the ticks; the worker
//!    reads settings fresh from the DB at every fire.
//!
//! Graceful shutdown: callers pass a `Future` that resolves on the
//! signal of their choice (`tokio::signal::ctrl_c()`, an axum
//! shutdown signal, ...) to [`Supervisor::run_with_signal`]. apalis's
//! `Monitor` drains in-flight tasks before exiting.
//!
//! ## Why the wire-up is split across this crate and the boot site
//!
//! apalis 0.7's `WorkerBuilder::backend(...)` and `.build_fn(handler)`
//! produce types whose generic parameters depend on every layer in
//! the stack. A single helper that erased every `T` would have to
//! lean on `Box<dyn ...>` for the inner future, which loses the
//! tower middleware composition the rest of apalis is built on.
//!
//! Instead, this crate exposes:
//! - [`Supervisor::new`] — wraps a bare apalis [`Monitor`] and
//!   attaches the broadcaster shim.
//! - [`Supervisor::into_monitor`] — hand the monitor to the boot
//!   site, which can call `register()` per worker with the
//!   apalis-recommended inline `WorkerBuilder::new(...).build_fn(...)`
//!   chain (see `bin/mydia-rs-cli/src/server.rs`).
//!
//! For test scenarios that want a working supervisor without the full
//! boot path, [`Supervisor::run`] and
//! [`Supervisor::run_with_signal`] are still available.

use apalis::prelude::Monitor;
use sea_orm::DatabaseConnection;

use mydia_rs_pubsub::Pubsub;

use crate::broadcaster;
use crate::storage::{self, JobsError};

/// Public handle to the configured monitor.
pub struct Supervisor {
    monitor: Monitor,
}

impl std::fmt::Debug for Supervisor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Supervisor")
            .field("monitor", &"Monitor { .. }")
            .finish()
    }
}

impl Supervisor {
    /// Build a fresh supervisor with the broadcaster shim attached.
    ///
    /// The `Monitor` has `Monitor::on_event(broadcaster::make_handler(pubsub))`
    /// already wired, so every worker registered against it
    /// automatically publishes lifecycle events on the
    /// [`mydia_rs_pubsub::topics::JOBS_STATUS`] topic.
    #[must_use]
    pub fn new(pubsub: Pubsub) -> Self {
        let monitor = Monitor::new().on_event(broadcaster::make_handler(pubsub));
        Self { monitor }
    }

    /// Set up the apalis-sql migration set against the active
    /// `SeaORM` connection. Convenience wrapper — equivalent to calling
    /// [`storage::setup`] directly.
    pub async fn setup(db: &DatabaseConnection) -> Result<(), JobsError> {
        storage::setup(db).await
    }

    /// Hand the underlying apalis [`Monitor`] to the caller so it can
    /// `register()` each worker.
    ///
    /// The caller is expected to chain `WorkerBuilder::new(name)
    ///     .data(ctx.clone())
    ///     .concurrency(Queue::Foo.concurrency())
    ///     .backend(JobStorage::from_db(&db).as_sqlite_or_postgres())
    ///     .build_fn(workers::foo::foo)` per worker, registering each on
    /// the monitor.
    #[must_use]
    pub fn into_monitor(self) -> Monitor {
        self.monitor
    }

    /// Replace the wrapped monitor — typically after the caller
    /// chained `register(...)` calls.
    #[must_use]
    pub fn with_monitor(mut self, monitor: Monitor) -> Self {
        self.monitor = monitor;
        self
    }

    /// Run the monitor until completion. Returns when every worker
    /// has drained.
    pub async fn run(self) -> std::io::Result<()> {
        self.monitor.run().await
    }

    /// Run the monitor and stop gracefully when `signal` resolves.
    /// Equivalent to Phoenix's OTP application shutdown hook.
    pub async fn run_with_signal<S>(self, signal: S) -> std::io::Result<()>
    where
        S: Send + std::future::Future<Output = std::io::Result<()>>,
    {
        self.monitor.run_with_signal(signal).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mydia_rs_pubsub::Pubsub;

    #[tokio::test]
    async fn supervisor_constructs_and_returns_monitor() {
        let supervisor = Supervisor::new(Pubsub::new());
        let _monitor = supervisor.into_monitor();
    }
}
