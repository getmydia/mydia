//! Profile + preferences server functions (U24.d).
//!
//! Three endpoints surface here:
//!
//! - [`current_profile`] — reads the signed-in user's row and returns
//!   a redacted view (no password hash, no oidc-sub).
//! - [`update_profile`] — mirrors `User.profile_changeset/2` exactly:
//!   only `display_name` (max 100 chars) and `avatar_url` (must look
//!   like an http(s) URL) are mutable through this endpoint. Email,
//!   username, role, oidc fields are not editable here.
//! - [`change_password`] — verifies the current bcrypt hash before
//!   writing the new one. OIDC-only users (no password set) get a
//!   clear "no password to change" error rather than a confusing
//!   "wrong password" message.
//!
//! Trakt OAuth device-flow integration, theme preference persistence,
//! and avatar-image upload are deferred — they touch the
//! `user_preferences` and `user_integrations` tables, which need
//! separate model ports.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Redacted view of a `users` row safe to send to the client.
/// Excludes `password_hash` and any other secret material.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProfileView {
    pub user_id: String,
    pub username: Option<String>,
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub role: String,
    /// `true` iff the user has an OIDC subject claim — the profile
    /// page hides the password-change UI in that case.
    pub is_oidc: bool,
    /// RFC3339 timestamp of the user's last successful login.
    pub last_login_at: Option<String>,
}

/// Wire payload for the profile-form submission. Matches the Phoenix
/// `profile_changeset` cast list exactly.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfilePayload {
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
}

/// Wire payload for the password-change modal. The server re-validates
/// confirmation server-side even though the client also checks it —
/// never trust the client.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PasswordChangePayload {
    pub current_password: String,
    pub new_password: String,
    pub confirm_password: String,
}

#[get("/api/profile")]
pub async fn current_profile() -> Result<ProfileView, ServerFnError> {
    server::current_profile().await
}

#[post("/api/profile")]
pub async fn update_profile(payload: ProfilePayload) -> Result<ProfileView, ServerFnError> {
    server::update_profile(payload).await
}

#[post("/api/profile/password")]
pub async fn change_password(payload: PasswordChangePayload) -> Result<(), ServerFnError> {
    server::change_password(payload).await
}

