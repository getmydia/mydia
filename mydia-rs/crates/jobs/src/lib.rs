//! apalis-backed background jobs for mydia-rs.
//!
//! ## Scope at U15
//!
//! - [`queues`] — the nine queue identifiers and per-queue concurrency
//!   caps mirroring `config/config.exs` Oban config.
//! - [`cron`] — the fourteen cron entries mirroring
//!   `config/config.exs:270-300`.
//! - [`storage`] — runtime-dispatched apalis storage backed by the
//!   sqlx pool extracted from the active SeaORM `DatabaseConnection`.
//!
//! ## Scope at U17 (next)
//!
//! - 24 worker structs ported from `lib/mydia/jobs/`, each with a
//!   serde-deserializable args struct and a Tower service `handle` fn.
//! - The supervision-tree wire-up: a `Monitor` per queue with
//!   `WorkerBuilder::new(...).backend(storage).build_fn(handle)`,
//!   joined with apalis-cron streams for the cron entries.
//! - Telemetry shim: subscribe to apalis worker events, re-publish on
//!   the [`mydia_rs_pubsub::topics::JOBS_STATUS`] pubsub topic so the
//!   admin Jobs `LiveView` in U28 mirrors the Oban analog from
//!   `Mydia.Jobs.Broadcaster`.

pub mod broadcaster;
pub mod context;
pub mod cron;
pub mod queues;
pub mod storage;
pub mod supervisor;
pub mod workers;

pub use broadcaster::make_handler as broadcaster_handler;
pub use context::AppContext;
pub use cron::{schedule, CronEntry, CronError, WorkerName};
pub use queues::Queue;
pub use storage::{setup, JobStorage, JobsError};
pub use supervisor::Supervisor;
