//! `SQLite`-only boot-time mutual-exclusion lock table.
//!
//! Owned by mydia-rs, not Phoenix. The one schema write mydia-rs is
//! allowed to make per the rewrite plan's scope boundary. Created at
//! boot via `Schema::create_table_from_entity` (U18) and never
//! migrated from there — column changes go through a new entity field
//! plus a fresh `CREATE TABLE IF NOT EXISTS` emission. Postgres uses
//! `pg_try_advisory_lock` instead and never sees this table.
//!
//! Columns mirror the CREATE TABLE in `crates/app/src/runtime_lock.rs`:
//! - `lock_key TEXT PRIMARY KEY` — singleton row keyed on
//!   `"mydia-rs-singleton"`.
//! - `pid INTEGER NOT NULL` — process id of the lock holder.
//! - `hostname TEXT` — best-effort hostname (nullable).
//! - `backend TEXT NOT NULL` — identifier of the holding backend
//!   process (e.g. `"mydia-rs"`).
//! - `started_at TEXT NOT NULL` — ISO 8601 UTC when the lock was
//!   acquired.
//! - `heartbeat_at TEXT NOT NULL` — ISO 8601 UTC of the most recent
//!   heartbeat, used by stale-sweep to reclaim abandoned locks.

use sea_orm::entity::prelude::*;
use mydia_rs_db::types::DateTimeSecs;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, DeriveEntityModel, Serialize, Deserialize)]
#[sea_orm(table_name = "mydia_runtime_lock")]
pub struct Model {
    #[sea_orm(primary_key, auto_increment = false)]
    pub lock_key: String,
    pub pid: i32,
    pub hostname: Option<String>,
    pub backend: String,
    pub started_at: DateTimeSecs,
    pub heartbeat_at: DateTimeSecs,
}

#[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
pub enum Relation {}

impl ActiveModelBehavior for ActiveModel {}