#[cfg(feature = "server")]
mod server {
    use super::{PasswordChangePayload, ProfilePayload, ProfileView};
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_auth::password::{hash_password, verify_password, PasswordError};
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::users;
    use sea_orm::entity::prelude::*;
    use sea_orm::sea_query::{Expr, ExprTrait};

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn current_profile() -> Result<ProfileView, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state()?;
        load_profile(&st.db, &user_id).await?.ok_or_else(|| {
            // Defensive: the session pointed at a row that no longer
            // exists. The session middleware would normally clear the
            // cookie here, but the server fn surface can only return
            // an error — the AppShell guard will then redirect to
            // /login on next render.
            ServerFnError::new("user not found")
        })
    }

    pub(super) async fn update_profile(
        payload: ProfilePayload,
    ) -> Result<ProfileView, ServerFnError> {
        let user_id = require_session_user_id().await?;
        validate_profile_payload(&payload)?;

        let st = state()?;
        write_profile(&st.db, &user_id, &payload).await?;
        load_profile(&st.db, &user_id)
            .await?
            .ok_or_else(|| ServerFnError::new("user vanished mid-update"))
    }

    pub(super) async fn change_password(
        payload: PasswordChangePayload,
    ) -> Result<(), ServerFnError> {
        let user_id = require_session_user_id().await?;

        if payload.new_password != payload.confirm_password {
            return Err(ServerFnError::new("New passwords do not match"));
        }
        if payload.new_password.chars().count() < 8 {
            return Err(ServerFnError::new(
                "New password must be at least 8 characters",
            ));
        }

        let st = state()?;
        let stored_hash = load_password_hash(&st.db, &user_id).await?;
        let Some(stored_hash) = stored_hash else {
            // OIDC-only users hit this — their authentication is at
            // the provider, not against a stored bcrypt hash.
            return Err(ServerFnError::new(
                "Password change is not available for SSO-only accounts",
            ));
        };

        match verify_password(&payload.current_password, &stored_hash) {
            Ok(()) => {}
            Err(PasswordError::Mismatch) => {
                return Err(ServerFnError::new("Current password is incorrect"));
            }
            Err(err) => {
                tracing::warn!(%err, "password verify failed unexpectedly during change");
                return Err(ServerFnError::new("Current password is incorrect"));
            }
        }

        let new_hash = hash_password(&payload.new_password)
            .map_err(|err| ServerFnError::new(format!("hash new password: {err}")))?;
        write_password_hash(&st.db, &user_id, &new_hash).await?;
        Ok(())
    }

    fn validate_profile_payload(payload: &ProfilePayload) -> Result<(), ServerFnError> {
        if let Some(name) = payload.display_name.as_deref() {
            if name.chars().count() > 100 {
                return Err(ServerFnError::new(
                    "Display name must be 100 characters or less",
                ));
            }
        }
        if let Some(url) = payload.avatar_url.as_deref() {
            let trimmed = url.trim();
            // Phoenix uses `~r/^https?:\/\//`; mirror that check.
            // Empty avatar_url is treated as "clear it" — Phoenix
            // accepts that path too.
            let looks_ok = trimmed.is_empty()
                || trimmed.starts_with("http://")
                || trimmed.starts_with("https://");
            if !looks_ok {
                return Err(ServerFnError::new("Avatar URL must start with http(s)://"));
            }
        }
        Ok(())
    }

    async fn load_profile(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<Option<ProfileView>, ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Ok(None);
        };
        let backend = db.get_database_backend();
        let row = users::Entity::find()
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("load profile: {err}")))?;
        Ok(row.map(|u| ProfileView {
            is_oidc: u.oidc_sub.is_some(),
            user_id: u.id.to_string(),
            username: u.username,
            email: u.email,
            display_name: u.display_name,
            avatar_url: u.avatar_url,
            role: u.role,
            last_login_at: u.last_login_at.map(|dt| dt.0.to_rfc3339()),
        }))
    }

    async fn write_profile(
        db: &DatabaseConnection,
        id: &str,
        payload: &ProfilePayload,
    ) -> Result<(), ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Err(ServerFnError::new(format!("invalid user id {id}")));
        };
        let now = DateTimeSecs::from(chrono::Utc::now());
        let backend = db.get_database_backend();
        // An empty-string avatar payload is treated as NULL — matches
        // Phoenix's allow_blank semantics on the regex validator.
        let avatar_url = payload
            .avatar_url
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let display_name = payload
            .display_name
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);

        users::Entity::update_many()
            .col_expr(users::Column::DisplayName, Expr::value(display_name))
            .col_expr(users::Column::AvatarUrl, Expr::value(avatar_url))
            .col_expr(users::Column::UpdatedAt, now.into_simple_expr(backend))
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("update profile: {err}")))?;
        Ok(())
    }

    async fn load_password_hash(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<Option<String>, ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Ok(None);
        };
        let backend = db.get_database_backend();
        let row = users::Entity::find()
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("load password_hash: {err}")))?;
        Ok(row.and_then(|u| u.password_hash))
    }

    async fn write_password_hash(
        db: &DatabaseConnection,
        id: &str,
        hash: &str,
    ) -> Result<(), ServerFnError> {
        let Some(wrapper) = parse_uuid(id) else {
            return Err(ServerFnError::new(format!("invalid user id {id}")));
        };
        let backend = db.get_database_backend();
        let now = DateTimeSecs::from(chrono::Utc::now());
        users::Entity::update_many()
            .col_expr(users::Column::PasswordHash, Expr::value(hash.to_owned()))
            .col_expr(users::Column::UpdatedAt, now.into_simple_expr(backend))
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("update password_hash: {err}")))?;
        Ok(())
    }
}
