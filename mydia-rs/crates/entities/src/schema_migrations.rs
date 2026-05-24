//! Phoenix's `schema_migrations` table — owned by Ecto's migration
//! framework, not by mydia-rs. Hand-defined here (not codegen-derived)
//! because the column shapes Ecto uses for its bookkeeping table differ
//! from the rest of the schema:
//!
//! - `version BIGINT PRIMARY KEY` — the migration timestamp.
//! - `inserted_at` is `:naive_datetime` (no timezone), unlike the
//!   `:utc_datetime` columns the rest of the app uses. On Postgres it
//!   maps to `timestamp without time zone`; on `SQLite` to TEXT with
//!   `"YYYY-MM-DD HH:MM:SS"` (no `T`, no `Z`). The mydia-rs wrappers
//!   target the `:utc_datetime[_usec]` shape and would fail to bind
//!   against this column, so we keep `NaiveDateTime` directly here.
//!
//! `crates/db/src/schema_check.rs` queries only `version` to determine
//! whether the latest migration matches the mydia-rs-bundled migration
//! set; `inserted_at` is present for completeness and never read.
//!
//! Note: as a guest table inside Phoenix's namespace, this entity is
//! deliberately NOT emitted by `Schema::create_table_from_entity` for
//! application bootstrapping — the table is created by Ecto's own
//! `mix ecto.migrate` flow.

use sea_orm::entity::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, DeriveEntityModel, Serialize, Deserialize)]
#[sea_orm(table_name = "schema_migrations")]
pub struct Model {
    #[sea_orm(primary_key, auto_increment = false)]
    pub version: i64,
    pub inserted_at: Option<DateTime>,
}

#[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
pub enum Relation {}

impl ActiveModelBehavior for ActiveModel {}
