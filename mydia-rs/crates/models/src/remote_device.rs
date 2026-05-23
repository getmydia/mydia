//! Port of `Mydia.RemoteAccess.RemoteDevice` (`lib/mydia/remote_access/remote_device.ex`).
//!
//! Phoenix table: `remote_devices`. Each row represents a paired
//! client device (mobile, web, desktop) authorised to access this
//! mydia instance remotely. The plaintext `token` field on the Ecto
//! side is virtual; only the Argon2-hashed `token_hash` ever reaches
//! the DB, matching `api_keys.key_hash` discipline.
//!
//! See `priv/repo/migrations/20251225060000_create_remote_access_tables.exs`
//! for the on-disk schema.

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use serde::{Deserialize, Serialize};

/// Row from `remote_devices`. `device_static_public_key` is a 32-byte
/// binary column (BLOB on `SQLite`, BYTEA on Postgres). We keep it as
/// `Vec<u8>` rather than a fixed-size array because Ecto allows
/// historical rows with non-32-byte values during the parallel
/// window; downstream validation lives at the issue/consume seam.
#[derive(Debug, Clone, sqlx::FromRow, Serialize, Deserialize)]
pub struct RemoteDevice {
    pub id: UuidText,
    pub device_name: String,
    pub platform: String,
    pub device_static_public_key: Vec<u8>,
    pub token_hash: String,
    pub last_seen_at: Option<DateTimeSecs>,
    pub revoked_at: Option<DateTimeSecs>,
    pub user_id: UuidText,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}

impl RemoteDevice {
    /// `true` once [`Self::revoked_at`] is set.
    pub fn is_revoked(&self) -> bool {
        self.revoked_at.is_some()
    }
}
