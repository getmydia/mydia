//! User-management server functions.
//!
//! Phoenix counterpart: `MydiaWeb.AdminUsersLive.Index` +
//! `Mydia.Accounts`. The Phoenix page exposes five mutations: create
//! user, update role, reset password, delete user, and a search/role
//! filter. U28 ships the four that the operational admin reaches for
//! day-to-day; password-reset modal lands in a follow-up because the
//! Phoenix flow has a generated-vs-manual mode toggle that doesn't
//! map cleanly to a single server fn signature.
//!
//! Validation mirrors `Mydia.Accounts.User`'s changeset:
//!
//! - `username` 3 to 50 chars, unique.
//! - `email` non-blank and looks like an email (single `@`,
//!   no whitespace).
//! - `password` at least 8 chars on create.
//! - `role` in the small set `{admin, user, readonly, guest}`.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Row shape for the users table.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct UserRow {
    pub id: String,
    pub username: Option<String>,
    pub email: Option<String>,
    pub role: String,
    /// `true` when `oidc_sub` is set; OIDC users have no local
    /// password to reset and the role-only path is the only mutation
    /// the admin page allows.
    pub is_oidc: bool,
    pub last_login_at: Option<String>,
    pub inserted_at: Option<String>,
}

/// Wire payload for the create-user flow.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NewUser {
    pub username: String,
    pub email: String,
    pub password: String,
    /// Defaults to `"guest"` when blank.
    #[serde(default)]
    pub role: String,
}

/// Wire payload for role-change.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoleUpdate {
    pub id: String,
    pub role: String,
}

#[get("/api/admin/users")]
pub async fn list_users() -> Result<Vec<UserRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/users")]
pub async fn create_user(payload: NewUser) -> Result<UserRow, ServerFnError> {
    server::create(payload).await
}

#[post("/api/admin/users/role")]
pub async fn update_user_role(payload: RoleUpdate) -> Result<UserRow, ServerFnError> {
    server::update_role(payload).await
}

#[post("/api/admin/users/delete")]
pub async fn delete_user(id: String) -> Result<(), ServerFnError> {
    server::delete(id).await
}

/// The small set of roles a user can hold. Mirrors
/// `Mydia.Accounts.User.valid_roles/0`.
pub const VALID_ROLES: &[&str] = &["admin", "user", "readonly", "guest"];

#[cfg(feature = "server")]
mod server {
    use super::{NewUser, RoleUpdate, UserRow, VALID_ROLES};
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_auth::password::hash_password;
    use mydia_rs_db::Db;

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    type UserTuple = (
        String,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
        Option<chrono::DateTime<chrono::Utc>>,
        Option<chrono::DateTime<chrono::Utc>>,
    );

    pub(super) async fn list() -> Result<Vec<UserRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let state = state().await?;
        let rows: Vec<UserTuple> = match &state.db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, username, email, role, oidc_sub, last_login_at, inserted_at \
                 FROM users ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query users: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, username, email, role, oidc_sub, last_login_at, inserted_at \
                 FROM users ORDER BY inserted_at ASC",
            )
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("query users: {err}")))?,
        };
        Ok(rows
            .into_iter()
            .map(
                |(id, username, email, role, oidc_sub, last_login_at, inserted_at)| UserRow {
                    id,
                    username,
                    email,
                    role,
                    is_oidc: oidc_sub.is_some(),
                    last_login_at: last_login_at.map(|dt| dt.to_rfc3339()),
                    inserted_at: inserted_at.map(|dt| dt.to_rfc3339()),
                },
            )
            .collect())
    }

    pub(super) async fn create(payload: NewUser) -> Result<UserRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        validate_new_user(&payload)?;

        let state = state().await?;
        let role = if payload.role.trim().is_empty() {
            "guest"
        } else {
            payload.role.trim()
        };
        if !VALID_ROLES.contains(&role) {
            return Err(ServerFnError::new(format!(
                "invalid role {role:?}; must be one of {VALID_ROLES:?}"
            )));
        }

        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();
        let hash = hash_password(&payload.password)
            .map_err(|err| ServerFnError::new(format!("hash password: {err}")))?;

        let username = payload.username.trim().to_owned();
        let email = payload.email.trim().to_owned();

        match &state.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO users (id, username, email, password_hash, role, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(&username)
                .bind(&email)
                .bind(&hash)
                .bind(role)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert user: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO users (id, username, email, password_hash, role, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7)",
                )
                .bind(&id)
                .bind(&username)
                .bind(&email)
                .bind(&hash)
                .bind(role)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert user: {err}")))?;
            }
        }

        Ok(UserRow {
            id,
            username: Some(username),
            email: Some(email),
            role: role.to_owned(),
            is_oidc: false,
            last_login_at: None,
            inserted_at: Some(now.to_rfc3339()),
        })
    }

    pub(super) async fn update_role(payload: RoleUpdate) -> Result<UserRow, ServerFnError> {
        let _ = require_admin_user_id().await?;
        if !VALID_ROLES.contains(&payload.role.as_str()) {
            return Err(ServerFnError::new(format!(
                "invalid role {role:?}; must be one of {VALID_ROLES:?}",
                role = payload.role,
            )));
        }
        let state = state().await?;
        let affected = match &state.db {
            Db::Sqlite(pool) => {
                sqlx::query("UPDATE users SET role = ?, updated_at = ? WHERE id = ?")
                    .bind(&payload.role)
                    .bind(chrono::Utc::now().to_rfc3339())
                    .bind(&payload.id)
                    .execute(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("update role: {err}")))?
                    .rows_affected()
            }
            Db::Postgres(pool) => {
                sqlx::query("UPDATE users SET role = $1, updated_at = $2 WHERE id = $3")
                    .bind(&payload.role)
                    .bind(chrono::Utc::now())
                    .bind(&payload.id)
                    .execute(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("update role: {err}")))?
                    .rows_affected()
            }
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!(
                "no user with id {}",
                payload.id
            )));
        }

        // Re-read the row so the page can re-render with the fresh
        // state without a second round-trip.
        let rows = list().await?;
        rows.into_iter()
            .find(|row| row.id == payload.id)
            .ok_or_else(|| {
                ServerFnError::new("user disappeared between update and read".to_owned())
            })
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let acting_user = require_admin_user_id().await?;
        if acting_user == id {
            return Err(ServerFnError::new(
                "You cannot delete your own account".to_owned(),
            ));
        }
        let state = state().await?;
        let affected = match &state.db {
            Db::Sqlite(pool) => sqlx::query("DELETE FROM users WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete user: {err}")))?
                .rows_affected(),
            Db::Postgres(pool) => sqlx::query("DELETE FROM users WHERE id = $1")
                .bind(&id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("delete user: {err}")))?
                .rows_affected(),
        };
        if affected == 0 {
            return Err(ServerFnError::new(format!("no user with id {id}")));
        }
        Ok(())
    }

    fn validate_new_user(payload: &NewUser) -> Result<(), ServerFnError> {
        let username = payload.username.trim();
        if !(3..=50).contains(&username.chars().count()) {
            return Err(ServerFnError::new(
                "Username must be 3-50 characters".to_owned(),
            ));
        }
        let email = payload.email.trim();
        if !email.contains('@') || email.split_whitespace().count() != 1 {
            return Err(ServerFnError::new(
                "Email must be a valid address".to_owned(),
            ));
        }
        if payload.password.chars().count() < 8 {
            return Err(ServerFnError::new(
                "Password must be at least 8 characters".to_owned(),
            ));
        }
        Ok(())
    }
}
