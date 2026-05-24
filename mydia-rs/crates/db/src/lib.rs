//! Database access layer.
//!
//! Post-U6 cutover: the workspace's data API is `SeaORM`-only. The legacy
//! `Db` enum, `from_sqlx_*_pool` bridging, and direct sqlx call sites
//! are gone. Every consumer crate threads [`DatabaseConnection`] through
//! repo / service function signatures, and writes against wrapper-typed
//! columns go through [`insert_active_model`] / [`update_active_model`].
//!
//! - [`pool`] owns [`pool::connect_from_config`], the single entry point
//!   for opening a database, plus the cheap `SELECT 1` smoke query.
//! - [`types`] holds the cross-engine wrapper types (`UuidText`,
//!   `DateTimeSecs`, `DateTimeMicros`, `JsonMap`, `StringArray`). Each
//!   carries `From<W> for Value` + custom engine-branched [`TryGetable`]
//!   + an `into_simple_expr(backend)` write helper. Phoenix and mydia-rs
//!   read each other's rows unchanged through these.
//! - [`insert_helper`] exposes [`insert_active_model`] and
//!   [`update_active_model`] — the workspace's write API for any
//!   `ActiveModel` whose entity has at least one wrapper-typed column.
//!   Vanilla `ActiveModelTrait::insert` and `::update` are forbidden by
//!   the workspace `clippy.toml`; this helper threads the engine-aware
//!   cast templates onto every wrapper column.
//! - [`schema_check`] runs the boot-time `schema_migrations` probe.

pub mod insert_helper;
pub mod pool;
pub mod schema_check;
pub mod types;

mod error;

pub use error::DbError;
pub use insert_helper::{insert_active_model, update_active_model};
pub use pool::{connect_from_config, smoke_query};
pub use schema_check::{schema_check, SchemaCheckOutcome, MAX_KNOWN_MIGRATION};

// `SeaORM` connection type re-export. Phase B conversion units thread this
// type through repo / service function signatures so consumer crates
// don't need to take a direct sea-orm dependency until they convert.
pub use sea_orm::DatabaseConnection;
