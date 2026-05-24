//! Port of `Mydia.RemoteAccess.PairingClaim` (`lib/mydia/remote_access/pairing_claim.ex`).
//!
//! Phoenix table: `pairing_claims`. Short-lived (default 5 minutes)
//! code a user generates to pair a new device. The relay service
//! mints the code and stores it both locally (this row) and in the
//! relay's transient store; the device claims it via the relay,
//! which forwards the request through the p2p mesh to this backend.

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingClaim {
    pub id: UuidText,
    pub code: String,
    pub user_id: UuidText,
    pub expires_at: DateTimeSecs,
    pub used_at: Option<DateTimeSecs>,
    pub device_id: Option<UuidText>,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}

impl PairingClaim {
    pub fn is_used(&self) -> bool {
        self.used_at.is_some()
    }

    /// `true` once the expiry timestamp has passed.
    pub fn is_expired(&self, now: chrono::DateTime<chrono::Utc>) -> bool {
        now >= self.expires_at.0
    }
}
