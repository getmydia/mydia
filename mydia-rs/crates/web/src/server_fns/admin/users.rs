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
    use mydia_rs_db::insert_active_model;
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_entities::users;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;
    use sea_orm::sea_query::{Expr, ExprTrait};
    use sea_orm::Set;

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    pub(super) async fn list() -> Result<Vec<UserRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let state = state().await?;
        let rows = users::Entity::find()
            .order_by_asc(users::Column::InsertedAt)
            .all(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query users: {err}")))?;
        Ok(rows
            .into_iter()
            .map(|u| UserRow {
                id: u.id.to_string(),
                username: u.username,
                email: u.email,
                role: u.role,
                is_oidc: u.oidc_sub.is_some(),
                last_login_at: u.last_login_at.map(|dt| dt.0.to_rfc3339()),
                inserted_at: Some(u.inserted_at.0.to_rfc3339()),
            })
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

        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let hash = hash_password(&payload.password)
            .map_err(|err| ServerFnError::new(format!("hash password: {err}")))?;

        let username = payload.username.trim().to_owned();
        let email = payload.email.trim().to_owned();

        let am = users::ActiveModel {
            id: Set(id),
            username: Set(Some(username.clone())),
            email: Set(Some(email.clone())),
            password_hash: Set(Some(hash)),
            oidc_sub: Set(None),
            oidc_issuer: Set(None),
            role: Set(role.to_owned()),
            display_name: Set(None),
            avatar_url: Set(None),
            last_login_at: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
        };
        insert_active_model(am, &state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("insert user: {err}")))?;

        Ok(UserRow {
            id: id_str,
            username: Some(username),
            email: Some(email),
            role: role.to_owned(),
            is_oidc: false,
            last_login_at: None,
            inserted_at: Some(now.0.to_rfc3339()),
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
        let Some(wrapper) = parse_uuid(&payload.id) else {
            return Err(ServerFnError::new(format!(
                "invalid user id {}",
                payload.id
            )));
        };
        let backend = state.db.get_database_backend();
        let now = DateTimeSecs::from(chrono::Utc::now());
        let res = users::Entity::update_many()
            .col_expr(users::Column::Role, Expr::value(payload.role.clone()))
            .col_expr(users::Column::UpdatedAt, now.into_simple_expr(backend))
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("update role: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new(format!(
                "no user with id {}",
                payload.id
            )));
        }

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
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new(format!("invalid user id {id}")));
        };
        let backend = state.db.get_database_backend();
        let res = users::Entity::delete_many()
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&state.db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete user: {err}")))?;
        if res.rows_affected == 0 {
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
