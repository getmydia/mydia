//! `:remote_device` + `:revoke_device_result` — port of
//! `common_types.ex:193-207`.
//!
//! Note: Phoenix exposes BOTH a `remote_device` object (with
//! `is_revoked` + `created_at`) and a separate `device` object (with
//! `revoked_at` + `inserted_at`) for the subscription surface. The
//! Rust port keeps them distinct; the subscription one lives in
//! [`crate::subscriptions::Device`].

use async_graphql::{SimpleObject, ID};
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "RemoteDevice")]
pub struct RemoteDevice {
    pub id: ID,
    pub device_name: String,
    pub platform: String,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub is_revoked: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "RevokeDeviceResult")]
pub struct RevokeDeviceResult {
    pub success: bool,
    pub device: Option<RemoteDevice>,
}
