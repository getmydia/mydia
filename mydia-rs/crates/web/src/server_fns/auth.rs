//! Authentication server functions for U24.a (auth UI).
//!
//! Mirrors `MydiaWeb.SessionController` + `MydiaWeb.FirstTimeSetupLive`
//! but with tower-sessions as the session backend instead of Plug
//! signed cookies. Three endpoints land here:
//!
//! - [`login_with_password`] — bcrypt verify against
//!   `users.password_hash`, write `user_id` into the session, update
//!   `last_login_at`.
//! - [`logout`] — clear the session (deletes the row + the cookie).
//! - [`setup_admin`] — create the initial admin user if the `users`
//!   table is empty, then sign them in. Mirrors
//!   `FirstTimeSetupLive`'s `handle_event("create_admin", ...)` minus
//!   the random-password mode (deferred to U24.b).
//!
//! OIDC PKCE flow lands separately in U24.b.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Wire payload for a password login attempt.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginPayload {
    pub username: String,
    pub password: String,
}

/// Wire payload for first-time admin setup.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetupPayload {
    pub username: String,
    pub email: String,
    pub password: String,
}

/// Small DTO returned by the auth server fns. The page redirects on
/// success and renders the message on failure.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthAck {
    pub user_id: String,
    pub username: Option<String>,
    pub role: String,
}

#[get("/api/auth/me")]
pub async fn current_user() -> Result<Option<AuthAck>, ServerFnError> {
    server::current_user().await
}

#[post("/api/auth/login")]
pub async fn login_with_password(payload: LoginPayload) -> Result<AuthAck, ServerFnError> {
    server::login(payload).await
}

#[post("/api/auth/logout")]
pub async fn logout() -> Result<(), ServerFnError> {
    server::logout().await
}

#[post("/api/auth/setup")]
pub async fn setup_admin(payload: SetupPayload) -> Result<AuthAck, ServerFnError> {
    server::setup(payload).await
}

#[get("/api/auth/setup-required")]
pub async fn setup_required() -> Result<bool, ServerFnError> {
    server::setup_required().await
}

/// Client-side check used by the login page to decide whether to
/// render the OIDC button. Returns `true` iff [`WebState::oidc`] was
/// successfully discovered at boot.
#[get("/api/auth/oidc-available")]
pub async fn oidc_available() -> Result<bool, ServerFnError> {
    server::oidc_available().await
}

/// Server-side helper used by [`crate::oidc::callback_handler`] to
/// upsert a user freshly authenticated via OIDC. Exposed at the
/// module boundary so the raw axum callback doesn't need to reach
/// into the server-fn private module path.
#[cfg(feature = "server")]
pub async fn upsert_oidc_user(
    db: &mydia_rs_db::DatabaseConnection,
    payload: &crate::oidc::OidcUserPayload,
) -> Result<String, ServerFnError> {
    server::upsert_oidc_user(db, payload).await
}

/// Server-side helper: pull the logged-in user's id out of the
/// session, or surface a 401-shaped `ServerFnError` if the request
/// is anonymous. Every server fn that mutates user-owned state (e.g.
/// the `library_paths` CRUD endpoints) should call this first.
#[cfg(feature = "server")]
pub async fn require_session_user_id() -> Result<String, ServerFnError> {
    server::require_session_user_id().await
}

/// Server-side helper used by every admin server fn — pulls the
/// session user, looks the row up, and verifies `role == "admin"`.
/// Returns the user id on success; a `not authorized` `ServerFnError`
/// otherwise (the page renders this inline). The 401-vs-403 distinction
/// is collapsed for the same reason
/// [`require_session_user_id`] collapses logged-out and session-expired.
#[cfg(feature = "server")]
pub async fn require_admin_user_id() -> Result<String, ServerFnError> {
    server::require_admin_user_id().await
}

#[cfg(feature = "server")]
mod server {
    use super::{AuthAck, LoginPayload, SetupPayload};
    use crate::server_state::WebState;
    use crate::session::SESSION_KEY_USER_ID;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_auth::password::{hash_password, verify_password, PasswordError};
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::{insert_active_model, DatabaseConnection};
    use mydia_rs_entities::users;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QuerySelect;
    use sea_orm::sea_query::{Expr, ExprTrait};
    use sea_orm::Set;
    use tower_sessions::Session;

