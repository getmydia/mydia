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
    pub is_revoked: bool,
    pub created_at: DateTime<Utc>,
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
