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
    use mydia_rs_db::Db;

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

    /// Row shape coming back from sqlx for the profile read. Listed
    /// out as a typedef because clippy's `type_complexity` lint
    /// (enabled via -D warnings) rejects the inline tuple.
    type ProfileRowSqlite = (
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
        Option<String>,
    );
    type ProfileRowPg = (
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    async fn load_profile(db: &Db, id: &str) -> Result<Option<ProfileView>, ServerFnError> {
        let view = match db {
            Db::Sqlite(pool) => {
                let raw: Option<ProfileRowSqlite> = sqlx::query_as(
                    "SELECT id, username, email, display_name, avatar_url, role, oidc_sub, last_login_at \
                     FROM users WHERE id = ? LIMIT 1",
                )
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("load profile: {err}")))?;
                raw.map(|(uid, un, em, dn, av, role, sub, llogin)| {
                    let last_login = llogin.as_deref().and_then(|s| {
                        chrono::DateTime::parse_from_rfc3339(s)
                            .ok()
                            .map(|dt| dt.to_rfc3339())
                    });
                    ProfileView {
                        is_oidc: sub.is_some(),
                        user_id: uid,
                        username: un,
                        email: em,
                        display_name: dn,
                        avatar_url: av,
                        role,
                        last_login_at: last_login,
                    }
                })
            }
            Db::Postgres(pool) => {
                let raw: Option<ProfileRowPg> = sqlx::query_as(
                    "SELECT id, username, email, display_name, avatar_url, role, oidc_sub, last_login_at \
                     FROM users WHERE id = $1 LIMIT 1",
                )
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("load profile: {err}")))?;
                raw.map(|(uid, un, em, dn, av, role, sub, llogin)| ProfileView {
                    is_oidc: sub.is_some(),
                    user_id: uid,
                    username: un,
                    email: em,
                    display_name: dn,
                    avatar_url: av,
                    role,
                    last_login_at: llogin.map(|dt| dt.to_rfc3339()),
                })
            }
        };

        Ok(view)
    }

    async fn write_profile(
        db: &Db,
        id: &str,
        payload: &ProfilePayload,
    ) -> Result<(), ServerFnError> {
        let now = chrono::Utc::now();
        // An empty-string avatar payload is treated as NULL — matches
        // Phoenix's allow_blank semantics on the regex validator.
        let avatar_url = payload
            .avatar_url
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let display_name = payload
            .display_name
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());

        match db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "UPDATE users SET display_name = ?, avatar_url = ?, updated_at = ? WHERE id = ?",
                )
                .bind(display_name)
                .bind(avatar_url)
                .bind(now.to_rfc3339())
                .bind(id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("update profile: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "UPDATE users SET display_name = $1, avatar_url = $2, updated_at = $3 WHERE id = $4",
                )
                .bind(display_name)
                .bind(avatar_url)
                .bind(now)
                .bind(id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("update profile: {err}")))?;
            }
        }
        Ok(())
    }

    async fn load_password_hash(db: &Db, id: &str) -> Result<Option<String>, ServerFnError> {
        let row: Option<(Option<String>,)> = match db {
            Db::Sqlite(pool) => {
                sqlx::query_as("SELECT password_hash FROM users WHERE id = ? LIMIT 1")
                    .bind(id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("load password_hash: {err}")))?
            }
            Db::Postgres(pool) => {
                sqlx::query_as("SELECT password_hash FROM users WHERE id = $1 LIMIT 1")
                    .bind(id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("load password_hash: {err}")))?
            }
        };
        Ok(row.and_then(|(h,)| h))
    }

    async fn write_password_hash(db: &Db, id: &str, hash: &str) -> Result<(), ServerFnError> {
        let now = chrono::Utc::now();
        match db {
            Db::Sqlite(pool) => {
                sqlx::query("UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?")
                    .bind(hash)
                    .bind(now.to_rfc3339())
                    .bind(id)
                    .execute(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("update password_hash: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query("UPDATE users SET password_hash = $1, updated_at = $2 WHERE id = $3")
                    .bind(hash)
                    .bind(now)
                    .bind(id)
                    .execute(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("update password_hash: {err}")))?;
            }
        }
        Ok(())
    }
}