    fn parse_uuid_wrapper(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    pub(crate) async fn require_session_user_id() -> Result<String, ServerFnError> {
        let session = session_handle().await?;
        let Some(user_id) = session
            .get::<String>(SESSION_KEY_USER_ID)
            .await
            .map_err(|err| ServerFnError::new(format!("session read: {err}")))?
        else {
            // Don't reveal that the session was simply missing —
            // operator-facing pages render the same way for "logged
            // out" and "session expired" so a 401-shaped error works
            // for both.
            return Err(ServerFnError::new("not authenticated"));
        };
        Ok(user_id)
    }

    pub(crate) async fn require_admin_user_id() -> Result<String, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state().await?;
        let role = lookup_user_role(&st.db, &user_id).await?;
        if role.as_deref() == Some("admin") {
            Ok(user_id)
        } else {
            Err(ServerFnError::new("not authorized"))
        }
    }

    async fn lookup_user_role(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<Option<String>, ServerFnError> {
        let Some(wrapper) = parse_uuid_wrapper(id) else {
            return Ok(None);
        };
        let backend = db.get_database_backend();
        let row = users::Entity::find()
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup role: {err}")))?;
        Ok(row.map(|u| u.role))
    }

    /// Server-fn-helpers that the dual-target functions delegate to.
    pub(super) async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    async fn session_handle() -> Result<Session, ServerFnError> {
        FullstackContext::extract::<Session, _>()
            .await
            .map_err(|err| ServerFnError::new(format!("session unavailable: {err}")))
    }

    pub(super) async fn current_user() -> Result<Option<AuthAck>, ServerFnError> {
        let session = session_handle().await?;
        let Some(user_id) = session
            .get::<String>(SESSION_KEY_USER_ID)
            .await
            .map_err(|err| ServerFnError::new(format!("session read: {err}")))?
        else {
            return Ok(None);
        };
        let st = state().await?;
        match load_user_brief(&st.db, &user_id).await {
            Ok(Some(ack)) => Ok(Some(ack)),
            Ok(None) => {
                // The user row went away between login and this read
                // (admin deleted them, for example). Clear the
                // dangling session so the page redirects to /login on
                // the next paint.
                let _ = session.delete().await;
                Ok(None)
            }
            Err(err) => Err(err),
        }
    }

    pub(super) async fn login(payload: LoginPayload) -> Result<AuthAck, ServerFnError> {
        let username = payload.username.trim();
        if username.is_empty() || payload.password.is_empty() {
            return Err(ServerFnError::new("Invalid username or password"));
        }
        let st = state().await?;

        let row = lookup_user_for_login(&st.db, username).await?;
        let Some((id, db_username, password_hash, role)) = row else {
            // Indistinguishable from "wrong password" by design — we
            // do not leak which side failed.
            return Err(ServerFnError::new("Invalid username or password"));
        };

        let Some(hash) = password_hash else {
            // OIDC-only users (no password set) hit this path. Mirror
            // Phoenix's `verify_password(_, _) -> false` clause.
            return Err(ServerFnError::new("Invalid username or password"));
        };

        match verify_password(&payload.password, &hash) {
            Ok(()) => {}
            Err(PasswordError::Mismatch) => {
                return Err(ServerFnError::new("Invalid username or password"));
            }
            Err(err) => {
                tracing::warn!(%err, "password verify failed unexpectedly");
                return Err(ServerFnError::new("Invalid username or password"));
            }
        }

        touch_last_login(&st.db, &id).await?;

        let session = session_handle().await?;
        // tower-sessions cycles the session id on successful login —
        // this protects against session fixation (an attacker who
        // pre-set the cookie can't reuse it after the victim authenticates).
        session
            .cycle_id()
            .await
            .map_err(|err| ServerFnError::new(format!("session cycle_id: {err}")))?;
        session
            .insert(SESSION_KEY_USER_ID, &id)
            .await
            .map_err(|err| ServerFnError::new(format!("session insert: {err}")))?;

        Ok(AuthAck {
            user_id: id,
            username: Some(db_username),
            role,
        })
    }

    pub(super) async fn logout() -> Result<(), ServerFnError> {
        let session = session_handle().await?;
        session
            .delete()
            .await
            .map_err(|err| ServerFnError::new(format!("session delete: {err}")))?;
        Ok(())
    }

    pub(super) async fn setup_required() -> Result<bool, ServerFnError> {
        let st = state().await?;
        Ok(count_users(&st.db).await? == 0)
    }

    pub(super) async fn oidc_available() -> Result<bool, ServerFnError> {
        let st = state().await?;
        Ok(st.oidc_available())
    }

    /// Upsert an OIDC-authenticated user.
    ///
    /// Mirrors `Mydia.Accounts.upsert_user_from_oidc/3`:
    ///   1. If a user already exists with the same `(oidc_sub,
    ///      oidc_issuer)` pair, update the mutable identity fields
    ///      (`email`, `display_name`, `avatar_url`) and return their id.
    ///   2. Otherwise insert a fresh row keyed by a new UUID.
    ///
    /// The role assignment falls back to `"user"` (see
    /// `oidc::extract_user_payload`); group/role-claim mapping is a
    /// follow-up tied to a `MydiaAdditionalClaims` shape.
    pub(crate) async fn upsert_oidc_user(
        db: &DatabaseConnection,
        payload: &crate::oidc::OidcUserPayload,
    ) -> Result<String, ServerFnError> {
        let existing = lookup_oidc_user(db, &payload.sub, &payload.issuer).await?;
        let now = chrono::Utc::now();
        let now_wrapper = DateTimeSecs::from(now);

        if let Some(existing_id) = existing {
            update_oidc_user(db, &existing_id, payload, now_wrapper).await?;
            return Ok(existing_id.to_string());
        }

        let id_uuid = uuid::Uuid::new_v4();
        let id = UuidText::from(id_uuid);
        insert_oidc_user(db, id, payload, now_wrapper).await?;
        Ok(id_uuid.to_string())
    }

    async fn lookup_oidc_user(
        db: &DatabaseConnection,
        sub: &str,
        issuer: &str,
    ) -> Result<Option<UuidText>, ServerFnError> {
        let row = users::Entity::find()
            .filter(users::Column::OidcSub.eq(sub.to_owned()))
            .filter(users::Column::OidcIssuer.eq(issuer.to_owned()))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup oidc user: {err}")))?;
        Ok(row.map(|u| u.id))
    }

    async fn insert_oidc_user(
        db: &DatabaseConnection,
        id: UuidText,
        payload: &crate::oidc::OidcUserPayload,
        now: DateTimeSecs,
    ) -> Result<(), ServerFnError> {
        let am = users::ActiveModel {
            id: Set(id),
            username: Set(None),
            email: Set(payload.email.clone()),
            password_hash: Set(None),
            oidc_sub: Set(Some(payload.sub.clone())),
            oidc_issuer: Set(Some(payload.issuer.clone())),
            role: Set(payload.role.clone()),
            display_name: Set(payload.display_name.clone()),
            avatar_url: Set(payload.avatar_url.clone()),
            last_login_at: Set(Some(now)),
            inserted_at: Set(now),
            updated_at: Set(now),
        };
        insert_active_model(am, db)
            .await
            .map_err(|err| ServerFnError::new(format!("insert oidc user: {err}")))?;
        Ok(())
    }

    async fn update_oidc_user(
        db: &DatabaseConnection,
        id: &UuidText,
        payload: &crate::oidc::OidcUserPayload,
        now: DateTimeSecs,
    ) -> Result<(), ServerFnError> {
        // last_login_at is bumped here as well so OIDC users see a
        // current timestamp on the profile page — touch_last_login
        // is bcrypt-path only.
        let backend = db.get_database_backend();
        users::Entity::update_many()
            .col_expr(users::Column::Email, Expr::value(payload.email.clone()))
            .col_expr(
                users::Column::DisplayName,
                Expr::value(payload.display_name.clone()),
            )
            .col_expr(
                users::Column::AvatarUrl,
                Expr::value(payload.avatar_url.clone()),
            )
            .col_expr(users::Column::LastLoginAt, now.into_simple_expr(backend))
            .col_expr(users::Column::UpdatedAt, now.into_simple_expr(backend))
            .filter(Expr::col(users::Column::Id).eq((*id).into_simple_expr(backend)))
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("update oidc user: {err}")))?;
        Ok(())
    }

    pub(super) async fn setup(payload: SetupPayload) -> Result<AuthAck, ServerFnError> {
        validate_setup_payload(&payload)?;
        let st = state().await?;
        if count_users(&st.db).await? != 0 {
            return Err(ServerFnError::new(
                "Setup is closed: an admin user already exists",
            ));
        }

        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = chrono::Utc::now();
        let now_wrapper = DateTimeSecs::from(now);
        let hash = hash_password(&payload.password)
            .map_err(|err| ServerFnError::new(format!("hash password: {err}")))?;

        let am = users::ActiveModel {
            id: Set(id),
            username: Set(Some(payload.username.trim().to_owned())),
            email: Set(Some(payload.email.trim().to_owned())),
            password_hash: Set(Some(hash)),
            oidc_sub: Set(None),
            oidc_issuer: Set(None),
            role: Set("admin".to_owned()),
            display_name: Set(None),
            avatar_url: Set(None),
            last_login_at: Set(Some(now_wrapper)),
            inserted_at: Set(now_wrapper),
            updated_at: Set(now_wrapper),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("create admin: {err}")))?;

        // Sign the new admin in immediately so they land on the home
        // page logged-in, matching Phoenix's
        // `FirstTimeSetupLive.handle_event("create_admin", ...)` path
        // which redirects to /auth/auto-login.
        let session = session_handle().await?;
        session
            .cycle_id()
            .await
            .map_err(|err| ServerFnError::new(format!("session cycle_id: {err}")))?;
        session
            .insert(SESSION_KEY_USER_ID, &id_str)
            .await
            .map_err(|err| ServerFnError::new(format!("session insert: {err}")))?;

        Ok(AuthAck {
            user_id: id_str,
            username: Some(payload.username.trim().to_owned()),
            role: "admin".to_owned(),
        })
    }

    fn validate_setup_payload(payload: &SetupPayload) -> Result<(), ServerFnError> {
        let username = payload.username.trim();
        if !(3..=50).contains(&username.chars().count()) {
            return Err(ServerFnError::new("Username must be 3-50 characters"));
        }
        let email = payload.email.trim();
        if !email.contains('@') || email.split_whitespace().count() != 1 {
            return Err(ServerFnError::new("Email must be a valid address"));
        }
        if payload.password.chars().count() < 8 {
            return Err(ServerFnError::new("Password must be at least 8 characters"));
        }
        Ok(())
    }

    async fn lookup_user_for_login(
        db: &DatabaseConnection,
        username: &str,
    ) -> Result<Option<(String, String, Option<String>, String)>, ServerFnError> {
        let row = users::Entity::find()
            .filter(users::Column::Username.eq(username.to_owned()))
            .limit(1)
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup user: {err}")))?;
        Ok(row.and_then(|u| {
            u.username
                .clone()
                .map(|name| (u.id.to_string(), name, u.password_hash, u.role))
        }))
    }

    async fn touch_last_login(db: &DatabaseConnection, id: &str) -> Result<(), ServerFnError> {
        let Some(wrapper) = parse_uuid_wrapper(id) else {
            return Ok(());
        };
        let backend = db.get_database_backend();
        let now = DateTimeSecs::from(chrono::Utc::now());
        users::Entity::update_many()
            .col_expr(users::Column::LastLoginAt, now.into_simple_expr(backend))
            .col_expr(users::Column::UpdatedAt, now.into_simple_expr(backend))
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(db)
            .await
            .map_err(|err| ServerFnError::new(format!("touch last_login: {err}")))?;
        Ok(())
    }

    async fn count_users(db: &DatabaseConnection) -> Result<i64, ServerFnError> {
        let n = users::Entity::find()
            .count(db)
            .await
            .map_err(|err| ServerFnError::new(format!("count users: {err}")))?;
        Ok(i64::try_from(n).unwrap_or(i64::MAX))
    }

    async fn load_user_brief(
        db: &DatabaseConnection,
        id: &str,
    ) -> Result<Option<AuthAck>, ServerFnError> {
        let Some(wrapper) = parse_uuid_wrapper(id) else {
            return Ok(None);
        };
        let backend = db.get_database_backend();
        let row = users::Entity::find()
            .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("load user: {err}")))?;
        Ok(row.map(|u| AuthAck {
            user_id: u.id.to_string(),
            username: u.username,
            role: u.role,
        }))
    }
}
