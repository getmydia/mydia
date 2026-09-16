//! Authentication, device and API key types.
//!
//! Types owned by this module (keep in sync with tests/types_remaining.rs):
//! User, LoginResult, LoginInput, AccessToken, MediaToken, ApiKey,
//! CreateApiKeyResult, RemoteDevice, RevokeDeviceResult, ClaimCode, Device,
//! DeviceStatusEvent, ToggleFavoriteResult.

use async_graphql::{InputObject, SimpleObject, ID};
use chrono::{DateTime, Utc};

use crate::types::common::DeviceEventType;

#[derive(SimpleObject)]
pub struct User {
    pub id: ID,
    pub username: Option<String>,
    pub email: Option<String>,
    pub display_name: Option<String>,
}

#[derive(SimpleObject)]
pub struct LoginResult {
    pub token: String,
    pub user: User,
    pub expires_in: i32,
}

#[derive(InputObject)]
pub struct LoginInput {
    pub username: String,
    pub password: String,
    pub device_id: String,
    pub device_name: String,
    pub platform: String,
}

#[derive(SimpleObject)]
pub struct AccessToken {
    pub token: String,
    pub expires_at: DateTime<Utc>,
}

#[derive(SimpleObject)]
pub struct MediaToken {
    pub token: String,
    pub expires_at: DateTime<Utc>,
    pub permissions: Vec<String>,
}

#[derive(SimpleObject)]
pub struct ApiKey {
    pub id: ID,
    pub name: String,
    pub key_prefix: String,
    pub permissions: Vec<String>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
}

#[derive(SimpleObject)]
pub struct CreateApiKeyResult {
    pub api_key: ApiKey,
    pub key: String,
}

#[derive(SimpleObject)]
pub struct RemoteDevice {
    pub id: ID,
    pub device_name: String,
    pub platform: String,
    pub last_seen_at: Option<DateTime<Utc>>,
    /// Whether the device was active within the last 15 minutes.
    pub online: bool,
    pub is_revoked: bool,
    pub created_at: DateTime<Utc>,
    /// The p2p node id this device registered, if it has paired for remote
    /// control. This server does not implement remote access, so it is
    /// always `None` here; the field exists for schema parity with the
    /// Elixir server.
    pub node_id: Option<String>,
}

#[derive(SimpleObject)]
pub struct RevokeDeviceResult {
    pub success: bool,
    pub device: Option<RemoteDevice>,
}

#[derive(SimpleObject)]
pub struct ClaimCode {
    pub code: String,
    pub expires_at: DateTime<Utc>,
    pub relay_registered: bool,
}

#[derive(SimpleObject)]
pub struct Device {
    pub id: ID,
    pub device_name: String,
    pub platform: String,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
}

#[derive(SimpleObject)]
pub struct DeviceStatusEvent {
    pub device: Device,
    pub event: DeviceEventType,
}

#[derive(SimpleObject)]
pub struct ToggleFavoriteResult {
    pub is_favorite: bool,
    pub media_item_id: ID,
}

/// How recently a device must have been seen to count as online, in seconds.
/// Matches `Mydia.RemoteAccess.online?/2` on the Elixir server, whose comment
/// explains why it is three liveness write intervals wide.
const ONLINE_WINDOW_SECONDS: i64 = 15 * 60;

/// Whether a device last seen at `last_seen_at` counts as online at `now`.
/// The window excludes its own edge, as the Elixir definition does.
pub fn is_online(last_seen_at: DateTime<Utc>, now: DateTime<Utc>) -> bool {
    last_seen_at > now - chrono::Duration::seconds(ONLINE_WINDOW_SECONDS)
}

/// Converts a stored device row into its GraphQL representation. Dates are
/// stored as RFC 3339 strings; a row that fails to parse is a storage bug,
/// not a caller error, so it surfaces as a plain error rather than a panic.
pub fn remote_device_from(
    device: mydia_db::devices::Device,
) -> async_graphql::Result<RemoteDevice> {
    let last_seen_at = parse_timestamp(&device.last_seen_at)?;

    Ok(RemoteDevice {
        id: device.id.into(),
        device_name: device.device_name,
        platform: device.platform,
        last_seen_at: Some(last_seen_at),
        online: is_online(last_seen_at, Utc::now()),
        is_revoked: device.revoked_at.is_some(),
        created_at: parse_timestamp(&device.inserted_at)?,
        node_id: None,
    })
}

fn parse_timestamp(value: &str) -> async_graphql::Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| async_graphql::Error::new(e.to_string()))
}

/// Renders just this group's types as SDL.
pub fn sdl_fragment() -> String {
    use async_graphql::{EmptyMutation, EmptySubscription, Object, Schema};

    struct FragmentQuery;

    #[Object]
    impl FragmentQuery {
        async fn user(&self) -> User {
            std::future::pending().await
        }

        async fn login_result(&self) -> LoginResult {
            std::future::pending().await
        }

        async fn login_input(&self, _input: LoginInput) -> bool {
            false
        }

        async fn access_token(&self) -> AccessToken {
            std::future::pending().await
        }

        async fn media_token(&self) -> MediaToken {
            std::future::pending().await
        }

        async fn api_key(&self) -> ApiKey {
            std::future::pending().await
        }

        async fn create_api_key_result(&self) -> CreateApiKeyResult {
            std::future::pending().await
        }

        async fn remote_device(&self) -> RemoteDevice {
            std::future::pending().await
        }

        async fn revoke_device_result(&self) -> RevokeDeviceResult {
            std::future::pending().await
        }

        async fn claim_code(&self) -> ClaimCode {
            std::future::pending().await
        }

        async fn device(&self) -> Device {
            std::future::pending().await
        }

        async fn device_status_event(&self) -> DeviceStatusEvent {
            std::future::pending().await
        }

        async fn toggle_favorite_result(&self) -> ToggleFavoriteResult {
            std::future::pending().await
        }
    }

    Schema::build(FragmentQuery, EmptyMutation, EmptySubscription)
        .finish()
        .sdl()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 16, 12, 0, 0).unwrap()
    }

    #[test]
    fn a_device_seen_a_minute_ago_is_online() {
        assert!(is_online(now() - chrono::Duration::seconds(60), now()));
    }

    #[test]
    fn a_device_seen_sixteen_minutes_ago_is_offline() {
        assert!(!is_online(now() - chrono::Duration::seconds(960), now()));
    }

    #[test]
    fn the_window_is_fifteen_minutes_and_excludes_its_own_edge() {
        assert!(is_online(now() - chrono::Duration::seconds(899), now()));
        assert!(!is_online(now() - chrono::Duration::seconds(900), now()));
    }
}
