//! Port of `Mydia.Integrations.UserIntegration`
//! (`lib/mydia/integrations/user_integration.ex`).
//!
//! Models a row in the `user_integrations` table — the Phoenix shape
//! that holds Trakt access tokens and other per-user OAuth credentials.
//! sqlx-shaped persistence lives in the U17 worker layer; this struct is
//! the in-memory value the integrations call sites pass around.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// In-memory representation of a `user_integrations` row.
///
/// Fields mirror `Mydia.Integrations.UserIntegration.t()` 1:1. The
/// Phoenix `settings` column is `:map`; the Rust side keeps it as
/// `serde_json::Value` so callers don't need to know the concrete shape
/// per-provider.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserIntegration {
    pub id: String,
    pub user_id: String,
    pub provider: String,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub token_expires_at: Option<DateTime<Utc>>,
    pub external_user_id: Option<String>,
    pub external_username: Option<String>,
    pub scopes: Option<String>,
    pub enabled: bool,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub settings: serde_json::Value,
}

impl UserIntegration {
    /// Mirror of `UserIntegration.token_expired?/1`.
    ///
    /// Returns `false` for a `None` expiry so callers behave the same
    /// way Phoenix does — only refresh when we have a positive expiry
    /// signal.
    #[must_use]
    pub fn token_expired(&self) -> bool {
        self.token_expires_at
            .is_some_and(|expires_at| Utc::now() > expires_at)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn fixture() -> UserIntegration {
        UserIntegration {
            id: "00000000-0000-0000-0000-000000000001".into(),
            user_id: "00000000-0000-0000-0000-000000000002".into(),
            provider: "trakt".into(),
            access_token: Some("acc".into()),
            refresh_token: Some("ref".into()),
            token_expires_at: None,
            external_user_id: None,
            external_username: None,
            scopes: None,
            enabled: true,
            last_synced_at: None,
            settings: serde_json::Value::Object(serde_json::Map::new()),
        }
    }

    #[test]
    fn none_expires_at_is_never_expired() {
        let i = fixture();
        assert!(!i.token_expired());
    }

    #[test]
    fn past_expiry_is_expired() {
        let mut i = fixture();
        i.token_expires_at = Some(Utc::now() - Duration::hours(1));
        assert!(i.token_expired());
    }

    #[test]
    fn future_expiry_is_not_expired() {
        let mut i = fixture();
        i.token_expires_at = Some(Utc::now() + Duration::hours(1));
        assert!(!i.token_expired());
    }
}
