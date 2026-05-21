//! Port of `Mydia.Accounts.ApiKey` (`lib/mydia/accounts/api_key.ex`).
//!
//! Phoenix table: `api_keys`. `permissions` is the dual-encoded
//! [`StringArray`] -> `text[]` on Postgres, JSON-text on SQLite (per
//! `priv/repo/migrations/20260223100000_fix_array_columns_for_postgres.exs`).
//! The virtual `key` field exists only on the Ecto changeset and is
//! not modelled here; only the hash and the stored prefix survive to
//! the DB.

use mydia_rs_db::types::{DateTimeSecs, StringArray, UuidText};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, sqlx::FromRow, Serialize, Deserialize)]
pub struct ApiKey {
    pub id: UuidText,
    pub user_id: UuidText,
    pub name: Option<String>,
    pub key_hash: Option<String>,
    pub key_prefix: Option<String>,
    pub permissions: Option<StringArray>,
    pub last_used_at: Option<DateTimeSecs>,
    pub expires_at: Option<DateTimeSecs>,
    pub revoked_at: Option<DateTimeSecs>,
    pub inserted_at: DateTimeSecs,
}

impl ApiKey {
    /// `true` once [`Self::revoked_at`] is set.
    pub fn is_revoked(&self) -> bool {
        self.revoked_at.is_some()
    }
}

/// Permission strings Phoenix validates against. Kept as constants
/// rather than an enum because the DB stores the strings directly and
/// future Phoenix versions may add new values without coordination.
pub const VALID_PERMISSIONS: &[&str] = &["read", "write", "admin"];
