//! Database access layer.
//!
//! Currently in the middle of the `SeaORM` cutover described in
//! `docs/plans/2026-05-24-001-refactor-seaorm-data-layer-unification-plan.md`.
//! During Phase A, both surfaces coexist: the legacy [`pool::Db`] enum and
//! sqlx-backed [`dialect`] / [`schema_check`] paths still serve in-flight
//! call sites, while [`types`], [`insert_helper`], and the new `SeaORM`
//! [`pool::connect_from_config_seaorm`] entry point land in
//! preparation for the U6 cutover.
//!
//! - [`pool`] owns the [`Db`] enum that legacy callers route every query
//!   through, plus the new `SeaORM` `connect_from_config_seaorm` entry
//!   point that Phase B converts to.
//! - [`dialect`] (scheduled for deletion in U4) mirrors the macros from
//!   `lib/mydia/db.ex` for dialect-divergent fragments.
//! - [`types`] holds the cross-engine wrapper types (`UuidText`,
//!   `DateTimeSecs`, `DateTimeMicros`, `JsonMap`, `StringArray`). Each
//!   carries both the legacy `sqlx::Type` impls and the `SeaORM`-native
//!   [`From<W> for Value`] + custom [`TryGetable`] + `into_simple_expr`
//!   write helper. Phoenix and mydia-rs read each other's rows unchanged
//!   through these.
//! - [`insert_helper`] exposes `insert_active_model` and
//!   `update_active_model` — the workspace's write API for any
//!   `ActiveModel` whose entity has at least one wrapper-typed column.
//!   Vanilla `ActiveModelTrait::insert` and `::update` are forbidden by
//!   the workspace `clippy.toml`; this helper threads the engine-aware
//!   cast templates onto every wrapper column.
//! - [`schema_check`] runs the boot-time `schema_migrations` probe.

pub mod dialect;
pub mod insert_helper;
pub mod pool;
pub mod schema_check;
pub mod types;

mod error;

pub use dialect::Dialect;
pub use error::DbError;
pub use insert_helper::{insert_active_model, update_active_model};
pub use pool::{connect_from_config, Db};
pub use schema_check::{schema_check, SchemaCheckOutcome, MAX_KNOWN_MIGRATION};

// `SeaORM` connection type re-export. Phase B conversion units thread this
// type through repo / service function signatures so consumer crates
// don't need to take a direct sea-orm dependency until they convert.
pub use sea_orm::DatabaseConnection;
