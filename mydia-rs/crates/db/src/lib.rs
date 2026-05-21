//! sqlx-backed database access layer with dual SQLite/Postgres support.
//!
//! - [`pool`] owns the [`Db`] enum that callers route every query through.
//! - [`dialect`] mirrors the macros from `lib/mydia/db.ex`. Each helper
//!   returns a SQL fragment for the chosen [`Dialect`], so dialect-divergent
//!   queries (JSON extract, datetime arithmetic, casts) stay readable at
//!   the call site.
//! - [`types`] holds `sqlx::Type` impls matching the on-disk format Ecto
//!   actually writes — TEXT-UUID and RFC3339-Z datetimes on SQLite,
//!   native types on Postgres. Phoenix and mydia-rs read each other's
//!   rows unchanged through these.
//! - [`schema_check`] runs the boot-time `schema_migrations` probe so
//!   mydia-rs refuses to start against a DB Phoenix has migrated past
//!   what this binary understands.
//!
//! sqlx query macros (`query!`, `query_as!`) are not used inside this
//! crate; the smoke query and the schema probe go through runtime
//! `sqlx::query`. Model crates that ship typed structs in U5+ pick which
//! tier (portable vs dialect-divergent) per query. See `db/README.md` for
//! the policy.

pub mod dialect;
pub mod pool;
pub mod schema_check;
pub mod types;

mod error;

pub use dialect::Dialect;
pub use error::DbError;
pub use pool::{connect_from_config, Db};
pub use schema_check::{schema_check, SchemaCheckOutcome, MAX_KNOWN_MIGRATION};
